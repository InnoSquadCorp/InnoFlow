import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "check_api_breakage_allowlist", SCRIPTS / "check-api-breakage-allowlist.py")
allowlist = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(allowlist)

SOURCE = """\
package protocol Driver {
  func run(awaited: Bool)
}

public struct Store {
  package func bridge() {}
  public func send() {}
}
"""


class APIBreakageAllowlistTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.git("init", "-q")
        (self.root / "Sources").mkdir()
        (self.root / "Sources/Runtime.swift").write_text(SOURCE, encoding="utf-8")
        self.git("add", "Sources/Runtime.swift")
        self.git("-c", "user.name=Selftest", "-c", "user.email=selftest@invalid.example",
                 "commit", "-qm", "fixture")
        self.git("tag", "6.0.2")

    def tearDown(self):
        self.temporary.cleanup()

    def git(self, *arguments):
        subprocess.run(["git", "-C", str(self.root), *arguments], check=True)

    def entry(self, **overrides):
        entry = {
            "message": "API breakage: func Driver.run(awaited:) has been removed",
            "source": "Sources/Runtime.swift",
            "declaration": "package protocol Driver",
            "reason": "Internal driver protocol.",
        }
        entry.update(overrides)
        return entry

    def validate(self, entries, baseline="6.0.2", reviewed="6.0.2"):
        path = self.root / "allowlist.json"
        path.write_text(json.dumps({"schema": 1, "baseline": reviewed, "entries": entries}),
                        encoding="utf-8")
        return allowlist.validate(self.root, path, baseline)

    def test_package_declarations_are_accepted(self):
        messages = self.validate([
            self.entry(),
            self.entry(message="API breakage: func Store.bridge() has been removed",
                       declaration="package func bridge()"),
        ])
        self.assertEqual(messages, [
            "API breakage: func Driver.run(awaited:) has been removed",
            "API breakage: func Store.bridge() has been removed",
        ])

    def test_public_declaration_cannot_be_listed(self):
        for declaration in ("public func send()", "public struct Store", "func run(awaited: Bool)"):
            with self.subTest(declaration=declaration):
                with self.assertRaises(allowlist.AllowlistError):
                    self.validate([self.entry(declaration=declaration)])

    def test_declaration_must_exist_at_the_baseline(self):
        with self.assertRaises(allowlist.AllowlistError):
            self.validate([self.entry(declaration="package func neverExisted()")])
        with self.assertRaises(allowlist.AllowlistError):
            self.validate([self.entry(source="Sources/Missing.swift")])
        with self.assertRaises(allowlist.AllowlistError):
            self.validate([self.entry(source="../outside.swift")])

    def test_allowlist_is_bound_to_one_baseline(self):
        self.git("tag", "6.1.0")
        with self.assertRaises(allowlist.AllowlistError):
            self.validate([self.entry()], baseline="6.1.0", reviewed="6.0.2")

    def test_malformed_entries_are_rejected(self):
        for entries in (
            [self.entry(reason=" ")],
            [self.entry(message="func Driver.run(awaited:) has been removed")],
            [self.entry(), self.entry()],
            [{"message": "API breakage: x"}],
        ):
            with self.subTest(entries=entries):
                with self.assertRaises(allowlist.AllowlistError):
                    self.validate(entries)


if __name__ == "__main__":
    unittest.main()
