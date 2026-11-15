"""The documented install version is the requirement's lower bound, not any string of the manifest."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
# `swift package dump-package` (Swift 6.3) of the documented install manifest
# that check-doc-copyable-examples.rb builds, with `from: "6.1.0"`. Only the
# local package root path was replaced.
FIXTURE = Path(__file__).resolve().parent / "fixtures/swiftpm-dump-package-install-6.3.json"


def version_drift(package, release_target):
    with tempfile.TemporaryDirectory() as temporary:
        path = Path(temporary) / "package.json"
        path.write_text(json.dumps(package))
        result = subprocess.run([
            "ruby", "-r", str(ROOT / "scripts/doc-install-requirement.rb"), "-e",
            'puts DocInstallRequirement.version_drift(JSON.parse(File.read(ARGV[0])), ARGV[1]) || "exact"',
            str(path), release_target,
        ], capture_output=True, text=True)
    if result.returncode != 0:
        raise AssertionError(result.stderr)
    output = result.stdout.strip()
    return None if output == "exact" else output


class DocInstallRequirementTests(unittest.TestCase):
    def setUp(self):
        self.text = FIXTURE.read_text()
        self.package = json.loads(self.text)

    def test_lower_bound_must_equal_the_release_target(self):
        self.assertIsNone(version_drift(self.package, "6.1.0"))
        # The manifest output also contains the upper bound and the tools
        # version, so a substring search accepted both of these targets.
        for target in ("7.0.0", "6.3.0"):
            with self.subTest(target=target):
                self.assertIn(f'"{target}"', self.text)
                self.assertRegex(version_drift(self.package, target), "does not start at " + target)
        self.assertIsNotNone(version_drift(self.package, "6.1"))

    def test_requirement_must_be_one_innoflow_version_range(self):
        dependency = self.package["dependencies"][0]
        source = dependency["sourceControl"][0]
        cases = {
            "missing": [],
            "duplicate": [dependency, dependency],
            "other repository": [{"sourceControl": [{
                **source, "location": {"remote": [{"urlString": "https://example.invalid/InnoFlow.git"}]}}]}],
            "exact requirement": [{"sourceControl": [{**source, "requirement": {"exact": ["6.1.0"]}}]}],
            "branch requirement": [{"sourceControl": [{**source, "requirement": {"branch": ["main"]}}]}],
        }
        for case, dependencies in cases.items():
            with self.subTest(case=case):
                self.assertIsNotNone(version_drift({**self.package, "dependencies": dependencies}, "6.1.0"))


if __name__ == "__main__":
    unittest.main()
