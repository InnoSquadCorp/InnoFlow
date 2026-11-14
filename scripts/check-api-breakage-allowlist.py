#!/usr/bin/env python3
"""Validate the reviewed API-breakage allowlist and render it for SwiftPM.

`swift package diagnose-api-breaking-changes` also reports declarations with
`package` access. Those cannot be used from another package, so changing them
is not a compatibility break for a consumer, but the digester cannot tell the
difference. This allowlist names such diagnostics one by one.

An entry is accepted only when the baseline source proves the point: the file
it cites must contain, at the baseline tag, a declaration line that starts
with `package` — the changed declaration itself, or the type that encloses
it. A `public` declaration can therefore never be listed. The allowlist is
bound to one baseline, so it has to be reviewed again when the stable version
moves.
"""
import argparse
import json
from pathlib import Path
import subprocess
import sys

PREFIX = "API breakage: "
FIELDS = {"message", "source", "declaration", "reason"}


class AllowlistError(Exception):
    pass


def baseline_source(root, baseline, source):
    if source.startswith("/") or ".." in Path(source).parts:
        raise AllowlistError(f"source must be a repository-relative path: {source}")
    result = subprocess.run(
        ["git", "-C", str(root), "show", f"refs/tags/{baseline}:{source}"],
        capture_output=True, text=True)
    if result.returncode != 0:
        raise AllowlistError(f"{source} does not exist at baseline {baseline}")
    return result.stdout


def validate(root, allowlist_path, baseline):
    try:
        document = json.loads(Path(allowlist_path).read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise AllowlistError(f"cannot read {allowlist_path}: {error}")
    if not isinstance(document, dict) or set(document) != {"schema", "baseline", "entries"}:
        raise AllowlistError("allowlist must contain exactly schema, baseline and entries")
    if document["schema"] != 1:
        raise AllowlistError("unsupported allowlist schema")
    if document["baseline"] != baseline:
        raise AllowlistError(
            f"allowlist was reviewed against {document['baseline']}, not {baseline}; "
            "review every entry again for the new baseline")
    entries = document["entries"]
    if not isinstance(entries, list):
        raise AllowlistError("entries must be a list")

    messages = []
    sources = {}
    for index, entry in enumerate(entries):
        where = f"entries[{index}]"
        if not isinstance(entry, dict) or set(entry) != FIELDS:
            raise AllowlistError(f"{where} must contain exactly {sorted(FIELDS)}")
        if not all(isinstance(entry[field], str) and entry[field].strip() for field in FIELDS):
            raise AllowlistError(f"{where} has an empty field")
        message, declaration = entry["message"], entry["declaration"].strip()
        if not message.startswith(PREFIX) or "\n" in message:
            raise AllowlistError(f"{where}.message must be one line starting with {PREFIX!r}")
        if message in messages:
            raise AllowlistError(f"{where}.message is listed twice")
        if not declaration.startswith("package "):
            raise AllowlistError(
                f"{where}.declaration must be a package-access declaration: {declaration}")
        source = entry["source"]
        if source not in sources:
            sources[source] = baseline_source(root, baseline, source)
        if not any(line.strip().startswith(declaration) for line in sources[source].splitlines()):
            raise AllowlistError(
                f"{where}: {source} at {baseline} has no line starting with {declaration!r}")
        messages.append(message)
    return messages


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--allowlist", required=True)
    parser.add_argument("--baseline", required=True)
    parser.add_argument("--output", required=True)
    arguments = parser.parse_args()
    try:
        messages = validate(Path(arguments.root), arguments.allowlist, arguments.baseline)
    except AllowlistError as error:
        print(f"[api-breakage-allowlist] {error}", file=sys.stderr)
        return 2
    Path(arguments.output).write_text("".join(f"{message}\n" for message in messages),
                                      encoding="utf-8")
    print(f"[api-breakage-allowlist] {len(messages)} reviewed package-access diagnostic(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
