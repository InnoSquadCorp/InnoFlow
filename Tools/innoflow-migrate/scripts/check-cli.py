#!/usr/bin/env python3
"""Exercise the real CLI binary, filesystem safety, status codes, and dry-run contract."""
import pathlib
import subprocess
import sys
import tempfile

binary = str(pathlib.Path(sys.argv[1]).resolve())
source = "@InnoFlow struct F { var body: some Reducer<State, Action> { Reduce { _, _ in .none } } }\n"
expected = source.replace("Action>", "Action, Never>")

def run(*args, code=0):
    result = subprocess.run([binary, *map(str, args)], capture_output=True, text=True)
    assert result.returncode == code, (args, result.returncode, result.stdout, result.stderr)
    return result

with tempfile.TemporaryDirectory(prefix="innoflow-cli-") as directory:
    root = pathlib.Path(directory)
    valid = root / "Feature.swift"
    valid.write_text(source)
    dry = run(valid)
    assert valid.read_text() == source
    assert "@@ -" in dry.stdout and "edit:" in dry.stderr
    assert not list(root.glob("*.bak"))
    run("--check", valid, code=1)
    malformed = root / "Malformed.swift"
    malformed.write_text("@InnoFlow struct F {")
    run("--write", valid, malformed, code=2)
    assert valid.read_text() == source and not list(root.glob("*.bak"))
    unresolved = root / "Unresolved.swift"
    unresolved.write_text("import InnoFlow\nlet scope = FlowScope()")
    run("--write", valid, unresolved, code=2)
    assert valid.read_text() == source and not list(root.glob("*.bak"))
    run("--write", valid)
    assert valid.read_text() == expected
    backup = pathlib.Path(str(valid) + ".innoflow-migrate.bak")
    assert backup.read_text() == source
    assert run("--check", valid).stdout == ""
    assert run("--write", valid).stdout == ""
    assert backup.read_text() == source
    valid.write_text(source)
    run("--write", valid, code=2)  # Never overwrite a retained backup.
    assert valid.read_text() == source and backup.read_text() == source
    link = root / "Link.swift"
    link.symlink_to(valid)
    run("--write", link, code=2)
    run("--write", valid, valid, code=2)
    run("--check", "--write", valid, code=2)
    run("--unknown", valid, code=2)
    run("--write", code=2)
    run("--help")
print("[innoflow-migrate] CLI filesystem and exit-code controls passed")
