#!/usr/bin/env python3
"""Compile unchanged stable extension syntax and reviewed current replacements.

The module directories (or enclosing build roots) must come from the pinned
5.1.1 and current package builds. check-migration-consumer.sh supplies them.
Each fixture is an independent importing client, never an in-module test.
"""
import argparse
import pathlib
import re
import shutil
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--baseline-modules", required=True, type=pathlib.Path)
parser.add_argument("--candidate-modules", required=True, type=pathlib.Path)
parser.add_argument("--log-directory", required=True, type=pathlib.Path)
parser.add_argument("--candidate-dependency-modules", action="append", default=[], type=pathlib.Path)
args = parser.parse_args()
fixture = pathlib.Path(__file__).resolve().parents[1] / "Tests/Fixtures/MigrationConsumer/EffectTaskExtensions"
args.log_directory.mkdir(parents=True, exist_ok=True)
swiftc = shutil.which("swiftc")
assert swiftc, "swiftc is required"
def module_directory(path):
    if (path / "InnoFlowCore.swiftmodule").exists():
        return path
    # SwiftPM's native and Swift Build backends use different module layouts.
    modules = list(path.rglob("InnoFlowCore.swiftmodule"))
    # Prefer Swift Build's exported architecture bundle over its intermediates.
    exported = [module for module in modules if module.is_dir()]
    matches = sorted({module.parent for module in (exported or modules)})
    assert len(matches) == 1, f"Expected one InnoFlowCore module under {path}, found {matches}"
    return matches[0]

args.baseline_modules = module_directory(args.baseline_modules)
args.candidate_modules = module_directory(args.candidate_modules)

def check(name, modules, source, *, output=False, diagnostic=None):
    command = [swiftc, "-swift-version", "6", "-warnings-as-errors", "-typecheck", "-I", str(modules)]
    if modules == args.candidate_modules:
        for dependency in args.candidate_dependency_modules:
            command += ["-I", str(dependency)]
    if output:
        command += ["-D", "MIGRATION_OUTPUT_CHECK"]
    command += [str(fixture / source)]
    result = subprocess.run(command, capture_output=True, text=True)
    text = result.stdout + result.stderr
    (args.log_directory / f"{name}.log").write_text(text)
    if diagnostic:
        assert result.returncode != 0 and re.search(diagnostic, text), (name, result.returncode, text)
        errors = [line for line in text.splitlines() if re.search(r"^.*:\d+:\d+: error:", line)]
        assert len(errors) == 1, (name, "unexpected extra diagnostics", text)
    else:
        assert result.returncode == 0 and not text, (name, result.returncode, text)
    print(f"[migration-effect-extensions] {name}: {'expected diagnostic' if diagnostic else 'passed'}")

for source in ("BareReturn.swift", "SelfReturn.swift", "ExplicitReturn.swift"):
    check("stable-" + pathlib.Path(source).stem, args.baseline_modules, source)
check("current-BareReturn", args.candidate_modules, "BareReturn.swift",
      diagnostic=r"reference to generic type 'EffectTask' requires arguments")
check("current-SelfReturn", args.candidate_modules, "SelfReturn.swift", output=True)
check("current-ExplicitReturn", args.candidate_modules, "ExplicitReturn.swift", output=True)
check("current-RestrictedOutput", args.candidate_modules, "RestrictedOutput.swift")
check("current-RestrictedOutput-rejected", args.candidate_modules, "RestrictedOutput.swift", output=True,
      diagnostic=r"requires the types 'String' and 'Never' be equivalent")
print("[migration-effect-extensions] 8 stable/current external compiler controls passed")
