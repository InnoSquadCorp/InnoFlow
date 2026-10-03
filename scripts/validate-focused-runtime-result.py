#!/usr/bin/env python3
"""Validate a focused xcresult against the reviewed candidate test inventory."""

import json
import hashlib
import re
import sys
from collections import Counter


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
    if suites != sorted(set(suites)):
        errors.append("duplicate-or-unsorted-suites")
    if expected != sorted(set(expected)):
        errors.append("duplicate-or-unsorted-inventory")
    if sorted({item.split("/", 1)[0] for item in expected}) != suites:
        errors.append("inventory-suite-mismatch")
    return errors


def validate(inventory, summary, tests):
    errors = validate_inventory(inventory)
    if errors:
        return errors, 0
    expected = inventory["expectedTestIdentifiers"]
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
    if summary.get("totalTestCount") != len(cases):
        errors.append("summary-test-count-mismatch")
    if len(cases) != len(expected):
        errors.append("inventory-test-count-mismatch")
    for key in ("failedTests", "skippedTests", "expectedFailures"):
        if summary.get(key, 0) != 0:
            errors.append(key + "=" + str(summary.get(key)))
    if summary.get("runtimeWarnings"):
        errors.append("runtime-warnings=" + str(len(summary["runtimeWarnings"])))
    if any(case.get("result") != "Passed" for case in cases):
        errors.append("non-passed-test-case")
    return errors, len(cases)


def validate_discovery(inventory, discovery):
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
    if not isinstance(disabled, list) or disabled:
        errors.append("disabled-tests=" + repr(disabled))
    enabled = value.get("enabledTests")
    if not isinstance(enabled, list):
        return errors + ["missing-enabled-tests"], []
    expected = inventory["expectedTestIdentifiers"]
    suites = set(inventory["suites"])
    discovered = []
    for entry in enabled:
        identifier = entry.get("identifier") if isinstance(entry, dict) else None
        if not isinstance(identifier, str):
            errors.append("missing-discovered-identifier")
            continue
        parts = identifier.split("/", 2)
        if len(parts) != 3 or not parts[1] or not parts[2]:
            errors.append("malformed-discovered-identifier=" + identifier)
            continue
        if parts[0] != "InnoFlowTests":
            errors.append("unexpected-discovery-target=" + parts[0])
            continue
        suite, test = parts[1:]
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
    if len(sys.argv) == 4 and sys.argv[1] == "discover":
        with open(sys.argv[2], encoding="utf-8") as stream:
            inventory = json.load(stream)
        with open(sys.argv[3], encoding="utf-8") as stream:
            discovery = json.load(stream)
        errors, discovered = validate_discovery(inventory, discovery)
        if errors:
            print("[focused-runtime] FAILED " + " ".join(errors), file=sys.stderr)
            raise SystemExit(1)
        digest = hashlib.sha256(("\n".join(sorted(discovered)) + "\n").encode()).hexdigest()
        print("[focused-runtime] DISCOVERY tests=" + str(len(discovered)) + " sha256=" + digest)
        return
    if len(sys.argv) != 4:
        raise SystemExit("usage: validate-focused-runtime-result.py [discover] INVENTORY SUMMARY TESTS")
    with open(sys.argv[1], encoding="utf-8") as stream:
        inventory = json.load(stream)
    with open(sys.argv[2], encoding="utf-8") as stream:
        summary = json.load(stream)
    with open(sys.argv[3], encoding="utf-8") as stream:
        tests = json.load(stream)
    errors, count = validate(inventory, summary, tests)
    if errors:
        print("[focused-runtime] FAILED " + " ".join(errors), file=sys.stderr)
        raise SystemExit(1)
    print("[focused-runtime] PASS tests=" + str(count))


if __name__ == "__main__":
    main()
