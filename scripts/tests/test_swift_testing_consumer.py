import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("consumer", Path(__file__).resolve().parents[1] / "run-swift-testing-consumer.py")
consumer = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(consumer)


class ConsumerRuntimeTests(unittest.TestCase):
    def fixture(self, root):
        developer = root / "Xcode App/Contents/Developer"
        platform = developer / "Platforms/MacOSX.platform"
        paths = [platform / x for x in ("Developer/Library/Frameworks", "Developer/Library/PrivateFrameworks", "Developer/usr/lib")]
        for p in paths:
            p.mkdir(parents=True)
        binary = paths[0] / "Testing.framework/Versions/A/Testing"
        binary.parent.mkdir(parents=True)
        binary.write_bytes(b"fixture")
        return developer, platform, paths, binary

    def test_non_apple_passthrough(self):
        with patch.object(consumer.subprocess, "check_output") as call:
            self.assertEqual(consumer.runtime_flags("linux"), [])
            call.assert_not_called()

    def test_selected_paths_and_symlinked_temporary_parent(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            real = root / "real"
            real.mkdir()
            alias = root / "alias"
            alias.symlink_to(real, target_is_directory=True)
            developer, platform, paths, _ = self.fixture(alias)
            with patch.object(consumer.subprocess, "check_output", side_effect=[str(developer), str(platform)]) as call:
                self.assertEqual(consumer.runtime_flags("darwin"), [arg for p in paths for arg in ("-Xlinker", "-rpath", "-Xlinker", str(p.resolve()))])
                self.assertEqual(call.call_args_list[1].args[0], ["xcrun", "--sdk", "macosx", "--show-sdk-platform-path"])

    def test_missing_and_escaping_testing_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            developer, platform, _, binary = self.fixture(root)
            binary.unlink()
            for escaped in (False, True):
                if escaped:
                    foreign = root / "foreign"
                    foreign.write_bytes(b"not selected")
                    binary.symlink_to(foreign)
                with self.subTest(escaped=escaped), patch.object(consumer.subprocess, "check_output", side_effect=[str(developer), str(platform)]), self.assertRaisesRegex(ValueError, "Testing.framework"):
                    consumer.runtime_flags("darwin")

    def test_foreign_platform_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            developer, _, _, _ = self.fixture(root / "first")
            _, platform, _, _ = self.fixture(root / "second")
            with patch.object(consumer.subprocess, "check_output", side_effect=[str(developer), str(platform)]), self.assertRaisesRegex(ValueError, "outside Xcode"):
                consumer.runtime_flags("darwin")

    def test_main_forwards_arguments_without_shell_or_loader_changes(self):
        with patch.object(consumer, "runtime_flags", return_value=["-Xlinker", "-rpath", "-Xlinker", "/space path"]), patch.object(consumer.sys, "argv", ["wrapper", "--package-path", "/fixture", "Consumer", "argument"]), patch.object(consumer.os, "execvp") as run:
            consumer.main()
            run.assert_called_once_with("swift", ["swift", "run", "-Xlinker", "-rpath", "-Xlinker", "/space path", "--package-path", "/fixture", "Consumer", "argument"])


if __name__ == "__main__":
    unittest.main()
