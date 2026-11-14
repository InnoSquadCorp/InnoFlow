"""Negative controls for seven-language documentation contracts and local links."""
import importlib.util
from pathlib import Path
import shutil
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]

def module(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'scripts' / (name + '.py'))
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result

PARITY = module('check-readme-parity')
LINKS = module('check-doc-links')
PARITY_FILES = [*PARITY.READMES, 'README.kr.md', 'README.jp.md', 'README.cn.md',
                'STABLE_VERSION', 'RELEASE_NOTES.md', 'docs/contracts/doc-parity.json']


def copy_parity_inputs(root):
    for file in PARITY_FILES:
        (root / file).parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / file, root / file)


def current_versions():
    stable = (ROOT / 'STABLE_VERSION').read_text().strip()
    return stable, PARITY.release_target(ROOT, stable)


class ReadmeParityTests(unittest.TestCase):
    def test_current_seven_language_control(self):
        PARITY.verify(ROOT)

    def test_missing_language_code_version_link_and_contract_are_rejected(self):
        _, target_version = current_versions()
        for case in ('missing', 'code', 'version', 'heading', 'link', 'contract'):
            with self.subTest(case=case), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                copy_parity_inputs(root)
                target = root / 'README.ru.md'
                source = target.read_text()
                if case == 'missing':
                    target.unlink()
                else:
                    old, new = {'code': ('state.count += state.step', 'state.count += 1'),
                                'version': (f'from: "{target_version}"', 'from: "5.1.1"'),
                                'heading': (f'## InnoFlow {target_version}\n', '## InnoFlow 0.0.1\n'),
                                'link': ('(docs/MACRO_OPERATIONS.md)', '(docs/missing.md)'),
                                'contract': ('select(memoize: true)', 'opaqueSelector') }[case]
                    self.assertIn(old, source)
                    target.write_text(source.replace(old, new))
                with self.assertRaises((ValueError, FileNotFoundError)):
                    PARITY.verify(root)

    def test_release_target_follows_release_notes_not_stable_version(self):
        # A candidate installs its release-notes target while STABLE_VERSION keeps
        # the published release; neither may stand in for the other.
        stable, target_version = current_versions()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            copy_parity_inputs(root)
            notes = root / 'RELEASE_NOTES.md'
            notes.write_text(notes.read_text().replace(
                f'## {target_version} Release\n', '## 99.0.0 Release\n', 1))
            with self.assertRaisesRegex(ValueError, 'release installation/version drift'):
                PARITY.verify(root)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            copy_parity_inputs(root)
            (root / 'STABLE_VERSION').write_text('99.0.0\n')
            with self.assertRaisesRegex(ValueError, 'older than STABLE_VERSION'):
                PARITY.verify(root)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            copy_parity_inputs(root)
            notes = root / 'RELEASE_NOTES.md'
            notes.write_text(notes.read_text().replace(' Release\n', ' Notes\n'))
            with self.assertRaisesRegex(ValueError, 'names no release target'):
                PARITY.verify(root)
        self.assertGreaterEqual(PARITY.version_key(target_version), PARITY.version_key(stable))

    def test_every_readme_must_link_the_published_stable_source(self):
        stable, _ = current_versions()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            copy_parity_inputs(root)
            # Change all seven alike, so only the stable-source rule can fail.
            for file in PARITY.READMES:
                path = root / file
                source = path.read_text()
                self.assertIn(f'/tree/{stable})', source)
                path.write_text(source.replace(f'/tree/{stable})', '/tree/main)'))
            with self.assertRaisesRegex(ValueError, 'published stable source link drift'):
                PARITY.verify(root)

    def test_old_name_cannot_reintroduce_stale_examples(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            copy_parity_inputs(root)
            path = root / 'README.kr.md'
            path.write_text(path.read_text() + '\n```swift\nlet stale = true\n```\n')
            with self.assertRaisesRegex(ValueError, 'Legacy README'):
                PARITY.verify(root)


class LocalLinkTests(unittest.TestCase):
    def test_valid_links_unicode_anchors_and_literal_code(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'target.md').write_text('# 제목\n\n## A `typed` API\n')
            (root / 'index.md').write_text('[one](target.md#제목) [two](target.md#a-typed-api)\n'
                '```text\n[example](absent.md)\n```\n')
            count, errors = LINKS.errors_for(root, ['index.md'])
            self.assertEqual((count, errors), (2, []))

    def test_missing_target_anchor_and_external_path_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'target.md').write_text('# Present\n')
            (root / 'index.md').write_text('[one](absent.md) [two](target.md#missing) [three](../outside.md)')
            count, errors = LINKS.errors_for(root, ['index.md'])
            self.assertEqual(count, 3)
            self.assertEqual(len(errors), 3)


if __name__ == '__main__':
    unittest.main()
