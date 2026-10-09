#!/usr/bin/env python3
"""Validate a focused xcresult against the reviewed candidate test inventory."""

import json
import hashlib
import re
import sys
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from swift_test_conditions import (conditional_identifiers, runtime_selection, compiled_selection,
                                   runtime_capabilities, runtime_identity, xcresult_runtime)


def collect_cases(node):
    if isinstance(node, dict):
        if node.get("nodeType") == "Test Case":
            yield node
        for value in node.values():
            yield from collect_cases(value)
    elif isinstance(node, list):
        for value in node:
            yield from collect_cases(value)


def validate_inventory(inventory):
    if (not isinstance(inventory, dict) or type(inventory.get("schemaVersion")) is not int or
            inventory["schemaVersion"] != 1):
        return ["invalid-inventory"]
    suites = inventory.get("suites")
    expected = inventory.get("expectedTestIdentifiers")
    if (not isinstance(suites, list) or not suites or
            any(not isinstance(suite, str) or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", suite)
                for suite in suites)):
        return ["invalid-inventory-suites"]
    if (not isinstance(expected, list) or not expected or
            any(not isinstance(item, str) or item.count("/") != 1 or not item.split("/", 1)[1]
                for item in expected)):
        return ["invalid-inventory-identifiers"]
    errors = []
    owners = inventory.get("suiteTargets", dict.fromkeys(suites, "InnoFlowTests"))
    if (not isinstance(owners, dict) or set(owners) != set(suites) or
            any(not isinstance(target, str) or not re.fullmatch(r"InnoFlow(?:Core|Testing|SwiftUIIntegration|Inspector)?Tests", target)
                for target in owners.values())):
        errors.append("invalid-suite-target-ownership")
    if "invalid-suite-target-ownership" in errors:
        return errors
    discovery_targets = inventory.get("discoveryTargets", sorted(set(owners.values())))
    if (not isinstance(discovery_targets, list) or
            any(not isinstance(target, str) or not re.fullmatch(r"InnoFlow(?:Core|Testing|SwiftUIIntegration|SwiftUI|Inspector)?Tests", target)
                for target in discovery_targets) or
            discovery_targets != sorted(set(discovery_targets)) or
            not set(owners.values()) <= set(discovery_targets)):
        errors.append("invalid-discovery-targets")
    if suites != sorted(set(suites)):
        errors.append("duplicate-or-unsorted-suites")
    if expected != sorted(set(expected)):
        errors.append("duplicate-or-unsorted-inventory")
    if sorted({item.split("/", 1)[0] for item in expected}) != suites:
        errors.append("inventory-suite-mismatch")
    diagnostics = inventory.get("expectedFailureTestIdentifiers", [])
    if (not isinstance(diagnostics, list) or
            any(not isinstance(item, str) or item not in expected for item in diagnostics) or
            diagnostics != sorted(set(diagnostics))):
        errors.append("invalid-expected-failure-inventory")
    try:
        conditional_identifiers(inventory)
        runtime_capabilities(inventory)
    except ValueError as error:
        errors.append(str(error))
    return errors


def validate(inventory, summary, tests, compiler_output=None, observed_runtime=None):
    errors = validate_inventory(inventory)
    if errors:
        return errors, 0
    if not isinstance(summary, dict) or not isinstance(tests, dict):
        return ["invalid-result-payload"], 0
    try:
        compiled = compiled_selection(inventory, compiler_output)
        relevant = set(compiled["expectedTestIdentifiers"]) & set(runtime_capabilities(inventory))
        actual_runtime = xcresult_runtime(summary, tests) if relevant else None
        if relevant and runtime_identity(observed_runtime) != actual_runtime:
            raise ValueError("xcresult runtime differs from discovery runtime")
        selected = runtime_selection(inventory, compiler_output, actual_runtime)
    except ValueError as error:
        return [str(error)], 0
    expected = selected["expectedTestIdentifiers"]
    diagnostics = set(selected["expectedFailureTestIdentifiers"])
    unavailable = set(selected["expectedUnavailableTestIdentifiers"])
    if diagnostics & unavailable:
        return ["unavailable diagnostic inventory overlap"], 0
    cases = list(collect_cases(tests))
    actual = [case.get("nodeIdentifier") for case in cases]
    if any(not isinstance(item, str) for item in actual):
        errors.append("missing-test-identifier")
    else:
        actual_counts = Counter(actual)
        expected_counts = Counter(expected)
        missing = sorted((expected_counts - actual_counts).elements())
        unexpected = sorted((actual_counts - expected_counts).elements())
        if missing:
            errors.append("missing=" + repr(missing))
        if unexpected:
            errors.append("unexpected=" + repr(unexpected))
        if len(actual) != len(set(actual)):
            errors.append("duplicate-test-identifier")
    if summary.get("result") != "Passed":
        errors.append("result=" + str(summary.get("result")))
    if len(cases) != len(expected):
        errors.append("inventory-test-count-mismatch")
    # Known diagnostic assertions are required outcomes, not an allowance for
    # arbitrary failures. Counters and exact per-declaration results must agree.
    for key, count in (("totalTestCount", len(cases)),
                       ("passedTests", len(expected) - len(diagnostics) - len(unavailable)),
                       ("failedTests", 0), ("skippedTests", len(unavailable)),
                       ("expectedFailures", len(diagnostics))):
        if type(summary.get(key)) is not int or summary[key] != count:
            errors.append(key + "=" + str(summary.get(key)))
    if summary.get("runtimeWarnings", []) != []:
        errors.append("runtime-warnings=" + repr(summary["runtimeWarnings"]))
    for case in cases:
        identifier = case.get("nodeIdentifier")
        result = ("Skipped" if isinstance(identifier, str) and identifier in unavailable else
                  "Expected Failure" if isinstance(identifier, str) and identifier in diagnostics else "Passed")
        if case.get("result") != result:
            errors.append("unexpected-test-result=" + repr(identifier) + ":" + str(case.get("result")))
    return errors, len(cases)


def validate_discovery(inventory, discovery, compiler_output=None, observed_runtime=None):
    errors = validate_inventory(inventory)
    if errors:
        return errors, []
    if not isinstance(discovery, dict):
        return ["invalid-discovery"], []
    if discovery.get("errors") != []:
        errors.append("discovery-errors=" + repr(discovery.get("errors")))
    values = discovery.get("values")
    if not isinstance(values, list) or len(values) != 1 or not isinstance(values[0], dict):
        errors.append("unexpected-discovery-configurations")
        return errors, []
    value = values[0]
    disabled = value.get("disabledTests", [])
    if not isinstance(disabled, list):
        return errors + ["invalid-disabled-tests"], []
    enabled = value.get("enabledTests")
    if not isinstance(enabled, list):
        return errors + ["missing-enabled-tests"], []
    try:
        selected = runtime_selection(inventory, compiler_output, observed_runtime)
        expected = selected["expectedTestIdentifiers"]
        unavailable = set(selected["expectedUnavailableTestIdentifiers"])
    except ValueError as error:
        return [str(error)], []
    suites = set(inventory["suites"])
    discovered = []
    for entry in enabled + disabled:
        identifier = entry.get("identifier") if isinstance(entry, dict) else None
        if not isinstance(identifier, str):
            errors.append("missing-discovered-identifier")
            continue
        parts = identifier.split("/", 2)
        if len(parts) != 3 or not parts[1] or not parts[2]:
            errors.append("malformed-discovered-identifier=" + identifier)
            continue
        owners = inventory.get("suiteTargets", dict.fromkeys(inventory["suites"], "InnoFlowTests"))
        if parts[0] not in inventory.get("discoveryTargets", set(owners.values())):
            errors.append("unexpected-discovery-target=" + parts[0])
            continue
        suite, test = parts[1:]
        if suite in owners and owners[suite] != parts[0]:
            errors.append("wrong-suite-target=" + identifier)
        if entry in disabled and suite + "/" + test not in unavailable:
            errors.append("unexpected-disabled-test=" + identifier)
        # The reviewed consistency contracts must never silently fall outside
        # the focused run when another suite is introduced. Unrelated suites
        # remain outside this intentionally focused inventory.
        if suite.endswith("ConsistencyTests") and suite not in suites:
            errors.append("unreviewed-consistency-suite=" + suite)
        if suite in suites:
            discovered.append(suite + "/" + test)
    if sorted(discovered) != expected:
        errors.append("discovery-missing=" + repr(sorted(set(expected) - set(discovered))))
        errors.append("discovery-unexpected=" + repr(sorted(set(discovered) - set(expected))))
    if len(discovered) != len(set(discovered)):
        errors.append("duplicate-discovered-identifier")
    return errors, discovered


def main():
    compiler_output = None
    observed_runtime = None
    while len(sys.argv) >= 3 and sys.argv[1] in ("--compiler-version-file", "--runtime-identity-file"):
        content = Path(sys.argv[2]).read_text(encoding="utf-8")
        if sys.argv[1] == "--compiler-version-file":
            compiler_output = content
        else:
            observed_runtime = json.loads(content)
        del sys.argv[1:3]
    if len(sys.argv) == 4 and sys.argv[1] == "discover":
        with open(sys.argv[2], encoding="utf-8") as stream:
            inventory = json.load(stream)
        with open(sys.argv[3], encoding="utf-8") as stream:
            discovery = json.load(stream)
        errors, discovered = validate_discovery(inventory, discovery, compiler_output, observed_runtime)
        if errors:
            print("[focused-runtime] FAILED " + " ".join(errors), file=sys.stderr)
            raise SystemExit(1)
        digest = hashlib.sha256(("\n".join(sorted(discovered)) + "\n").encode()).hexdigest()
        print("[focused-runtime] DISCOVERY tests=" + str(len(discovered)) + " sha256=" + digest)
        return
    if len(sys.argv) != 4:
        raise SystemExit("usage: validate-focused-runtime-result.py [--compiler-version-file FILE] [discover] INVENTORY SUMMARY [TESTS]")
    with open(sys.argv[1], encoding="utf-8") as stream:
        inventory = json.load(stream)
    with open(sys.argv[2], encoding="utf-8") as stream:
        summary = json.load(stream)
    with open(sys.argv[3], encoding="utf-8") as stream:
        tests = json.load(stream)
    errors, count = validate(inventory, summary, tests, compiler_output, observed_runtime)
    if errors:
        print("[focused-runtime] FAILED " + " ".join(errors), file=sys.stderr)
        raise SystemExit(1)
    print("[focused-runtime] PASS declarations=" + str(count) +
          " executed=" + str(count - summary["skippedTests"]) +
          " unavailable=" + str(summary["skippedTests"]))


if __name__ == "__main__":
    main()
