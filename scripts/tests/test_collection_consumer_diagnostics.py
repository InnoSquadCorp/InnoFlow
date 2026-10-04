"""Verify diagnostic attribution without running a compiler or weakening negatives."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "check-collection-lifetime-consumer.sh"


class CollectionConsumerDiagnostics(unittest.TestCase):
    def run_fixture(self, mode):
        with tempfile.TemporaryDirectory() as directory:
            swift = Path(directory) / "swift"
            swift.write_text("""#!/usr/bin/env python3
import os, sys
kind = os.environ['INNOFLOW_COLLECTION_CONSUMER_NEGATIVE']
mode = os.environ['DIAGNOSTIC_FIXTURE_MODE']
if kind == '0':
    sys.exit(0)
if mode == 'unexpected-success':
    sys.exit(0)
if mode == 'unrelated':
    print('Fixture.swift:1: error: no such module InnoFlowCore')
elif kind == '1':
    print("PreviousInitializer.swift:13:36: error: cannot convert value of type 'StaticString' to specified type")
else:
    print("NonSendableKeyPath.swift:10:1: error: type 'KeyPath' does not conform to the 'Sendable' protocol")
sys.exit(1)
""")
            if mode == "color":
                source = swift.read_text().replace(
                    ": error: ", ": \\x1b[1;31merror: \\x1b[1;39m"
                )
                swift.write_text(source)
            swift.chmod(0o755)
            return subprocess.run(
                ["bash", str(SCRIPT)], capture_output=True, text=True,
                env={**os.environ, "PATH": directory + os.pathsep + os.environ["PATH"],
                     "DIAGNOSTIC_FIXTURE_MODE": mode},
            )

    def test_plain_and_apple_colored_diagnostics_preserve_all_negatives(self):
        for mode in ("plain", "color"):
            with self.subTest(mode=mode):
                result = self.run_fixture(mode)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(result.stdout.count("rejection verified"), 13)

    def test_unrelated_failure_and_unexpected_compilation_fail_closed(self):
        for mode in ("unrelated", "unexpected-success"):
            with self.subTest(mode=mode):
                self.assertNotEqual(self.run_fixture(mode).returncode, 0)


if __name__ == "__main__":
    unittest.main()
