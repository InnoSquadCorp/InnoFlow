#!/usr/bin/env python3
"""Compile the published KSP processor in independent positive/negative consumers."""
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[1]
cases = {
    "positive": None,
    "private": "@InnoFlow requires public or internal visibility",
    "generic": "@InnoFlow 1.0 does not support generic feature declarations",
    "nested": "@InnoFlow 1.0 requires a top-level declaration",
    "indirect": "@InnoFlow types must directly implement FlowFeature",
    "abstract": "@InnoFlow requires a concrete class or object",
}
for case, diagnostic in cases.items():
    result = subprocess.run([
        str(root / "kotlin/gradlew"), "-p", str(root / "kotlin/ksp-fixtures"),
        "clean", "compileKotlin", "--refresh-dependencies", "--console=plain", f"-PfixtureCase={case}",
    ], cwd=root, capture_output=True, text=True, timeout=240)
    output = result.stdout + result.stderr
    if (diagnostic is None and result.returncode != 0) or (
        diagnostic is not None and (result.returncode == 0 or diagnostic not in output)
    ):
        raise SystemExit(f"KSP fixture {case} failed its contract:\n{output}")
    print(f"[ksp-fixtures] {case}: {'compiled' if diagnostic is None else 'expected diagnostic'}", flush=True)
