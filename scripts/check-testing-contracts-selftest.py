#!/usr/bin/env python3
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parent.parent
checker = root / 'scripts/check-testing-contracts.py'
paths = ['Sources/InnoFlowTesting', 'Sources/InnoFlowCore/FlowScope.swift', 'Tests/InnoFlowTests/StoreScopeSelectionTests.swift', 'Tests/InnoFlowTests/StoreEffectRuntimeTests.swift']
mutations = [
    ('source-column', 'Sources/InnoFlowTesting/TestStore+Public.swift', 'column: UInt = #column', 'column: UInt = 1'),
    ('test-framework-routing', 'Sources/InnoFlowTesting/TestStore+Assertions.swift', 'if Test.current != nil', 'if false'),
    ('scope-construction', 'Sources/InnoFlowCore/FlowScope.swift', 'fileprivate init()', 'public init()'),
    ('selection-fixed-sleep', 'Tests/InnoFlowTests/StoreScopeSelectionTests.swift', None, '\n// Task.sleep(for: .milliseconds(20))\n'),
    ('scenario-threshold', 'Sources/InnoFlowTesting/TestStoreScenario.swift', 'onceSleepersReach count: Int,', 'onceSleepersReach count: Int = 1,'),
]
with tempfile.TemporaryDirectory(prefix='innoflow-testing-contracts-') as directory:
    target = Path(directory)
    for relative in paths:
        source = root / relative
        destination = target / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        if source.is_dir():
            shutil.copytree(source, destination)
        else:
            shutil.copy2(source, destination)
    def run():
        return subprocess.run([sys.executable, str(checker), str(target)], capture_output=True, text=True)
    baseline = run()
    if baseline.returncode:
        raise SystemExit('Baseline contract check failed: ' + baseline.stdout)
    for name, relative, before, after in mutations:
        path = target / relative
        original = path.read_text()
        if before is not None and before not in original:
            raise SystemExit('Mutation anchor missing: ' + name)
        path.write_text(original + after if before is None else original.replace(before, after, 1))
        result = run()
        path.write_text(original)
        if result.returncode == 0:
            raise SystemExit('Negative control unexpectedly passed: ' + name)
        print('PASS negative control:', name)
print('PASS: baseline and all testing-contract negative controls')
