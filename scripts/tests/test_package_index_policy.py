"""Negative controls for the externally hosted SPI documentation contract."""
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("package_index", ROOT / "scripts/check-package-index.py")
POLICY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(POLICY)


class PackageIndexPolicyTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / "docs").mkdir()
        for name in (".spi.yml", "Package.swift", "docs/SWIFT_PACKAGE_INDEX.md"):
            shutil.copyfile(ROOT / name, self.root / name)

    def rewrite_manifest(self, mutate):
        path = self.root / ".spi.yml"
        value = json.loads(path.read_text())
        mutate(value)
        path.write_text(json.dumps(value))

    def test_current_configuration(self):
        POLICY.validate(self.root)

    def test_wrong_documentation_destination(self):
        self.rewrite_manifest(lambda value: value["external_links"].update(documentation="https://example.invalid/"))
        with self.assertRaises(ValueError):
            POLICY.validate(self.root)

    def test_unsupported_schema_version(self):
        self.rewrite_manifest(lambda value: value.update(version=2))
        with self.assertRaises(ValueError):
            POLICY.validate(self.root)

    def test_boolean_is_not_schema_version(self):
        self.rewrite_manifest(lambda value: value.update(version=True))
        with self.assertRaises(ValueError):
            POLICY.validate(self.root)

    def test_builder_override_requires_review(self):
        self.rewrite_manifest(lambda value: value.update(builder={"configs": []}))
        with self.assertRaises(ValueError):
            POLICY.validate(self.root)

    def test_docc_dependency_not_added_to_consumer(self):
        path = self.root / "Package.swift"
        path.write_text(path.read_text().replace("  dependencies: [", '  dependencies: [\n    .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.5.0"),', 1))
        with self.assertRaises(ValueError):
            POLICY.validate(self.root)

    def test_removed_product(self):
        path = self.root / "Package.swift"
        path.write_text(path.read_text().replace('name: "InnoFlowSwiftUI"', 'name: "OtherProduct"', 1))
        with self.assertRaises(ValueError):
            POLICY.validate(self.root)

    def test_undocumented_product(self):
        path = self.root / "docs/SWIFT_PACKAGE_INDEX.md"
        path.write_text(path.read_text().replace("`InnoFlowTesting`", "test library"))
        with self.assertRaises(ValueError):
            POLICY.validate(self.root)

    def test_missing_configuration(self):
        (self.root / ".spi.yml").unlink()
        with self.assertRaises(OSError):
            POLICY.validate(self.root)


if __name__ == "__main__":
    unittest.main()
