"""Keep versioned installation fragments bound to every validation contract."""
import hashlib
import json
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
READMES = ('README.md', 'README.ko.md', 'README.es.md', 'README.de.md', 'README.zh-Hans.md', 'README.ja.md', 'README.ru.md')


def verify_install_contracts(root):
    version = re.search(r"^## (\d+\.\d+\.\d+) Release$", (root / "RELEASE_NOTES.md").read_text(), re.M).group(1)
    syntax = json.loads((root / "docs/contracts/doc-swift-syntax-exceptions.json").read_text())["exceptions"]
    syntax_pairs = [(entry["file"], entry["sha256"]) for entry in syntax]
    ledger = (root / "docs/contracts/doc-swift-fence-review.tsv").read_text().splitlines()
    harness = (root / "scripts/check-doc-copyable-examples.rb").read_text()
    reviewer = (root / "scripts/report-doc-fence-review.rb").read_text()
    for readme in READMES:
        fragments = re.findall(r"^```swift\n(.*?)^```", (root / readme).read_text(), re.M | re.S)
        dependency, = [fragment for fragment in fragments if fragment.startswith("dependencies: [\n")]
        if f'from: "{version}"' not in dependency:
            raise ValueError(f"{readme}: candidate version mismatch")
        digest = hashlib.sha256(dependency.encode()).hexdigest()
        if syntax_pairs.count((readme, digest)) != 1:
            raise ValueError(f"{readme}: missing exact syntax context")
        if f"{readme}\t{digest}\tpartial\tdoc-copyable-install-manifest" not in ledger:
            raise ValueError(f"{readme}: missing exact review binding")
        if digest not in harness or digest not in reviewer:
            raise ValueError(f"{readme}: missing exact manifest harness binding")


class InstallationContractTests(unittest.TestCase):
    def test_candidate_fragments_match_all_contracts(self):
        verify_install_contracts(ROOT)

    def test_stale_syntax_digest_is_rejected(self):
        import shutil
        import tempfile
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for path in [*READMES, "RELEASE_NOTES.md", "docs/contracts/doc-swift-syntax-exceptions.json",
                         "docs/contracts/doc-swift-fence-review.tsv", "scripts/check-doc-copyable-examples.rb",
                         "scripts/report-doc-fence-review.rb"]:
                (root / path).parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(ROOT / path, root / path)
            path = root / "docs/contracts/doc-swift-syntax-exceptions.json"
            data = json.loads(path.read_text())
            entry = next(item for item in data["exceptions"] if item["file"] == "README.md" and item["reason"] == "Package.swift dependency-list fragment")
            entry["sha256"] = "0" * 64
            path.write_text(json.dumps(data))
            with self.assertRaisesRegex(ValueError, "missing exact syntax context"):
                verify_install_contracts(root)


if __name__ == "__main__":
    unittest.main()
