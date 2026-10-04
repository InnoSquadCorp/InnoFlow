import importlib.util
from pathlib import Path
import plistlib
import tempfile
from types import SimpleNamespace
import unittest

spec = importlib.util.spec_from_file_location(
    "select_swift_release", Path(__file__).resolve().parents[1] / "select-swift-release-toolchain.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ToolchainSelectionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "toolchains"
        self.root.mkdir()
        self.evidence = Path(self.temp.name) / "evidence"

    def bundle(self, name, identifier="org.swift.640"):
        path = self.root / (name + ".xctoolchain")
        (path / "usr/bin").mkdir(parents=True)
        (path / "usr/bin/swift").write_text("fixture-only; never executed")
        (path / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": identifier}))
        return path

    def run_version(self, version="Apple Swift version 6.4 (swift-6.4-RELEASE)\n", code=0):
        return lambda *args, **kwargs: SimpleNamespace(stdout=version, stderr="", returncode=code)

    def test_official_release_and_latest_alias_are_one_physical_bundle(self):
        physical = self.bundle("swift-6.4.0-RELEASE")
        (self.root / "swift-latest.xctoolchain").symlink_to(physical.name, target_is_directory=True)
        result = module.select(self.root, self.evidence, self.run_version())
        self.assertEqual(result["path"], str(physical))
        self.assertEqual(len(result["aliases"]), 2)
        self.assertEqual((self.evidence / "bin-path.txt").read_text(), str(physical / "usr/bin") + "\n")

    def test_two_distinct_release_installations_are_rejected(self):
        self.bundle("one")
        self.bundle("two")
        with self.assertRaisesRegex(ValueError, "one physical"):
            module.select(self.root, self.evidence, self.run_version())
        self.assertTrue((self.evidence / "inventory.json").is_file())
        self.assertFalse((self.evidence / "selected.json").exists())

    def test_640_spelling_is_accepted(self):
        self.bundle("official")
        module.select(self.root, self.evidence,
                      self.run_version("Swift version 6.4.0 (swift-6.4.0-RELEASE)\n"))

    def test_wrong_version_or_development_build_remains_rejected(self):
        self.bundle("candidate")
        for text in ["Swift version 6.3 (swift-6.3-RELEASE)",
                     "Swift version 6.4 (swift-6.4-DEVELOPMENT)",
                     "Apple Swift version 6.4 (swiftlang-6.4.0.1 clang-1)"]:
            with self.subTest(text=text), self.assertRaisesRegex(ValueError, "one physical"):
                module.select(self.root, self.evidence, self.run_version(text))

    def test_failed_compiler_and_missing_compiler_are_rejected(self):
        path = self.bundle("candidate")
        with self.assertRaisesRegex(ValueError, "one physical"):
            module.select(self.root, self.evidence, self.run_version(code=1))
        (path / "usr/bin/swift").unlink()
        with self.assertRaisesRegex(ValueError, "one physical"):
            module.select(self.root, self.evidence, self.run_version())

    def test_identifier_cannot_inject_environment_lines(self):
        self.bundle("candidate", identifier="org.swift.640\nOTHER=value")
        with self.assertRaisesRegex(ValueError, "identifier"):
            module.select(self.root, self.evidence, self.run_version())


if __name__ == "__main__":
    unittest.main()
