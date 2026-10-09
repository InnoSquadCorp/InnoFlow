"""The external timing documentation context must read its actual moved fixture."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class DocExampleContextsTests(unittest.TestCase):
    def generate(self, root):
        return subprocess.run([
            "ruby", "-r", str(ROOT / "scripts/doc-example-contexts.rb"), "-e",
            'puts DocExampleContexts.source(ARGV[0], "DocCTiming", '
            '["import InnoFlow\\nimport InnoFlowTesting\\n\\nlet entries = []\\n"])', str(root)
        ], capture_output=True, text=True)

    def test_timing_context_uses_moved_witness_and_external_product_import(self):
        result = self.generate(ROOT)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("final class EffectInstrumentationWitness", result.stdout)
        self.assertIn("func docCTimingCapture", result.stdout)
        self.assertIn("import InnoFlow", result.stdout)
        self.assertNotIn("@testable import InnoFlowCore", result.stdout)
        self.assertNotIn("import InnoFlowCore", result.stdout)

    def test_missing_witness_is_rejected_instead_of_omitting_the_context(self):
        with tempfile.TemporaryDirectory() as temporary:
            result = self.generate(Path(temporary))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("InnoFlowCoreTestSupport/EffectInstrumentationWitness.swift", result.stderr)


if __name__ == "__main__":
    unittest.main()
