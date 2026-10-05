#!/usr/bin/env python3
"""Run an external executable with the selected Xcode's test-support rpaths.

Unlike `swift test`, `swift run` does not supply Testing.framework's runtime
search paths. Embed verified rpaths in the fixture executable, without changing
product manifests or injecting a loader environment into compiler processes.
"""
import os
from pathlib import Path
import subprocess
import sys


def runtime_flags(platform=sys.platform):
    if platform != "darwin":
        return []
    developer = Path(subprocess.check_output(["xcode-select", "-p"], text=True).strip())
    selected = Path(subprocess.check_output(
        ["xcrun", "--sdk", "macosx", "--show-sdk-platform-path"], text=True).strip())
    if not developer.is_absolute() or not selected.is_absolute():
        raise ValueError("Selected Xcode paths must be absolute")
    developer, selected = developer.resolve(strict=True), selected.resolve(strict=True)
    if selected != (developer / "Platforms/MacOSX.platform").resolve(strict=True) or developer not in selected.parents:
        raise ValueError("Selected macOS platform is outside Xcode")
    paths = [selected / "Developer/Library/Frameworks",
             selected / "Developer/Library/PrivateFrameworks",
             selected / "Developer/usr/lib"]
    for path in paths:
        if not path.is_dir() or selected not in path.resolve(strict=True).parents:
            raise ValueError("Test-support directory is missing or outside the selected platform")
    testing = paths[0] / "Testing.framework/Versions/A/Testing"
    if not testing.is_file() or selected not in testing.resolve(strict=True).parents:
        raise ValueError("Testing.framework is missing or outside the selected platform")
    return [arg for path in paths for arg in ("-Xlinker", "-rpath", "-Xlinker", str(path))]


def main():
    flags = runtime_flags()
    os.execvp("swift", ["swift", "run", *flags, *sys.argv[1:]])


if __name__ == "__main__":
    main()
