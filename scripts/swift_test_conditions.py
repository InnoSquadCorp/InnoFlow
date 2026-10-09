"""Reviewed declaration selection. This is source inventory, never execution evidence."""

import json
import re
import sys
from pathlib import Path
import subprocess


COMPILER_CONDITION = ["#if compiler(>=6.4)"]
HOST_CONDITION = ["#if os(macOS) || os(Linux)"]
HOST_TEST = "CompiledHarnessCacheTests/preservesProcessIsolation()"
DID_SET_CAPABILITY = "observation-didset-os27"
DID_SET_TESTS = (
    "SnapshotBoundaryConsistencyTests/didSetPrecedesProjectionRefresh(animated:observed:)",
    "SnapshotBoundaryConsistencyTests/didSetRegistrationDoesNotRecomputeAnUnchangedMemoizedSelection()",
    "SnapshotBoundaryConsistencyTests/didSetRegistrationPreservesSelectorCallsAndReturnedValues(memoize:changed:)",
)
DID_SET_AVAILABILITY = "@available(macOS 27.0, iOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *)"
REVIEWED_RUNTIME_VERSIONS = {
    "macOS": {(27, 0)},
    "iOS Simulator": {(18, 5), (27, 0)},
    "tvOS Simulator": {(18, 5), (27, 0)},
    "watchOS Simulator": {(11, 5), (27, 0)},
    "visionOS Simulator": {(2, 5), (27, 0)},
}


def source_capabilities(inventory):
    capabilities = {}
    for test in inventory["tests"]:
        identifier = test["identifier"]
        attributes = test.get("availabilityAttributes", [])
        if identifier in DID_SET_TESTS:
            if (test["target"] != "InnoFlowCoreTests" or test["conditionalContexts"] != COMPILER_CONDITION or
                    attributes != [DID_SET_AVAILABILITY]):
                raise ValueError("didSet capability must preserve compiler and function availability: " + identifier)
            capabilities[identifier] = DID_SET_CAPABILITY
        elif attributes:
            raise ValueError("unreviewed test availability: " + identifier)
    has_snapshot_suite = any(test["identifier"].startswith("SnapshotBoundaryConsistencyTests/") for test in inventory["tests"])
    if has_snapshot_suite and set(capabilities) != set(DID_SET_TESTS):
        raise ValueError("didSet capability declarations must retain all three tests")
    return capabilities


def runtime_capabilities(inventory):
    capabilities = inventory.get("requiredCapabilitiesByIdentifier", {})
    if not isinstance(capabilities, dict):
        raise ValueError("invalid runtime capability inventory")
    if capabilities or set(DID_SET_TESTS) & set(inventory["expectedTestIdentifiers"]):
        expected = dict.fromkeys(DID_SET_TESTS, DID_SET_CAPABILITY)
        if capabilities != expected or not set(capabilities) <= set(inventory["expectedTestIdentifiers"]):
            raise ValueError("unreviewed runtime capability identifiers")
        if set(capabilities) & set(inventory.get("expectedFailureTestIdentifiers", [])):
            raise ValueError("unavailable capability cannot be an expected diagnostic")
        conditions = conditional_identifiers(inventory)
        if any(conditions.get(identifier) != COMPILER_CONDITION for identifier in capabilities):
            raise ValueError("runtime capability compiler condition mismatch")
    return capabilities


def runtime_identity(identity):
    if not isinstance(identity, dict):
        raise ValueError("missing actual runtime identity")
    platform, version = identity.get("platform"), identity.get("os")
    if platform not in REVIEWED_RUNTIME_VERSIONS or not isinstance(version, str) or not re.fullmatch(r"[0-9]+\.[0-9]+(?:\.[0-9]+)?", version):
        raise ValueError("unknown runtime platform or version")
    parts = tuple(map(int, version.split(".")))
    if parts[:2] not in REVIEWED_RUNTIME_VERSIONS[platform]:
        raise ValueError("unreviewed runtime version: " + platform + " " + version)
    device = identity.get("deviceId")
    if platform != "macOS" and (not isinstance(device, str) or not device):
        raise ValueError("missing actual runtime device identity")
    normalized = dict(identity, os=".".join(map(str, parts[:2] if len(parts) == 2 or parts[2] == 0 else parts)))
    return normalized


def xcresult_runtime(summary, tests):
    identities = []
    configurations = summary.get("devicesAndConfigurations", [])
    devices = tests.get("devices", [])
    if not isinstance(configurations, list) or not isinstance(devices, list):
        raise ValueError("invalid xcresult runtime identity")
    raw = [item.get("device") if isinstance(item, dict) else None for item in configurations] + devices
    for device in raw:
        if not isinstance(device, dict):
            raise ValueError("invalid xcresult device")
        identities.append(runtime_identity({"platform": device.get("platform"),
            "os": device.get("osVersion"), "deviceId": device.get("deviceId")}))
    if not identities or any(item != identities[0] for item in identities):
        raise ValueError("missing or conflicting xcresult runtime identity")
    return identities[0]


def simulator_runtime(destination, devices, runtimes):
    fields = dict(part.split("=", 1) for part in destination.split(","))
    if set(fields) != {"platform", "id"}:
        raise ValueError("capability discovery requires a resolved simulator destination ID")
    matches = []
    for runtime_id, entries in devices["devices"].items():
        for device in entries:
            if device.get("udid") == fields["id"] and device.get("isAvailable") is True:
                for runtime in runtimes["runtimes"]:
                    if runtime.get("identifier") == runtime_id and runtime.get("isAvailable") is True:
                        kinds = {"iOS": "iOS Simulator", "tvOS": "tvOS Simulator",
                                 "watchOS": "watchOS Simulator", "xrOS": "visionOS Simulator"}
                        platform = next((value for key, value in kinds.items()
                            if runtime_id.startswith("com.apple.CoreSimulator.SimRuntime." + key + "-")), None)
                        matches.append(runtime_identity({"platform": platform,
                            "os": runtime.get("version"), "deviceId": device["udid"]}))
    if len(matches) != 1 or matches[0]["platform"] != fields["platform"]:
        raise ValueError("ambiguous or mismatched actual simulator runtime")
    return matches[0]


def compiler_version(output):
    if not isinstance(output, str):
        raise ValueError("missing Swift compiler identity")
    versions = re.findall(r"\bSwift version ([0-9]+\.[0-9]+(?:\.[0-9]+)*)(?=[\s;(]|$)", output)
    if len(set(versions)) != 1:
        raise ValueError("missing or conflicting Swift compiler identity")
    version = tuple(map(int, versions[0].split(".")))
    if version[:2] not in ((6, 3), (6, 4)):
        raise ValueError("unreviewed Swift compiler identity: " + versions[0])
    return ".".join(map(str, version[:2]))


def active(conditions, version, *, identifier=None, host=False):
    if conditions == []:
        return True
    if conditions == COMPILER_CONDITION:
        return version == "6.4"
    if host and identifier == HOST_TEST and conditions == HOST_CONDITION:
        return True
    # In particular, #elseif/#else cannot be evaluated from a lone clause:
    # preceding branches matter. Reject instead of guessing an active branch.
    raise ValueError("unreviewed conditional Swift test declaration: " + repr(conditions))


def host_counts(inventory):
    source_capabilities(inventory)
    tests = inventory["tests"]
    counts = {}
    for version in ("6.3", "6.4"):
        selected = [test for test in tests if active(test["conditionalContexts"], version,
                    identifier=test["identifier"], host=True)]
        counts[version] = len(selected)
    baseline = [test for test in tests if test["target"] == "InnoFlowTests" and
                test["identifier"].startswith("EffectTimingBaselineGate/")]
    if len(baseline) != 1 or baseline[0]["conditionalContexts"] != []:
        raise ValueError("isolated timing baseline inventory changed")
    counts["full-principle"] = counts["6.4"] * 2 + len(baseline)
    return counts


def conditional_identifiers(inventory):
    conditions = inventory.get("conditionalContextsByIdentifier", {})
    if not isinstance(conditions, dict):
        raise ValueError("invalid conditional runtime inventory")
    for identifier, contexts in conditions.items():
        if identifier not in inventory["expectedTestIdentifiers"] or not contexts:
            raise ValueError("invalid conditional runtime identifier: " + repr(identifier))
        # Validate every branch regardless of whether this compiler selects it.
        active(contexts, "6.3")
    return conditions


def compiled_selection(inventory, output):
    conditions = conditional_identifiers(inventory)
    runtime_capabilities(inventory)
    version = compiler_version(output) if conditions or output is not None else None
    identifiers = [identifier for identifier in inventory["expectedTestIdentifiers"]
                   if active(conditions.get(identifier, []), version)]
    return {"expectedTestIdentifiers": identifiers,
            "expectedFailureTestIdentifiers": [identifier for identifier in
                inventory.get("expectedFailureTestIdentifiers", []) if identifier in identifiers],
            "compilerVersion": version}


def runtime_selection(inventory, output, runtime=None):
    selected = compiled_selection(inventory, output)
    capabilities = runtime_capabilities(inventory)
    relevant = [identifier for identifier in selected["expectedTestIdentifiers"] if identifier in capabilities]
    unavailable = []
    if relevant:
        runtime = runtime_identity(runtime)
        if int(runtime["os"].split(".")[0]) < 27:
            unavailable = relevant
    return dict(selected, expectedUnavailableTestIdentifiers=unavailable,
                runtimeIdentity=runtime if relevant else None)


def capture_runtime(arguments):
    inventory_path, compiler_path, destination, output_path = arguments
    inventory = json.loads(Path(inventory_path).read_text())
    selected = compiled_selection(inventory, Path(compiler_path).read_text())
    relevant = set(selected["expectedTestIdentifiers"]) & set(runtime_capabilities(inventory))
    identity = None
    if relevant:
        devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"]))
        runtimes = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "runtimes", "-j"]))
        identity = simulator_runtime(destination, devices, runtimes)
    Path(output_path).write_text(json.dumps(identity) + "\n")


def main():
    if len(sys.argv) == 6 and sys.argv[1] == "capture-runtime":
        capture_runtime(sys.argv[2:])
        return
    request = json.load(sys.stdin)
    operation = request["operation"]
    if operation == "host-counts":
        result = host_counts(request["inventory"])
    elif operation == "runtime-selection":
        result = runtime_selection(request["inventory"], request.get("compilerOutput"), request.get("runtimeIdentity"))
    elif operation == "compiled-selection":
        result = compiled_selection(request["inventory"], request.get("compilerOutput"))
    elif operation == "source-capabilities":
        result = source_capabilities(request["inventory"])
    elif operation == "xcresult-runtime":
        result = xcresult_runtime(request["summary"], request["tests"])
    elif operation == "runtime-identity":
        result = runtime_identity(request.get("runtimeIdentity"))
    elif operation == "compiler-version":
        result = compiler_version(request.get("compilerOutput"))
    else:
        raise ValueError("unknown inventory operation")
    print(json.dumps(result))


if __name__ == "__main__":
    try:
        main()
    except (KeyError, TypeError, ValueError) as error:
        sys.exit("[swift-test-inventory] " + str(error))
