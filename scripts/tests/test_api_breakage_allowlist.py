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

extension Store {
  package func send(_ action: Int, awaited: Bool) {}
  package func cancel<ID: Hashable>(id: ID, context: Int?) async {}
}

package final class Bridge {
  package func send() {}
}

package actor Runtime {}

/*
package func ghost() {}
*/
let template = \"\"\"
  package func phantom() {}
  \"\"\"
"""

NESTED = """\
public struct Outer {
  package struct Inner {
    package enum Mode {
      case fast
    }
  }
}

package struct Detached {}

package extension Outer {
  func helper() {}
}
"""


class APIBreakageAllowlistTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.git("init", "-q")
        (self.root / "Sources").mkdir()
        (self.root / "Sources/Runtime.swift").write_text(SOURCE, encoding="utf-8")
        (self.root / "Sources/Nested.swift").write_text(NESTED, encoding="utf-8")
        self.git("add", "Sources/Runtime.swift", "Sources/Nested.swift")
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

    def cited(self, subject, declaration, source="Sources/Runtime.swift"):
        return self.entry(message=f"API breakage: {subject} has been removed",
                          declaration=declaration, source=source)

    def validate(self, entries, baseline="6.0.2", reviewed="6.0.2"):
        path = self.root / "allowlist.json"
        path.write_text(json.dumps({"schema": 1, "baseline": reviewed, "entries": entries}),
                        encoding="utf-8")
        return allowlist.validate(self.root, path, baseline)

    def assertRejected(self, entry, reason):
        with self.assertRaisesRegex(allowlist.AllowlistError, reason):
            self.validate([entry])

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

    def test_message_binds_to_the_declaration_or_an_enclosing_type(self):
        for entry in (
            # The changed member itself, inside the type the message names.
            self.cited("func Store.send(_:awaited:)", "package func send("),
            self.cited("func Store.cancel(id:context:)", "package func cancel"),
            self.cited("func Bridge.send()", "package func send("),
            # The named type itself; the digester reports an actor as a class.
            self.cited("class Runtime", "package actor Runtime"),
            self.cited("protocol Driver", "package protocol Driver"),
            # A package type enclosing the named declaration.
            self.cited("func Bridge.send()", "package final class Bridge"),
            self.cited("struct Outer.Inner", "package struct Inner", "Sources/Nested.swift"),
            self.cited("var Outer.Inner.count", "package struct Inner", "Sources/Nested.swift"),
            self.entry(message="API breakage: enumelement Outer.Inner.Mode.slow has been added "
                               "as a new enum case",
                       declaration="package enum Mode", source="Sources/Nested.swift"),
        ):
            with self.subTest(message=entry["message"], declaration=entry["declaration"]):
                self.assertEqual(self.validate([entry]), [entry["message"]])

    def test_unrelated_package_declaration_cannot_stand_for_a_public_break(self):
        for entry in (
            # Any package type in the cited file used to be enough.
            self.cited("func Store.send()", "package protocol Driver"),
            self.cited("func Store.send(_:)", "package protocol Driver"),
            # Same base name, but another type or other argument labels.
            self.cited("func Store.send()", "package func send("),
            self.cited("func Store.send(_:context:)", "package func send("),
            self.cited("func Store.cancel(identifiedBy:)", "package func cancel"),
            # Same name with another declaration kind.
            self.cited("struct Runtime", "package actor Runtime"),
            self.cited("var Store.bridge", "package func bridge()"),
            self.cited("constructor Store.init()", "package func bridge()"),
            # A declaration prefix names the longer declaration it starts.
            self.cited("func Store.br()", "package func br"),
            # Lines in a comment or string literal are not declarations.
            self.cited("func ghost()", "package func ghost()"),
            self.cited("func phantom()", "package func phantom()"),
            # Nesting must match the path exactly.
            self.cited("struct Inner", "package struct Inner", "Sources/Nested.swift"),
            self.cited("func Outer.Detached.make()", "package struct Detached",
                       "Sources/Nested.swift"),
            # An extension never stands for the type it extends.
            self.cited("func Outer.helper()", "package extension Outer", "Sources/Nested.swift"),
        ):
            with self.subTest(message=entry["message"], declaration=entry["declaration"]):
                self.assertRejected(entry, "declares neither")

    def test_message_must_name_a_digester_declaration(self):
        for message in (
            "API breakage: Store has been removed",
            "API breakage: operator Store.+ has been removed",
            "API breakage: func Store..send() has been removed",
            "API breakage: func Store.send has been removed",
        ):
            with self.subTest(message=message):
                self.assertRejected(self.entry(message=message, declaration="package func send("),
                                    "must name a declaration")

    def test_unreadable_baseline_structure_is_rejected(self):
        # Unbalanced braces leave no reliable enclosing type, so nothing binds.
        (self.root / "Sources/Broken.swift").write_text(
            "package struct Broken {\n  package func open() {\n}\n", encoding="utf-8")
        self.git("add", "Sources/Broken.swift")
        self.git("-c", "user.name=Selftest", "-c", "user.email=selftest@invalid.example",
                 "commit", "-qm", "broken")
        self.git("tag", "6.0.3")
        with self.assertRaisesRegex(allowlist.AllowlistError, "cannot be read as Swift"):
            self.validate([self.cited("func Broken.open()", "package struct Broken",
                                      "Sources/Broken.swift")], baseline="6.0.3", reviewed="6.0.3")


if __name__ == "__main__":
    unittest.main()
