"""Product dependency selection and full-build fallback contracts."""
import importlib.util
import subprocess
from pathlib import Path
from types import SimpleNamespace
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('ci_build_products', ROOT / 'scripts/ci-build-products.py')
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)


def plan(paths, event='pull_request'):
    payload = {'action': 'opened', 'pull_request': {'labels': [], 'user': {'login': 'contributor'}}}
    return build.policy().make_plan(event, payload, paths)


class ProductsTests(unittest.TestCase):
    def select(self, paths, event='pull_request', manifest=None):
        return build.affected_products(plan(paths, event), manifest if manifest is not None else (ROOT / 'Package.swift').read_bytes())

    def test_reverse_dependencies(self):
        self.assertEqual(self.select(['Sources/InnoFlowCore/Store.swift']), build.FULL)
        self.assertEqual(self.select(['Sources/InnoFlowMacros/Macro.swift']), ['InnoFlow'])
        self.assertEqual(self.select(['Sources/InnoFlowSwiftUI/Binding.swift']), ['InnoFlowSwiftUI'])
        self.assertEqual(self.select(['Sources/InnoFlowTesting/TestStore.swift']), ['InnoFlowTesting'])
        self.assertEqual(self.select(['Sources/InnoFlowInspector/View.swift']), ['InnoFlowInspector'])
        self.assertEqual(self.select(['Sources/InnoFlowTesting/TestStore.swift', 'Sources/InnoFlowSwiftUI/Binding.swift']), ['InnoFlowSwiftUI', 'InnoFlowTesting'])

    def test_full_fallback(self):
        for paths in ([], ['Package.swift'], ['Tests/InnoFlowTests/Test.swift'], ['Sources/Unknown/Test.swift'],
                      ['Sources/InnoFlowCore/PrivacyInfo.xcprivacy'], ['Sources/InnoFlowTesting/Test.swift', 'README.md']):
            self.assertEqual(self.select(paths), build.FULL)
        self.assertEqual(self.select(['Sources/InnoFlowTesting/Test.swift'], 'workflow_dispatch'), build.FULL)
        self.assertEqual(self.select(['Sources/InnoFlowTesting/Test.swift'], manifest=b'changed'), build.FULL)

    def test_corrupt_plan_rejected(self):
        value = plan(['Sources/InnoFlowTesting/Test.swift'])
        value['jobs']['tests'] = False
        with self.assertRaises(ValueError):
            build.affected_products(value, (ROOT / 'Package.swift').read_bytes())

    def test_sdk_command_and_missing_scheme_fallback(self):
        for schemes, expected in [(['InnoFlowSwiftUI'], ['InnoFlowSwiftUI']), ([], build.FULL)]:
            calls = []
            def runner(command, **kwargs):
                calls.append(command)
                return SimpleNamespace(stdout=__import__('json').dumps({'workspace': {'schemes': schemes}}))
            selected = build.run(plan(['Sources/InnoFlowSwiftUI/Binding.swift']), 'visionOS', runner=runner)
            self.assertEqual(selected, expected)
            self.assertIn('generic/platform=visionOS', calls[-1])
            self.assertEqual(calls[-1][calls[-1].index('-scheme') + 1], expected[0])

    def test_discovery_failure_runs_real_full_build(self):
        calls = []
        def runner(command, **kwargs):
            calls.append(command)
            if '-list' in command:
                raise subprocess.TimeoutExpired(command, 180)
            return SimpleNamespace(stdout='')
        self.assertEqual(build.run(plan(['Sources/InnoFlowTesting/Test.swift']), 'macOS', runner=runner), build.FULL)
        self.assertEqual(len(calls), 2)

    def test_build_failure_is_not_retried_or_hidden(self):
        calls = []
        def runner(command, **kwargs):
            calls.append(command)
            if '-list' in command:
                return SimpleNamespace(stdout='{"workspace":{"schemes":["InnoFlowTesting"]}}')
            raise subprocess.CalledProcessError(65, command)
        with self.assertRaises(subprocess.CalledProcessError):
            build.run(plan(['Sources/InnoFlowTesting/Test.swift']), 'iOS', runner=runner)
        self.assertEqual(len(calls), 2)
