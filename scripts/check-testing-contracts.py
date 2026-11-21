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
if assertions.count('if TestStoreReportingContext.reportsThroughSwiftTesting') != 2:
    failures.append('Both failure and warning routing must inspect the owning test framework')
for contract in [
    'return Test.current != nil',
    'isSwiftTestingCurrent || ownerUsesSwiftTesting',
    '@TaskLocal package static var ownerUsesSwiftTesting = false',
    'sourceLocation: location.testingLocation',
    'XCTFail(message, file: location.filePath, line: location.line)',
]:
    if contract not in assertions:
        failures.append('Testing/XCTest reporting contract missing: ' + contract)
# An isolated deinitializer runs without task-locals, so the store must
# record its owning framework at initialization and restore it while it
# reports from deinit.
test_store = (root / 'Sources/InnoFlowTesting/TestStore.swift').read_text()
for contract in [
    'package let ownerUsesSwiftTesting = TestStoreReportingContext.isSwiftTestingCurrent',
    'TestStoreReportingContext.$ownerUsesSwiftTesting.withValue(ownerUsesSwiftTesting)',
]:
    if contract not in test_store:
        failures.append('TestStore deinit reporting contract missing: ' + contract)
scope = (root / 'Sources/InnoFlowCore/FlowScope.swift').read_text()
if re.search(r'\b(?:public|package|internal)\s+init\(', scope):
    failures.append('FlowScope construction must remain private to its lexical owner file')
if 'fileprivate init()' not in scope and 'private init()' not in scope:
    failures.append('FlowScope must explicitly restrict its initializer')
selection = (root / 'Tests/InnoFlowSwiftUIIntegrationTests/StoreScopeSelectionTests.swift').read_text()
if re.search(r'Task\.sleep\(for:\s*\.milliseconds\(20\)\)', selection):
    failures.append('Selection fixtures must await dispatch completion instead of fixed 20ms sleeps')
runtime = (root / 'Tests/InnoFlowTestingTests/StoreEffectRuntimeTests.swift').read_text()
combinator = runtime.split('func storeCombinatorComposition()', 1)[-1].split('\n  @Test', 1)[0]
if 'Task.sleep' in combinator or 'waitForNowReads' not in combinator or 'waitForSleepRegistrations' not in combinator:
    failures.append('Combinator fixture must synchronize clock reads and sleeper registration')
scenario = (root / 'Sources/InnoFlowTesting/TestStoreScenario.swift').read_text()
if re.search(r'onceSleepersReach count:\s*Int\?\s*=|onceSleepersReach count:\s*Int\s*=', scenario):
    failures.append('Scenario clock advance must require an explicit sleeper threshold')
# A clock step shares the store's one deadline and reports an unmet threshold;
# it must not fall back to the clock's own wait deadline or swallow the error.
if 'timeout: store.effectTimeout' not in scenario or 'store.issueReporter(' not in scenario:
    failures.append('Scenario clock advance must wait within the store deadline and report a miss')
explorer = (root / 'Sources/InnoFlowTesting/TestStoreExplorer.swift').read_text()
if 'clock.waitForSleepers(atLeast: sleepers, timeout: store.effectTimeout)' not in explorer or 'ContinuousClock().sleep(for: timeout)' in explorer:
    failures.append('Explorer clock registration must use the store deadline alone')
# TestStore accepts reducer-returned cancellation in the reduction turn through
# the traversal it shares with Store, at every site that starts an effect.
driver = (root / 'Sources/InnoFlowTesting/TestStore+EffectDriver.swift').read_text()
if 'extension TestStore: ReductionTurnCancellationAcceptor' not in driver:
    failures.append('TestStore must share reduction-turn cancellation acceptance with Store')
starts = sum(
    (root / 'Sources/InnoFlowTesting' / name).read_text().count('nextEffectContext(')
    for name in ['TestStore+Public.swift', 'TestStore+Exhaustivity.swift', 'TestStore+DeliveryOrder.swift'])
if starts:
    failures.append('TestStore must start reducer effects through reductionTurnContext(for:)')


def attribute_arguments(source, index):
    """Top-level arguments of the attribute argument clause at `index`; None if unterminated."""
    while index < len(source) and source[index] in ' \t':
        index += 1
    if index >= len(source) or source[index] != '(':
        return []
    arguments, depth, start, position = [], 0, index + 1, index
    while position < len(source):
        character = source[position]
        if character == '"':
            position += 1
            while position < len(source) and source[position] != '"':
                position += 2 if source[position] == '\\' else 1
        elif character in '([{':
            depth += 1
        elif character in ')]}':
            depth -= 1
            if depth == 0:
                return arguments + [source[start:position].strip()]
        elif character == ',' and depth == 1:
            arguments.append(source[start:position].strip())
            start = position + 1
        position += 1
    return None


# Every Swift Testing suite of the package test targets bounds its run time.
# Tests/Fixtures holds consumer packages, which are not package suites.
suites = 0
for directory in sorted(path for path in (root / 'Tests').iterdir() if path.is_dir() and path.name != 'Fixtures'):
    for path in sorted(directory.rglob('*.swift')):
        source = path.read_text()
        for match in re.finditer(r'@Suite\b', source):
            if '//' in source[source.rfind('\n', 0, match.start()) + 1:match.start()]:
                continue
            suites += 1
            arguments = attribute_arguments(source, match.end())
            if arguments is None or not any(argument.startswith('.timeLimit(') for argument in arguments):
                line = source.count('\n', 0, match.start()) + 1
                failures.append(f'{path.relative_to(root)}:{line}: @Suite must declare a .timeLimit trait')
if not suites:
    failures.append('No @Suite attribute found under Tests/<Target>; the time-limit check would be vacuous')

if failures:
    for failure in failures:
        print('FAIL:', failure)
    sys.exit(1)
print(f'PASS: testing source locations, framework routing, lexical scope, deterministic waits, '
      f'and time limits of {suites} suites')
