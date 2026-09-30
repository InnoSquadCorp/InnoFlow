"""Keep reviewed 603/604 admission paired with exact blocking compatibility jobs."""
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('operations', ROOT / 'scripts/check-public-operations.py')
policy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(policy)


class SwiftSyntaxUpgradeTests(unittest.TestCase):
    def test_minimum_and_reviewed_range_cannot_be_silently_changed(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            for file in policy.LOCKS + ['Package.swift', 'Tools/generate-docc.sh']:
                dest = root / file
                dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(ROOT / file, dest)
            policy.coherence(root)
            manifest = (root / 'Package.swift').read_text()
            mutations = [manifest.replace('swift-tools-version: 6.3', 'swift-tools-version: 6.4'),
                         manifest.replace('"603.0.0"..<"605.0.0"', '"604.0.0"..<"605.0.0"'),
                         manifest.replace('"603.0.0"..<"605.0.0"', '"603.0.0"..<"606.0.0"')]
            for text in mutations:
                (root / 'Package.swift').write_text(text)
                with self.assertRaises(ValueError):
                    policy.coherence(root)
            (root / 'Package.swift').write_text(manifest)
            for file in policy.LOCKS:
                doc = json.loads((root / file).read_text())
                next(p for p in doc['pins'] if p['identity'] == 'swift-syntax')['state']['version'] = '605.0.0'
                (root / file).write_text(json.dumps(doc))
            with self.assertRaises(ValueError):
                policy.coherence(root)

    def test_real_workflow_keeps_floor_forward_and_exact_proof(self):
        ci = json.loads(subprocess.check_output(['ruby', '-ryaml', '-rjson', '-e',
            'puts YAML.safe_load(File.read(ARGV[0]), aliases: false).to_json',
            str(ROOT / '.github/workflows/ci.yml')], text=True))
        job = ci['jobs']['swift-syntax-compatibility']
        self.assertEqual(job['needs'], ['ci-plan', 'lint'])
        self.assertEqual(job['if'], 'fromJSON(needs.ci-plan.outputs.plan).jobs.swift-syntax-compatibility')
        self.assertIs(job['strategy']['fail-fast'], False)
        rows = job['strategy']['matrix']['include']
        self.assertEqual(rows, [
            dict(runner='macos-26', xcode='26.6', swift='6.3', syntax='603.0.0', revision='2b59c0c741e9184ab057fd22950b491076d42e91'),
            dict(runner='xcode-27', xcode='27.0', swift='6.4', syntax='604.0.0', revision='050f1a346fbbac0ca2cfb15a95274f7bd1cf0ccf'),
        ])
        self.assertIn('swift-syntax-compatibility', ci['jobs']['ci-required']['needs'])
        self.assertEqual(job['env']['DEVELOPER_DIR'], '/Applications/Xcode_${{ matrix.xcode }}.app/Contents/Developer')
        steps = {s['name']: s for s in job['steps']}
        self.assertEqual(steps['Checkout exact compatibility candidate']['with'], {'ref': '${{ github.sha }}', 'persist-credentials': False})
        resolve = steps['Resolve and verify audited SwiftSyntax']['run']
        self.assertIn('swift package resolve swift-syntax --version "$SYNTAX_VERSION"', resolve)
        self.assertIn("matches[0]['state']['revision'] == os.environ['SYNTAX_REVISION']", resolve)
        testing = steps['Test macro and external compile contracts']['run']
        for required in ['--no-parallel', '-warnings-as-errors', 'InnoFlowMacrosTests|CompileContractTests']:
            self.assertIn(required, testing)
        for step in steps.values():
            self.assertNotIn('if', step)
            self.assertNotIn('continue-on-error', step)


if __name__ == '__main__':
    unittest.main()
