#!/usr/bin/env python3
"""Exact, lane-isolated SwiftPM download caches; never build/test evidence (stdlib)."""

import argparse
import hashlib
import json
import math
import os
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
import sys
import time

SCHEMA = 1
CACHE_PATHS = (
    "~/Library/Caches/org.swift.swiftpm/repositories",
    "~/Library/Caches/org.swift.swiftpm/prebuilts",
)
SAMPLE = "Examples/InnoFlowSampleApp"
REQUIRED_INPUTS = {
    "Package.swift", "Package.resolved",
    SAMPLE + "/InnoFlowSampleAppPackage/Package.swift",
    SAMPLE + "/InnoFlowSampleAppPackage/Package.resolved",
    SAMPLE + "/InnoFlowSampleApp.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
}
PROFILES = {
    "tests": {"configuration": "debug", "source-fallback": True},
    "release-tests": {"configuration": "release"},
    "api-compatibility": {"contracts": "public-api-and-migration-consumer"},
    "thread-sanitizer": {"sanitizer": "thread"},
    "address-sanitizer": {"sanitizer": "address"},
    "sample-tests": {"configuration": "debug", "package": "sample"},
    "package-builds": {"platforms": ("macOS", "iOS", "tvOS", "watchOS", "visionOS")},
    "focused-runtime-tests": {"platforms": ("iOS", "tvOS", "watchOS", "visionOS"), "simulator": True},
    "sample-package-builds": {"platforms": ("tvOS", "watchOS", "visionOS"), "package": "sample"},
    "sample-build": {"platform": "iOS", "package": "sample-app"},
    "sample-ui-tests": {"platform": "iOS", "package": "sample-app", "simulator": True},
    "swift-syntax-compatibility": {"versions": ("603.0.0", "604.0.0")},
    "coverage": {"configuration": "debug", "instrumentation": "code-coverage"},
}
PLATFORM_SDKS = {
    "macOS": ("macosx", "macosx"), "iOS": ("iphoneos", "iphonesimulator"),
    "tvOS": ("appletvos", "appletvsimulator"), "watchOS": ("watchos", "watchsimulator"),
    "visionOS": ("xros", "xrsimulator"),
}
MANIFEST = re.compile(r"Package(?:@swift-\d+(?:\.\d+)*)?\.swift\Z")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(value):
    require(isinstance(value, str) and bool(value.strip()), "empty cache fingerprint input")
    return hashlib.sha256(value.encode()).hexdigest()


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "duplicate JSON field: " + key)
        result[key] = value
    return result


def decode(value):
    return json.loads(value, object_pairs_hook=unique_object)


def relative_path(value):
    require(isinstance(value, str) and bool(value) and "\\" not in value and
            all(ord(c) >= 32 for c in value), "invalid relative input path")
    path = PurePosixPath(value)
    require(not path.is_absolute() and str(path) == value and
            not any(p in (".", "..") for p in path.parts), "unsafe relative input path")
    return path


def profile_contract(profile, variant):
    require(profile in PROFILES, "unknown cache profile")
    contract = PROFILES[profile]
    choices = contract.get("platforms", contract.get("versions", ("default",)))
    require(variant in choices, "invalid or missing cache profile variant")
    return contract


def lock_pins(contents):
    data = decode(contents)
    require(isinstance(data, dict) and type(data.get("version")) is int and
            data["version"] in (2, 3), "unsupported Package.resolved schema")
    pins = data.get("pins")
    require(isinstance(pins, list) and bool(pins), "empty or missing resolved pins")
    identities = set()
    for pin in pins:
        require(isinstance(pin, dict), "malformed resolved pin")
        identity, state = pin.get("identity"), pin.get("state")
        require(isinstance(identity, str) and re.fullmatch(r"[a-z0-9][a-z0-9._-]*", identity) and
                identity not in identities, "missing or duplicate resolved identity")
        identities.add(identity)
        require(pin.get("kind") == "remoteSourceControl" and
                isinstance(pin.get("location"), str) and pin["location"].startswith("https://"),
                "unsupported resolved source")
        require(isinstance(state, dict) and isinstance(state.get("revision"), str) and
                re.fullmatch(r"[0-9a-f]{40}", state["revision"]) and
                isinstance(state.get("version"), str) and
                re.fullmatch(r"\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?", state["version"]) and
                "branch" not in state, "resolved dependencies require an exact release and revision")
    return pins


def fingerprint(inputs, toolchain, profile, variant="default", contract=None):
    lane = profile_contract(profile, variant)
    require(isinstance(inputs, dict) and REQUIRED_INPUTS <= inputs.keys(), "missing manifest or resolved lock")
    hashes, locks = {}, {}
    for path, contents in sorted(inputs.items()):
        name = relative_path(path).name
        require(MANIFEST.fullmatch(name) or name in ("Package.resolved", "project.pbxproj"),
                "unexpected dependency input")
        hashes[path] = digest(contents)
        if name == "Package.resolved":
            locks[path] = lock_pins(contents)
        elif MANIFEST.fullmatch(name):
            require(re.match(r"\s*// swift-tools-version:\s*\d+\.\d+", contents), "invalid package manifest")
    require(isinstance(toolchain, dict) and set(toolchain) == {
        "swift", "swift-path", "xcode", "developer-dir", "os-version", "os-build", "architecture", "sdks"
    }, "incomplete toolchain identity")
    for key, value in toolchain.items():
        if key != "sdks":
            digest(value)
    compiler = re.search(r"^Apple Swift version (6\.[34])(?:\.\d+)?\s+\([^\n]+\)", toolchain["swift"], re.M)
    require(compiler and re.fullmatch(r"Xcode \d+(?:\.\d+)*\nBuild version [A-Za-z0-9]+", toolchain["xcode"]),
            "unsupported or incomplete Apple Swift/Xcode identity")
    require(toolchain["architecture"] in ("arm64", "x86_64"), "unsupported architecture")
    require(re.fullmatch(r"\d+(?:\.\d+)+", toolchain["os-version"]) and
            re.fullmatch(r"[A-Za-z0-9]+", toolchain["os-build"]), "invalid macOS identity")
    for key in ("swift-path", "developer-dir"):
        require(Path(toolchain[key]).is_absolute(), "nonabsolute toolchain path")
    sdks = toolchain["sdks"]
    require(isinstance(sdks, dict) and bool(sdks), "missing SDK identity")
    for sdk, identity in sdks.items():
        require(isinstance(sdk, str) and re.fullmatch(r"[a-z]+\d+(?:\.\d+)*", sdk) and
                isinstance(identity, dict) and set(identity) == {"version", "build", "path"}, "malformed SDK identity")
        require(isinstance(identity["version"], str) and re.fullmatch(r"\d+(?:\.\d+)*", identity["version"]) and
                isinstance(identity["build"], str) and re.fullmatch(r"[A-Za-z0-9]+", identity["build"]),
                "incomplete SDK build identity: " + sdk + "; SDK metadata=" + repr(sdks))
        require(isinstance(identity["path"], str) and Path(identity["path"]).is_absolute() and
                all(ord(c) >= 32 for c in identity["path"]), "invalid resolved SDK path: " + sdk + "; SDK metadata=" + repr(sdks))
    needed = {"macosx"}
    platform = lane.get("platform", variant if "platforms" in lane else None)
    if platform:
        needed.add(PLATFORM_SDKS[platform][bool(lane.get("simulator"))])
    available = {re.sub(r"[\d.]+$", "", sdk) for sdk in sdks}
    require(needed <= available, "required profile SDK is missing")
    if profile == "swift-syntax-compatibility":
        pins = [pin for pin in locks["Package.resolved"] if pin["identity"] == "swift-syntax"]
        require(len(pins) == 1 and pins[0]["state"]["version"] == variant,
                "fingerprint compatibility only after resolving and auditing its requested lock")
        require(compiler[1] == {"603.0.0": "6.3", "604.0.0": "6.4"}[variant],
                "compatibility profile/compiler mismatch")
    identity = {"schema": SCHEMA, "profile": profile, "variant": variant, "lane": decode(canonical(lane)),
                "inputs": hashes, "toolchain": toolchain,
                "implementation": digest(contract if contract is not None else Path(__file__).read_text()),
                "paths": list(CACHE_PATHS)}
    return {"dependency-key": f"innoflow-swiftpm-deps-v{SCHEMA}-{profile}-{variant}-" + digest(canonical(identity)),
            "dependency-paths": list(CACHE_PATHS), "cache-profile": profile, "cache-variant": variant,
            "identity": identity}


def command(*args):
    return subprocess.check_output(args, text=True).strip()


def dependency_input(path):
    return bool(MANIFEST.fullmatch(PurePosixPath(path).name)) or PurePosixPath(path).name in (
        "Package.resolved", "project.pbxproj")


def repository_inputs(root):
    tracked = set(command("git", "-C", str(root), "ls-files", "-z").split("\0")) - {""}
    paths = sorted(path for path in tracked if dependency_input(path))
    require(REQUIRED_INPUTS <= set(paths), "required manifests/locks must be tracked")
    others = command("git", "-C", str(root), "ls-files", "--others", "--exclude-standard", "-z").split("\0")
    require(not any(dependency_input(path) for path in others if path), "untracked dependency input")
    inputs = {}
    for path in paths:
        relative_path(path)
        file = root / path
        require(file.is_file() and not any(parent.is_symlink() for parent in (file, *file.parents)) and
                file.resolve().is_relative_to(root), "missing or symlinked dependency input: " + path)
        inputs[path] = file.read_text()
    return inputs


def sdk_identifiers(listing):
    """Keep every occurrence for resolution checks; merge only identical rows.

    Xcode 26.6's hosted output repeats the identical macOS SDK row. A repeated
    identifier is safe only when section and display also agree; an unknown
    format or conflicting row is still an error, not a reason to drop a SDK.
    """
    names, rows, section = [], {}, None

    def reject(reason):
        raise ValueError("SDK inventory rejected: " + reason + "; parsed=" + repr(names) +
                         "; duplicates=" + repr(sorted(name for name in set(names) if names.count(name) > 1)) +
                         "; xcodebuild output=" + repr(listing))

    if not isinstance(listing, str) or not listing.strip():
        reject("missing SDK inventory")
    for line in listing.splitlines():
        line = line.strip()
        if not line:
            continue
        if re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9 ()/-]* SDKs:", line):
            section = line
            continue
        match = re.fullmatch(r"(.+?)\s+-sdk\s+([a-z]+[0-9]+(?:\.[0-9]+)*)", line)
        if not match or section is None:
            reject("unrecognized SDK row or missing section")
        display, name = " ".join(match[1].split()), match[2]
        names.append(name)
        row = (section, display)
        if name in rows and rows[name] != row:
            reject("conflicting rows for " + name)
        rows[name] = row
    if not names:
        reject("missing SDK inventory")
    return names


def toolchain_identity():
    listing = command("xcodebuild", "-showsdks")
    names = sdk_identifiers(listing)
    sdks = {}
    # Resolve every occurrence before coalescing, including repeated rows.
    # Identical presentation cannot hide changed SDK version/build/path data.
    for name in names:
        identity = {}
        for field, flag in (("version", "--show-sdk-version"), ("build", "--show-sdk-build-version"),
                            ("path", "--show-sdk-path")):
            try:
                identity[field] = command("xcrun", "--sdk", name, flag)
            except (OSError, subprocess.CalledProcessError) as error:
                raise ValueError("SDK query failed: " + name + " " + flag + "; partial SDK metadata=" +
                                 repr({**sdks, name: identity}) + "; command error=" + str(error) +
                                 "; partial output=" + repr(getattr(error, "output", None))) from error
        require(name not in sdks or sdks[name] == identity,
                "SDK resolution changed for repeated identifier: " + name)
        sdks[name] = identity
    return {
        "swift": command("swift", "--version"), "swift-path": command("xcrun", "--find", "swift"),
        "xcode": command("xcodebuild", "-version"),
        "developer-dir": os.environ.get("DEVELOPER_DIR") or command("xcode-select", "-p"),
        "os-version": command("sw_vers", "-productVersion"), "os-build": command("sw_vers", "-buildVersion"),
        "architecture": command("uname", "-m"), "sdks": sdks,
    }


def observations(home):
    """Record metadata only, without traversing symlinks or inspecting build trees."""
    result = {}
    for cache in CACHE_PATHS:
        base = home / cache.removeprefix("~/")
        require(not any(path.is_symlink() for path in (base, *base.parents)), "symlinked cache root")
        if not base.exists():
            continue
        require(base.is_dir(), "cache root is not a directory")
        for directory, folders, files in os.walk(base, followlinks=False, onerror=lambda error: (_ for _ in ()).throw(error)):
            for name in sorted(folders + files):
                path = Path(directory) / name
                info = path.lstat()
                key = base.name + "/" + path.relative_to(base).as_posix()
                relative_path(key)
                if stat.S_ISREG(info.st_mode):
                    result[key] = ["file", info.st_size, info.st_mtime_ns]
                elif stat.S_ISLNK(info.st_mode):
                    result[key] = ["symlink", os.readlink(path), info.st_mtime_ns]
                else:
                    require(stat.S_ISDIR(info.st_mode), "unsupported cache entry")
    return result


def validate_observations(value):
    require(isinstance(value, dict), "missing or malformed cache observation")
    for path, entry in value.items():
        parts = relative_path(path).parts
        require(len(parts) > 1 and parts[0] in ("repositories", "prebuilts"), "observation outside cache allowlist")
        require(isinstance(entry, list) and len(entry) == 3 and type(entry[2]) is int and entry[2] >= 0,
                "malformed cache entry metadata")
        require((entry[0] == "file" and type(entry[1]) is int and entry[1] >= 0) or
                (entry[0] == "symlink" and isinstance(entry[1], str) and bool(entry[1])), "invalid cache entry kind")


def context(root, home):
    return {"root": str(root), "home": str(home), **{
        name: os.environ.get(name, "") for name in ("GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT", "GITHUB_JOB")}}


def elapsed(now, before):
    require(type(before) in (int, float) and math.isfinite(before) and 0 <= before <= now,
            "missing or invalid observation timestamp")
    return round(now - before, 3)


def write_state(path, data):
    require(not path.is_symlink(), "symlinked cache state")
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    require(not temporary.is_symlink(), "symlinked temporary cache state")
    temporary.write_text(json.dumps(data, indent=2, allow_nan=False) + "\n")
    temporary.replace(path)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("fingerprint", "restored", "report"))
    parser.add_argument("--profile", required=True, choices=PROFILES)
    parser.add_argument("--variant", default="default")
    parser.add_argument("--root", type=Path, default=Path("."))
    parser.add_argument("--state", type=Path)
    args = parser.parse_args(argv)
    try:
        profile_contract(args.profile, args.variant)
        root, home = args.root.resolve(), Path.home().resolve()
        # Validation scripts may replace .build; observations must survive it.
        state = args.state or root / "build" / "ci-cache.json"
        current = fingerprint(repository_inputs(root), toolchain_identity(), args.profile, args.variant)
        now = time.time()
        if args.command == "fingerprint":
            output_path = os.environ["GITHUB_OUTPUT"]
            require(bool(output_path), "missing GITHUB_OUTPUT")
            data = {"schema": SCHEMA, "phase": "fingerprinted", "fingerprint": current,
                    "context": context(root, home), "started": now}
            write_state(state, data)
            with open(output_path, "a") as output:
                for key in ("dependency-key", "cache-profile", "cache-variant"):
                    output.write(key + "=" + current[key] + "\n")
                output.write("dependency-paths<<CACHE_PATHS\n" + "\n".join(CACHE_PATHS) + "\nCACHE_PATHS\n")
            print(json.dumps({key: value for key, value in current.items() if key != "identity"}, indent=2))
        else:
            require(not state.is_symlink(), "symlinked cache state")
            data = decode(state.read_text())
            require(isinstance(data, dict) and type(data.get("schema")) is int and data["schema"] == SCHEMA and
                    data.get("fingerprint") == current and data.get("context") == context(root, home),
                    "cache identity or execution context changed/malformed")
            elapsed(now, data.get("started"))
            entries = observations(home)
            validate_observations(entries)
            if args.command == "restored":
                require(data.get("phase") == "fingerprinted", "restore observation missing or out of order")
                hit = os.environ["DEPENDENCY_CACHE_HIT"]
                require(hit in ("true", "false", ""), "invalid dependency cache-hit output")
                data.update(phase="restored", restored=entries, dependency_hit=hit,
                            restore_seconds=elapsed(now, data["started"]), build_started=now)
                write_state(state, data)
                print(f"Observed {len(entries)} dependency-cache entries; cache hits are not verification.")
            else:
                require(data.get("phase") == "restored", "report requires a fresh restore observation")
                before = data.get("restored")
                validate_observations(before)
                require(data.get("dependency_hit") in ("true", "false", ""), "missing or invalid cache-hit observation")
                restore = data.get("restore_seconds")
                require(type(restore) in (int, float) and math.isfinite(restore) and restore >= 0 and
                        restore == elapsed(data["build_started"], data["started"]), "invalid restore elapsed observation")
                report = {"dependency_key": current["dependency-key"], "cache_profile": args.profile,
                          "cache_variant": args.variant, "dependency_cache_hit": data["dependency_hit"],
                          "restore_elapsed_seconds": restore,
                          "validation_elapsed_seconds": elapsed(now, data.get("build_started")),
                          "restored_entries": len(before), "entries_after": len(entries),
                          "restored_entries_unchanged": sum(entries.get(path) == value for path, value in before.items()),
                          "verification": "not-evaluated-by-cache"}
                print(json.dumps(report, indent=2))
                if os.environ.get("GITHUB_STEP_SUMMARY"):
                    with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as summary:
                        summary.write("\n### CI dependency cache observations\n\n")
                        for key, value in report.items():
                            summary.write(f"- {key}: {value}\n")
                        summary.write("\nOnly repository mirrors and downloaded prebuilts are cached. Build products and test/release receipts are never restored. A cache hit or unchanged size/mtime is not verification. All selected assertions still run. Timings include intervening steps; no speedup or validation success is inferred.\n")
                data.update(phase="reported", report=report)
                write_state(state, data)
        return 0
    except (ValueError, KeyError, TypeError, OSError, subprocess.CalledProcessError) as error:
        print("CI cache rejected: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
