import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'migrate-effect-timing-jsonl.py'
spec = importlib.util.spec_from_file_location('migration', SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class TimingMigrationTests(unittest.TestCase):
    def row(self, identity=None, **extra):
        return {'phase': 'runStarted', 'sequence': 1, 'timestampNanos': 10, 'dispatchID': identity, **extra}
    def convert(self, *rows):
        return [json.loads(line) for line in module.convert('\n'.join(json.dumps(row) for row in rows)).splitlines()]
    def test_shared_and_distinct_uuid_correlations_are_preserved_without_numeric_collision(self):
        first = '00000000-0000-0000-0000-000000000001'
        second = '00000000-0000-0000-0000-000000000002'
        rows = self.convert(self.row(first), self.row(second), self.row(first), self.row(1))
        self.assertEqual([row['dispatchID'] for row in rows], [2, 3, 2, 1])
        self.assertEqual(rows[0]['legacyDispatchID'], first)
        self.assertTrue(all(row['schemaVersion'] == 2 for row in rows))
    def test_no_identity_and_uint64_max_preserve_values(self):
        rows = self.convert(self.row(), self.row((1 << 64) - 1))
        self.assertIsNone(rows[0]['dispatchID'])
        self.assertEqual(rows[1]['dispatchID'], (1 << 64) - 1)
    def test_reapplication_is_byte_identical(self):
        text = module.convert(json.dumps(self.row('00000000-0000-0000-0000-000000000001')))
        self.assertEqual(module.convert(text), text)
    def test_malformed_records_are_rejected(self):
        for row in [self.row(-1), self.row(True), self.row('invalid'), self.row(1, schemaVersion=99), self.row(1, schemaVersion=True), self.row('00000000-0000-0000-0000-000000000001', schemaVersion=2), self.row(1, sequence=-1), self.row(1, phase='unknown')]:
            with self.subTest(row=row), self.assertRaises(ValueError): self.convert(row)
    def test_existing_output_and_invalid_input_never_modify_originals(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / 'old.jsonl'; target = Path(directory) / 'new.jsonl'
            original = json.dumps(self.row())
            source.write_text(original); target.write_text('sentinel')
            result = subprocess.run([sys.executable, str(SCRIPT), '--input', str(source), '--output', str(target)], capture_output=True)
            self.assertEqual(result.returncode, 2); self.assertEqual(source.read_text(), original); self.assertEqual(target.read_text(), 'sentinel')
            source.write_text('invalid json'); new = Path(directory) / 'missing.jsonl'
            result = subprocess.run([sys.executable, str(SCRIPT), '--input', str(source), '--output', str(new)], capture_output=True)
            self.assertEqual(result.returncode, 2); self.assertFalse(new.exists())

if __name__ == '__main__': unittest.main()
