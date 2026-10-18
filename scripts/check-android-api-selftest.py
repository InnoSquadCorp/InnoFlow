#!/usr/bin/env python3
"""Prove both AAR API gates reject a changed reference without editing source."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="innoflow-android-api-negative-") as scratch:
    scratch = Path(scratch)
    bad = scratch / "bad.api"
    bad.write_text("unexpected public signature\n", encoding="utf-8")
    init = scratch / "negative.init.gradle"
    init.write_text("""
gradle.projectsEvaluated {
    rootProject.subprojects.each { candidate ->
        if (candidate.name in ['inno-flow-android', 'inno-flow-compose']) {
            candidate.tasks.named('checkKotlinAbi').configure {
                projectApiFile.set(new File('%s'))
            }
        }
    }
}
""" % bad.as_posix(), encoding="utf-8")
    result = subprocess.run([str(root / "kotlin/gradlew"), "-p", str(root / "kotlin"),
        ":inno-flow-android:checkKotlinAbi", ":inno-flow-compose:checkKotlinAbi", "--continue",
        "--no-configuration-cache", "--init-script", str(init), "--console=plain"],
        capture_output=True, text=True, timeout=240)
    output = result.stdout + result.stderr
    if result.returncode == 0 or not all(f"API check failed for project {name}" in output
            for name in ("inno-flow-android", "inno-flow-compose")):
        raise SystemExit("Android ABI negative controls failed:\n" + output)
print("[android-api] Both real AAR API gates rejected changed baselines")
