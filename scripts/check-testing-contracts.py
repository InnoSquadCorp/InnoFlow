#!/usr/bin/env python3
"""Static complements to executable Testing/dispatch/FlowScope contracts."""
from pathlib import Path
import re
import sys

root = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent
failures = []
for path in (root / 'Sources/InnoFlowTesting').glob('*.swift'):
    source = path.read_text()
    for match in re.finditer(r'public\s+(?:(?:static|convenience)\s+)?(?:func\s+[^\n(]+|init)\(', source):
        start = source.index('(', match.start())
        depth = 0
        end = start
        for end in range(start, len(source)):
            if source[end] == '(':
                depth += 1
            elif source[end] == ')':
                depth -= 1
                if depth == 0:
                    break
        parameters = source[start:end]
        if 'fileID: StaticString' in parameters:
            for name, default in [('fileID', '#fileID'), ('filePath', '#filePath'), ('line', '#line'), ('column', '#column')]:
                if not re.search(r'\b' + name + r':\s*(?:StaticString|UInt)\s*=\s*' + default + r'\b', parameters):
                    failures.append(f'{path.name}: canonical location lacks {name} caller default')
        if re.search(r'\bfile:\s*StaticString\s*=', parameters):
            failures.append(f'{path.name}: legacy file overload must require explicit file to avoid ambiguity')

assertions = (root / 'Sources/InnoFlowTesting/TestStore+Assertions.swift').read_text()
if assertions.count('if Test.current != nil') != 2:
    failures.append('Both failure and warning routing must inspect the current test framework')
for contract in ['if Test.current != nil', 'sourceLocation: location.testingLocation', 'XCTFail(message, file: location.filePath, line: location.line)']:
    if contract not in assertions:
        failures.append('Testing/XCTest reporting contract missing: ' + contract)
scope = (root / 'Sources/InnoFlowCore/FlowScope.swift').read_text()
if re.search(r'\b(?:public|package|internal)\s+init\(', scope):
    failures.append('FlowScope construction must remain private to its lexical owner file')
if 'fileprivate init()' not in scope and 'private init()' not in scope:
    failures.append('FlowScope must explicitly restrict its initializer')
selection = (root / 'Tests/InnoFlowTests/StoreScopeSelectionTests.swift').read_text()
if re.search(r'Task\.sleep\(for:\s*\.milliseconds\(20\)\)', selection):
    failures.append('Selection fixtures must await dispatch completion instead of fixed 20ms sleeps')
runtime = (root / 'Tests/InnoFlowTests/StoreEffectRuntimeTests.swift').read_text()
combinator = runtime.split('func storeCombinatorComposition()', 1)[-1].split('\n  @Test', 1)[0]
if 'Task.sleep' in combinator or 'waitForNowReads' not in combinator or 'waitForSleepRegistrations' not in combinator:
    failures.append('Combinator fixture must synchronize clock reads and sleeper registration')
scenario = (root / 'Sources/InnoFlowTesting/TestStoreScenario.swift').read_text()
if re.search(r'onceSleepersReach count:\s*Int\?\s*=|onceSleepersReach count:\s*Int\s*=', scenario):
    failures.append('Scenario clock advance must require an explicit sleeper threshold')

if failures:
    for failure in failures:
        print('FAIL:', failure)
    sys.exit(1)
print('PASS: testing source locations, framework routing, lexical scope, and deterministic waits')
