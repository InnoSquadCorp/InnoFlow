#!/usr/bin/env python3
"""Select one physical official Swift 6.4 release, preserving alias evidence."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess


def select(root, evidence, run=subprocess.run):
    evidence.mkdir(parents=True, exist_ok=True)
    inventory, matches = [], {}
    for info in sorted(root.glob("*.xctoolchain/Info.plist")):
        bundle = info.parent.resolve(strict=True)
        swift = bundle / "usr/bin/swift"
        if not swift.is_file():
            continue
        result = run([str(swift), "--version"], capture_output=True, text=True, timeout=30)
        entry = {"path": str(info.parent), "resolved_path": str(bundle),
                 "stdout": result.stdout, "stderr": result.stderr,
                 "returncode": result.returncode}
        inventory.append(entry)
        if (result.returncode == 0
                and re.search(r"\bSwift version 6\.4(?:\.0)?(?:\s|\()", result.stdout)
                and re.search(r"\(swift-6\.4(?:\.0)?-RELEASE(?:[ )])", result.stdout)):
            matches.setdefault(bundle, entry)
    (evidence / "inventory.json").write_text(json.dumps(inventory, indent=2) + "\n")
    if len(matches) != 1:
        raise ValueError("Expected exactly one physical official Swift 6.4.0 release toolchain")
    bundle, entry = next(iter(matches.items()))
    info = bundle / "Info.plist"
    identifier = plistlib.loads(info.read_bytes())["CFBundleIdentifier"]
    if not isinstance(identifier, str) or not re.fullmatch(r"[A-Za-z0-9._-]+", identifier):
        raise ValueError("Invalid installed toolchain identifier")
    shutil.copyfile(info, evidence / "selected-Info.plist")
    selected = {**entry, "path": str(bundle), "identifier": identifier,
                "aliases": [item["path"] for item in inventory
                            if item["resolved_path"] == str(bundle)]}
    (evidence / "selected.json").write_text(json.dumps(selected, indent=2) + "\n")
    (evidence / "identifier.txt").write_text(identifier + "\n")
    (evidence / "bin-path.txt").write_text(str(bundle / "usr/bin") + "\n")
    return selected


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    args = parser.parse_args()
    selected = select(args.root, args.evidence)
    with Path(os.environ["GITHUB_ENV"]).open("a") as stream:
        stream.write("TOOLCHAINS=" + selected["identifier"] + "\n")
    with Path(os.environ["GITHUB_PATH"]).open("a") as stream:
        stream.write(str(Path(selected["path"]) / "usr/bin") + "\n")


if __name__ == "__main__":
    main()
