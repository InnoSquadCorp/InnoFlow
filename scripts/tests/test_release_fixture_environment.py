"""Release selftests must isolate synthetic repositories from a real tag run."""
import os
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]
RELEASE_VARIABLES = (
    "GITHUB_REF_TYPE", "GITHUB_REF_NAME", "INNOFLOW_TRIGGER_TAG",
    "INNOFLOW_REQUIRE_RELEASE_TAG", "INNOFLOW_REQUIRE_RELEASE_DATE", "INNOFLOW_RELEASE_VERSION",
    "INNOFLOW_API_BASELINE", "INNOFLOW_REQUIRE_API_BASELINE", "INNOFLOW_STABLE_VERSION_FILE",
)


class ReleaseFixtureEnvironmentTests(unittest.TestCase):
    def run_fixtures(self, overrides):
        environment = os.environ.copy()
        for key in RELEASE_VARIABLES:
            environment.pop(key, None)
        environment.update(overrides)
        result = subprocess.run(
            ["bash", str(ROOT / "scripts/principle-gates-selftest.sh"), "--release-fixtures-only"],
            cwd=ROOT, env=environment, capture_output=True, text=True, timeout=60,
        )
        output = result.stdout + result.stderr
        self.assertEqual(result.returncode, 0, output)
        # Each negative control must reach the intended checker, not an earlier
        # inherited-env or documentation-mismatch failure.
        for diagnostic in (
            "does not exist locally",
            "does not match staged release",
            "Tagged",  # An undated candidate is rejected before tagging.
            "tagged candidate must retain an earlier public stable baseline",
            "but the release checkout is",
            "Isolated release fixtures passed",
        ):
            self.assertIn(diagnostic, output)

    def test_clean_branch_context(self):
        self.run_fixtures({"GITHUB_REF_TYPE": "branch", "GITHUB_REF_NAME": "main"})

    def test_inherited_release_and_api_enforcement(self):
        self.run_fixtures({
            "GITHUB_REF_TYPE": "tag", "GITHUB_REF_NAME": "9.8.7",
            "INNOFLOW_TRIGGER_TAG": "9.8.7", "INNOFLOW_RELEASE_VERSION": "9.8.7",
            "INNOFLOW_REQUIRE_RELEASE_TAG": "1", "INNOFLOW_REQUIRE_RELEASE_DATE": "1",
            "INNOFLOW_API_BASELINE": "99.0.0", "INNOFLOW_REQUIRE_API_BASELINE": "1",
            "INNOFLOW_STABLE_VERSION_FILE": "/not-a-fixture/stable-version",
        })

    def test_trigger_without_github_tag_and_date_override(self):
        self.run_fixtures({"INNOFLOW_TRIGGER_TAG": "9.8.7", "INNOFLOW_REQUIRE_RELEASE_DATE": "true"})


if __name__ == "__main__":
    unittest.main()
