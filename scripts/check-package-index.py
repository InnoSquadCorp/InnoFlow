#!/usr/bin/env python3
"""Offline SPI metadata and consumer dependency-boundary contract."""
import json
from pathlib import Path
import re
import sys

DOCUMENTATION_URL = "https://innosquadcorp.github.io/InnoFlow/documentation/innoflow/"
PRODUCTS = {"InnoFlowCore", "InnoFlow", "InnoFlowSwiftUI", "InnoFlowTesting", "InnoFlowInspector"}


def validate(root: Path) -> None:
    # JSON is the deliberately small YAML subset used by all three repos.
    manifest = json.loads((root / ".spi.yml").read_text())
    if (not isinstance(manifest, dict) or type(manifest.get("version")) is not int
            or manifest != {"version": 1, "external_links": {"documentation": DOCUMENTATION_URL}}):
        raise ValueError("SPI must use the reviewed v1 external documentation configuration")
    package = (root / "Package.swift").read_text()
    uncommented = re.sub(r"//[^\n]*", "", re.sub(r'/\*.*?\*/', '', package, flags=re.S))
    products = set(re.findall(r'\.library\(\s*name:\s*"([^"]+)"', uncommented))
    if products != PRODUCTS:
        raise ValueError("Public product inventory changed; review the SPI documentation boundary")
    # The canonical manifest keeps dependency declarations on their own lines.
    dependencies = re.findall(r'^\s*\.package\(\s*url:\s*"([^"]+)"', package, re.M)
    if dependencies != ["https://github.com/swiftlang/swift-syntax.git"]:
        raise ValueError("SPI must not expand the consumer dependency graph")
    docs = (root / "docs/SWIFT_PACKAGE_INDEX.md").read_text()
    if not all(f"`{product}`" in docs for product in PRODUCTS):
        raise ValueError("SPI documentation must account for every public library product")
    if DOCUMENTATION_URL not in docs:
        raise ValueError("SPI documentation link and configuration disagree")


def main() -> int:
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent
    try:
        validate(root)
    except (OSError, ValueError) as error:
        print(f"[check-package-index] {error}", file=sys.stderr)
        return 1
    print("[check-package-index] OK (offline configuration only)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
