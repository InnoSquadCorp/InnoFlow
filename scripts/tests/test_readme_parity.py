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


class ReadmeParityTests(unittest.TestCase):
    def test_current_seven_language_control(self):
        PARITY.verify(ROOT)

    def test_missing_language_code_version_link_and_contract_are_rejected(self):
        for case in ('missing', 'code', 'version', 'link', 'contract'):
            with self.subTest(case=case), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                files = [*PARITY.READMES, 'README.kr.md', 'README.jp.md', 'README.cn.md',
                         'STABLE_VERSION', 'docs/contracts/doc-parity.json']
                for file in files:
                    (root / file).parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(ROOT / file, root / file)
                target = root / 'README.ru.md'
                source = target.read_text()
                if case == 'missing':
                    target.unlink()
                else:
                    old, new = {'code': ('state.count += state.step', 'state.count += 1'),
                                'version': ('from: "6.0.2"', 'from: "5.1.1"'),
                                'link': ('(docs/MACRO_OPERATIONS.md)', '(docs/missing.md)'),
                                'contract': ('select(memoize: true)', 'opaqueSelector') }[case]
                    self.assertIn(old, source)
                    target.write_text(source.replace(old, new))
                with self.assertRaises((ValueError, FileNotFoundError)):
                    PARITY.verify(root)

    def test_old_name_cannot_reintroduce_stale_examples(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for file in [*PARITY.READMES, 'README.kr.md', 'README.jp.md', 'README.cn.md',
                         'STABLE_VERSION', 'docs/contracts/doc-parity.json']:
                (root / file).parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(ROOT / file, root / file)
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
