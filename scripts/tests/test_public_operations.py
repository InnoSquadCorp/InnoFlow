import importlib.util
import json
import re
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('operations', ROOT / 'scripts/check-public-operations.py')
p = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p)


class PublicOperationsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        files = p.LOCKS + ['Package.swift', p.SAMPLE + '/Package.swift', 'Tools/generate-docc.sh', '.github/dependabot.yml']
        files += ['.github/workflows/' + n for n in ['ci.yml', 'coverage.yml', 'docs.yml', 'asan.yml', 'dependabot-auto-merge.yml', 'dependabot-review-notice.yml']]
        for f in files:
            target = self.root / f
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / f, target)
        self.addCleanup(self.temp.cleanup)

    def edit(self, path, transform):
        f = self.root / path
        f.write_text(transform(f.read_text()))

    def reject(self, path, transform):
        original = (self.root / path).read_text()
        self.edit(path, transform)
        with self.assertRaises((ValueError, KeyError, TypeError)):
            p.validate(self.root)
        (self.root / path).write_text(original)

    def test_readiness_matrices_cannot_cancel_unrelated_prs(self):
        path = '.github/workflows/dependabot-auto-merge.yml'
        for job in ['manual-ready', 'bot-ready']:
            marker = '\n  ' + job + ':\n'
            for replacement in ['      fail-fast: true\n', '']:
                def mutate(text, marker=marker, replacement=replacement):
                    before, after = text.split(marker, 1)
                    return before + marker + after.replace('      fail-fast: false\n', replacement, 1)
                with self.subTest(job=job, replacement=replacement):
                    self.reject(path, mutate)

    def test_documentation_contract_scripts_reject_missing_policy_text(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / 'InnoFlow'
            shutil.copytree(ROOT, root, ignore=shutil.ignore_patterns('.git', '.build*', '__pycache__'))
            cases = [
                ('scripts/check-macro-operations.sh', 'docs/MACRO_OPERATIONS.md', '-skipMacroValidation'),
                ('scripts/check-community-health.sh', 'SECURITY.md', 'initial acknowledgment within 7 calendar days'),
            ]
            for script, document, required in cases:
                with self.subTest(script=script):
                    result = subprocess.run(['bash', str(root / script)], cwd=root,
                        capture_output=True, text=True)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    path = root / document
                    original = path.read_text()
                    self.assertIn(required, original)
                    path.write_text(original.replace(required, 'removed-contract-marker'))
                    result = subprocess.run(['bash', str(root / script)], cwd=root,
                        capture_output=True, text=True)
                    self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                    path.write_text(original)

    def test_current_contract(self):
        p.validate(self.root)

    def test_every_swift_syntax_lock_and_generator_requires_coherence(self):
        for f in p.LOCKS:
            doc = json.loads((self.root / f).read_text())
            pin = next(x for x in doc['pins'] if x['identity'] == 'swift-syntax')
            version = pin['state']['version']
            parts = version.split('.')
            changed = '.'.join(parts[:-1] + [str(int(parts[-1]) + 1)])
            self.reject(f, lambda t, a=version, b=changed: t.replace(a, b))
        self.reject('Tools/generate-docc.sh', lambda t: t.replace('DOCC_SWIFT_SYNTAX_VERSION="', 'DOCC_SWIFT_SYNTAX_VERSION="9'))
        def advance_range(text):
            return re.sub(r'"([0-9]+)\.0\.0"\.\.<"([0-9]+)\.0\.0"',
                          lambda m: f'"{int(m[1])+1}.0.0"..<"{int(m[2])+1}.0.0"', text)
        self.reject('Package.swift', advance_range)

    def test_individual_majors_and_toolchains_are_not_ignored(self):
        path = '.github/dependabot.yml'
        def mutate(text, action):
            d = json.loads(text)
            action(d)
            return json.dumps(d)
        for alter in [lambda d: d['updates'][0]['groups']['actions-minor-patch']['update-types'].append('major'),
                      lambda d: d['updates'][1]['groups']['swift-minor-patch'].pop('exclude-patterns'),
                      lambda d: d['updates'][1].update(ignore=[{'dependency-name': '*'}]),
                      lambda d: d['updates'][1]['directories'].pop(),
                      lambda d: d['updates'][1]['schedule'].update(interval='monthly'),
                      lambda d: d['updates'][1]['labels'].remove('release-validation')]:
            self.reject(path, lambda t: mutate(t, alter))

    def test_new_live_manifest_needs_inventory_update(self):
        f = self.root / 'Examples/NewExample/Package.swift'
        f.parent.mkdir(parents=True)
        f.write_text('// new live consumer')
        with self.assertRaisesRegex(ValueError, 'manifest'):
            p.validate(self.root)

    def test_permissions_and_trusted_execution_cannot_expand(self):
        path = '.github/workflows/dependabot-auto-merge.yml'
        self.reject(path, lambda t: t.replace('actions: read', 'actions: write', 1))
        self.reject(path, lambda t: t.replace('persist-credentials: false', 'persist-credentials: true', 1))
        self.reject(path, lambda t: t.replace('ref: refs/heads/main', 'ref: ${{ github.event.pull_request.head.sha }}', 1))
        self.reject(path, lambda t: t.replace("github.workflow_ref == 'InnoSquadCorp/InnoFlow/.github/workflows/dependabot-auto-merge.yml@refs/heads/main'", 'true', 1))
        self.reject('.github/workflows/ci.yml', lambda t: t.replace('contents: read', 'contents: write', 1))
        self.reject('.github/workflows/dependabot-review-notice.yml', lambda t: t.replace('permissions: {}', 'permissions: write-all'))


if __name__ == '__main__':
    unittest.main()
