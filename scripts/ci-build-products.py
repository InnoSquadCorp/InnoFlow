#!/usr/bin/env python3
"""Select SDK build products; shared/unknown changes retain the full package build.

Test target selection is verified separately by ci-test-targets.py.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
MANIFEST_SHA256 = "a6a803ad1a2b7c4ae6e3b16ca021a7732b705bdf3251f1f27639e3284526ed2e"
DEPENDENCIES = {
    "InnoFlowCore": set(),
    "InnoFlowMacros": set(),
    "InnoFlow": {"InnoFlowCore", "InnoFlowMacros"},
    "InnoFlowSwiftUI": {"InnoFlowCore"},
    "InnoFlowTesting": {"InnoFlowCore"},
    "InnoFlowInspector": {"InnoFlowCore"},
}
PRODUCTS = set(DEPENDENCIES) - {"InnoFlowMacros"}
PLATFORMS = {"macOS", "iOS", "tvOS", "watchOS", "visionOS"}
FULL = ["InnoFlow-Package"]


def policy():
    spec = importlib.util.spec_from_file_location("ci_policy", ROOT / "scripts/ci-policy.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def affected_products(plan, manifest):
    policy().validate_plan(plan)
    if (plan["lane"] != "fast" or not plan["changes"] or
            hashlib.sha256(manifest).hexdigest() != MANIFEST_SHA256):
        return FULL[:]
    changed = set()
    for change in plan["changes"]:
        parts = change["path"].split("/")
        # Mixed docs, test, package, resource or unknown changes use all products.
        if len(parts) < 3 or parts[0] != "Sources" or parts[1] not in DEPENDENCIES or not parts[-1].endswith(".swift"):
            return FULL[:]
        changed.add(parts[1])
    while True:
        expanded = changed | {target for target, deps in DEPENDENCIES.items() if deps & changed}
        if expanded == changed:
            break
        changed = expanded
    products = sorted(changed & PRODUCTS)
    return FULL[:] if not products or set(products) == PRODUCTS else products


def available_schemes(value):
    if not isinstance(value, dict):
        raise ValueError("malformed xcodebuild scheme listing")
    schemes = set()
    for key in ("workspace", "project"):
        if key in value:
            entries = value[key].get("schemes")
            if not isinstance(entries, list) or not all(isinstance(x, str) for x in entries):
                raise ValueError("malformed xcodebuild schemes")
            schemes.update(entries)
    return schemes


def run(plan, platform, root=ROOT, runner=subprocess.run):
    if platform not in PLATFORMS:
        raise ValueError("unsupported SDK platform")
    products = affected_products(plan, (root / "Package.swift").read_bytes())
    if products != FULL:
        try:
            listing = runner(["xcodebuild", "-list", "-json"], cwd=root,
                             check=True, capture_output=True, text=True, timeout=180)
            if not set(products) <= available_schemes(json.loads(listing.stdout)):
                products = FULL[:]
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired, ValueError):
            # Scheme discovery is advisory; the full real build still must pass.
            products = FULL[:]
    print(json.dumps({"platform": platform, "schemes": products,
                      "tests": "full SDK product contract retained"}), flush=True)
    for product in products:
        runner(["xcodebuild", "-scheme", product, "-destination", "generic/platform=" + platform,
                "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO", "build"],
               cwd=root, check=True)
    return products


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--platform", required=True, choices=sorted(PLATFORMS))
    args = parser.parse_args()
    run(policy().load_json(os.environ["CI_PLAN"]), args.platform)


if __name__ == "__main__":
    main()
