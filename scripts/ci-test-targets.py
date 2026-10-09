#!/usr/bin/env python3
"""Fail-closed PR test selection; ordinary, release and shared changes stay full."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
CONTRACT = "docs/contracts/ci-test-targets.json"


def load_policy():
    spec = importlib.util.spec_from_file_location("ci_policy", ROOT / "scripts/ci-policy.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def graph(root=ROOT):
    value = json.loads((root / CONTRACT).read_text())
    if (value["schema"] != 1 or
            hashlib.sha256((root / "Package.swift").read_bytes()).hexdigest() != value["manifestSha256"]):
        raise ValueError("unreviewed package/test graph")
    targets = value["dependencies"]
    if any(not set(deps) <= set(targets) for deps in targets.values()):
        raise ValueError("unknown target dependency")
    if not set(value["testTargets"]) <= set(targets):
        raise ValueError("unknown test target")
    return value


def selection(plan, root=ROOT):
    load_policy().validate_plan(plan)
    full = {"mode": "full", "testTargets": [], "reason": "shared, unknown or full lane"}
    try:
        value = graph(root)
    except (ValueError, KeyError, OSError, json.JSONDecodeError):
        return full
    if plan["lane"] != "fast" or not plan["changes"]:
        return full
    changed = set()
    for change in plan["changes"]:
        parts = change["path"].split("/")
        if (len(parts) < 3 or parts[0] != "Sources" or not parts[-1].endswith(".swift") or
                parts[1] not in value["sourceTargets"]):
            return full
        changed.add(parts[1])
    if len(changed) != 1 or changed & {"InnoFlowCore", "InnoFlow", "InnoFlowMacros"}:
        return full
    affected = set(changed)
    while True:
        expanded = affected | {name for name, deps in value["dependencies"].items() if set(deps) & affected}
        if expanded == affected:
            break
        affected = expanded
    tests = sorted(affected & set(value["testTargets"]))
    if not tests or set(tests) == set(value["testTargets"]):
        return full
    return {"mode": "selected", "testTargets": tests,
            "reason": "reviewed reverse dependencies: " + next(iter(changed))}


def closure(tests, value):
    if not tests or not set(tests) <= set(value["testTargets"]):
        raise ValueError("unknown/empty test selection")
    names = set(tests)
    while True:
        expanded = names | {dep for name in names for dep in value["dependencies"][name]}
        if expanded == names:
            return sorted(names)
        names = expanded


def verify(root=ROOT):
    value = graph(root)
    model = json.loads(subprocess.check_output(["swift", "package", "--package-path", str(root), "dump-package"], text=True))
    inventory = json.loads((root / "docs/contracts/swift-test-inventory.json").read_text())
    verify_manifest(value, model, inventory)
    print(json.dumps({"verifiedTargets": value["dependencies"], "testDeclarations": len(inventory["tests"])}))


def verify_manifest(value, model, inventory):
    actual = {}
    test_targets = []
    support_targets = []
    for target in model["targets"]:
        if target["type"] == "test":
            test_targets.append(target["name"])
        if target["name"] in value["supportTargets"]:
            if target["type"] != "regular" or target.get("path") != "Tests/" + target["name"]:
                raise ValueError("shared fixtures must be regular targets under Tests")
            support_targets.append(target["name"])
        dependencies = []
        for dependency in target["dependencies"]:
            if "byName" in dependency:
                dependencies.append(dependency["byName"][0])
            elif "target" in dependency:
                dependencies.append(dependency["target"][0])
            elif "product" not in dependency or dependency["product"][1] != "swift-syntax":
                raise ValueError("unreviewed external target dependency")
        actual[target["name"]] = sorted(dependencies)
    if actual != {name: sorted(deps) for name, deps in value["dependencies"].items()}:
        raise ValueError("test selection graph differs from actual SwiftPM manifest")
    if (sorted(test_targets) != sorted(value["testTargets"]) or
            sorted(support_targets) != sorted(value["supportTargets"])):
        raise ValueError("unreviewed test/support target")
    # Xcode 26.6 cannot resolve a target that depends on another test target.
    if any(set(deps) & set(test_targets) for deps in actual.values()):
        raise ValueError("targets must not depend on test targets")
    if inventory["hostTargets"] != sorted(test_targets + support_targets):
        raise ValueError("declaration inventory does not cover every test/support target")
    if any(test["target"] in value["supportTargets"] for test in inventory["tests"]):
        raise ValueError("shared fixture targets must not contain test declarations")
    if {product["name"] for product in model["products"]} != set(value["sourceTargets"]) - {"InnoFlowMacros"}:
        raise ValueError("unreviewed shipping product")
    for product in model["products"]:
        names = set(product["targets"])
        while True:
            expanded = names | {dep for name in names for dep in actual[name]}
            if expanded == names:
                break
            names = expanded
        if names & set(test_targets + support_targets):
            raise ValueError("shipping products must not include tests or fixtures")


def prepare(tests, destination, root=ROOT):
    value = graph(root)
    names = closure(tests, value)
    destination = Path(destination).resolve()
    # A fresh private package; never replace a user checkout or an existing build.
    destination.mkdir(parents=True, exist_ok=False)
    with tempfile.TemporaryDirectory(prefix="innoflow-manifest-") as scratch:
        host = json.loads(subprocess.check_output(["swiftc", "-print-target-info"], text=True))["paths"]["runtimeResourcePath"] + "/host"
        tool = Path(scratch) / "rewrite"
        subprocess.run(["swiftc", "-warnings-as-errors", str(root / "scripts/ci-test-package.swift"), "-I", host,
                        "-L", host, "-Xlinker", "-rpath", "-Xlinker", host, "-o", str(tool)], check=True)
        manifest = subprocess.check_output([str(tool), str(root / "Package.swift"), *names])
    (destination / "Package.swift").write_bytes(manifest)
    shutil.copy2(root / "Package.resolved", destination / "Package.resolved")
    # Consumer/script contracts retain their normal repository layout. Do not
    # copy .github, where independent lint jobs may create temporary files.
    for directory in ("Sources", "Tests", "scripts", "docs", "Examples", "skills"):
        shutil.copytree(root / directory, destination / directory,
                        ignore=shutil.ignore_patterns(".build*", ".swiftpm", "__pycache__"))
    for filename in ("LICENSE", ".swift-format"):
        shutil.copy2(root / filename, destination / filename)
    model = json.loads(subprocess.check_output(["swift", "package", "--package-path", str(destination), "dump-package"], text=True))
    actual = sorted(target["name"] for target in model["targets"])
    if actual != names:
        raise ValueError("private package does not match selected dependency closure")
    evidence = {"schema": 1, "testTargets": tests, "compiledTargets": names,
                "rootManifestSha256": value["manifestSha256"],
                "manifestSha256": hashlib.sha256(manifest).hexdigest(), "package": str(destination)}
    (destination / "selection.json").write_text(json.dumps(evidence, indent=2) + "\n")
    return destination


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("select", "run", "prepare", "assert-full", "verify"))
    parser.add_argument("--plan")
    parser.add_argument("--targets", nargs="+")
    parser.add_argument("--destination")
    args = parser.parse_args()
    if args.action == "verify":
        verify()
        return
    if args.action == "prepare":
        print(prepare(args.targets, args.destination))
        return
    plan = json.loads(Path(args.plan).read_text() if args.plan else os.environ["CI_PLAN"])
    chosen = selection(plan)
    print(json.dumps(chosen), flush=True)
    if args.action == "assert-full" and chosen["mode"] != "full":
        raise ValueError("selective tests cannot be reused as complete main test evidence")
    if args.action == "select" and os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a") as stream:
            stream.write("mode=" + chosen["mode"] + "\n")
    if args.action != "run":
        return
    package = ROOT
    if chosen["mode"] == "selected":
        package = prepare(chosen["testTargets"], ROOT / ".build" / ("ci-selected-" + os.environ["GITHUB_RUN_ID"] + "-" + os.environ["GITHUB_RUN_ATTEMPT"]))
    subprocess.run(["swift", "test", "--package-path", str(package), "--jobs", "1",
                    "--no-parallel", "-Xswiftc", "-warnings-as-errors"], check=True)


if __name__ == "__main__":
    main()
