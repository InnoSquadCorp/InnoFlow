// MARK: - TestSupport.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
import Testing
import os

@testable import InnoFlowCore
@testable import InnoFlowTesting

// MARK: - Compile Contract Helpers

func effectOperationSignature<Action: Sendable>(_ effect: EffectTask<Action>) -> String {
  switch effect.operation {
  case .none:
    return "none"

  case .send(let action):
    return "send(\(String(describing: action)))"

  case .run(let priority, _):
    return "run(priority:\(String(describing: priority)))"

  case .merge(let children):
    return "merge(\(children.map(effectOperationSignature).joined(separator: ",")))"

  case .concatenate(let children):
    return "concatenate(\(children.map(effectOperationSignature).joined(separator: ",")))"

  case .cancel(let id):
    return "cancel(\(id.description))"

  case .cancellable(let nested, let id, let cancelInFlight):
    return
      "cancellable(id:\(id.description),cancelInFlight:\(cancelInFlight),nested:\(effectOperationSignature(nested)))"

  case .debounce(let nested, let id, let interval):
    return
      "debounce(id:\(id.description),interval:\(interval),nested:\(effectOperationSignature(nested)))"

  case .throttle(let nested, let id, let interval, let leading, let trailing):
    return
      "throttle(id:\(id.description),interval:\(interval),leading:\(leading),trailing:\(trailing),nested:\(effectOperationSignature(nested)))"

  case .animation(let nested, let animation):
    return "animation(\(String(describing: animation)),nested:\(effectOperationSignature(nested)))"

  case .lazyMap(let lazy):
    return effectOperationSignature(lazy.materialize())
  }
}

func normalizedConcatenateSignature<Action: Sendable>(_ effect: EffectTask<Action>)
  -> String
{
  switch effect.operation {
  case .concatenate(let children):
    return
      children
      .flatMap(flattenConcatenateChildren)
      .map(effectOperationSignature)
      .joined(separator: " -> ")

  default:
    return effectOperationSignature(effect)
  }
}

func flattenConcatenateChildren<Action: Sendable>(_ effect: EffectTask<Action>)
  -> [EffectTask<Action>]
{
  switch effect.operation {
  case .concatenate(let children):
    return children.flatMap(flattenConcatenateChildren)

  default:
    return [effect]
  }
}

enum TimingScenarioStep: Sendable {
  case trigger(Int)
  case advance(Int)
}

struct TimingScenarioExpectation: Equatable, Sendable {
  var outputs: [Int]
  var emissionCountsAfterSteps: [Int]
}

func makeTimingScenario(
  seed: UInt64,
  maxSteps: Int = 100
) -> [TimingScenarioStep] {
  var rng = SeededGenerator(seed: seed)
  let count = rng.nextInt(upperBound: maxSteps - 20) + 20
  var steps: [TimingScenarioStep] = []

  for index in 0..<count {
    if index == 0 || rng.nextInt(upperBound: 100) < 60 {
      steps.append(.trigger(rng.nextInt(upperBound: 10_000)))
    } else {
      steps.append(.advance(rng.nextInt(upperBound: 120) + 1))
    }
  }

  steps.append(.advance(200))
  return steps
}

func expectedDebounceOutputs(
  for steps: [TimingScenarioStep],
  intervalMilliseconds: Int
) -> [Int] {
  expectedDebounceTimeline(
    for: steps,
    intervalMilliseconds: intervalMilliseconds
  ).outputs
}

func expectedDebounceTimeline(
  for steps: [TimingScenarioStep],
  intervalMilliseconds: Int
) -> TimingScenarioExpectation {
  var time = 0
  var pending: (value: Int, due: Int)?
  var emitted: [Int] = []
  var countsAfterSteps: [Int] = []

  for step in steps {
    switch step {
    case .trigger(let value):
      pending = (value, time + intervalMilliseconds)

    case .advance(let delta):
      time += delta
      if let scheduled = pending, scheduled.due <= time {
        emitted.append(scheduled.value)
        pending = nil
      }
    }

    countsAfterSteps.append(emitted.count)
  }

  return .init(
    outputs: emitted,
    emissionCountsAfterSteps: countsAfterSteps
  )
}

func expectedThrottleOutputs(
  for steps: [TimingScenarioStep],
  intervalMilliseconds: Int,
  leading: Bool,
  trailing: Bool
) -> [Int] {
  expectedThrottleTimeline(
    for: steps,
    intervalMilliseconds: intervalMilliseconds,
    leading: leading,
    trailing: trailing
  ).outputs
}

func expectedThrottleTimeline(
  for steps: [TimingScenarioStep],
  intervalMilliseconds: Int,
  leading: Bool,
  trailing: Bool
) -> TimingScenarioExpectation {
  precondition(leading || trailing)

  var time = 0
  var windowEnd: Int?
  var pending: Int?
  var emitted: [Int] = []
  var countsAfterSteps: [Int] = []

  for step in steps {
    switch step {
    case .trigger(let value):
      if let activeWindowEnd = windowEnd, time < activeWindowEnd {
        if trailing {
          pending = value
        }
        countsAfterSteps.append(emitted.count)
        continue
      }

      windowEnd = time + intervalMilliseconds
      pending = nil

      if leading {
        emitted.append(value)
      } else if trailing {
        pending = value
      }

    case .advance(let delta):
      time += delta
      if let activeWindowEnd = windowEnd, activeWindowEnd <= time {
        if trailing, let pending {
          emitted.append(pending)
        }
        windowEnd = nil
        pending = nil
      }
    }

    countsAfterSteps.append(emitted.count)
  }

  return .init(
    outputs: emitted,
    emissionCountsAfterSteps: countsAfterSteps
  )
}

@MainActor
func runTimingScenario<R: Reducer>(
  reducer: R,
  steps: [TimingScenarioStep],
  trigger: @escaping (Int) -> R.Action,
  emitted: KeyPath<R.State, [Int]>,
  expectedCount: Int,
  expectedCountAfterEachStep: [Int]? = nil
) async -> [Int]
where
  R.State: Equatable & Sendable & DefaultInitializable,
  R.Action: Sendable
{
  if let expectedCountAfterEachStep {
    precondition(expectedCountAfterEachStep.count == steps.count)
  }

  let clock = ManualTestClock()
  let store = Store(
    reducer: reducer,
    initialState: .init(),
    clock: .manual(clock)
  )

  for (index, step) in steps.enumerated() {
    switch step {
    case .trigger(let value):
      store.send(trigger(value))
      await settleTimingScenarioWork()

    case .advance(let milliseconds):
      await settleTimingScenarioWork()
      await clock.advance(by: .milliseconds(milliseconds))
      await settleTimingScenarioWork()
    }

    if let expectedCountAfterEachStep {
      await waitForEmissionCount(
        store,
        emitted: emitted,
        minimumCount: expectedCountAfterEachStep[index]
      )
    }
  }

  await waitForEmissionCount(
    store,
    emitted: emitted,
    minimumCount: expectedCount
  )

  return store.state[keyPath: emitted]
}

func settleTimingScenarioWork() async {
  // `Store.send` schedules non-`.send` effects onto a separate Task. For the
  // randomized debounce/throttle property tests, some in-window updates only
  // mutate internal pending state and do not immediately change user-visible
  // state or sleeper counts. A pure `Task.yield()` loop can therefore advance
  // the manual clock before the walker Task has actually applied the pending
  // replacement under release optimization. Add a tiny wall-clock handoff so
  // the queued Task gets a real executor turn before the scenario continues.
  await drainAsyncWork(iterations: 64)
  try? await Task.sleep(for: .milliseconds(1))
  await drainAsyncWork(iterations: 64)
}

@MainActor
func waitForEmissionCount<R: Reducer>(
  _ store: Store<R>,
  emitted: KeyPath<R.State, [Int]>,
  minimumCount: Int,
  maxIterations: Int = 1_024
) async {
  guard minimumCount > 0 else { return }

  for _ in 0..<maxIterations {
    if store.state[keyPath: emitted].count >= minimumCount {
      return
    }
    await Task.yield()
  }
}

func drainAsyncWork(iterations: Int = 128) async {
  for _ in 0..<iterations {
    await Task.yield()
  }
}

@MainActor
func waitUntil(
  timeout: Duration = .seconds(2),
  pollInterval: Duration = .milliseconds(20),
  condition: @escaping @MainActor () -> Bool
) async {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: timeout)

  while clock.now < deadline {
    if condition() {
      return
    }
    try? await Task.sleep(for: pollInterval)
  }
}

func waitUntilAsync(
  timeout: Duration = .seconds(2),
  pollInterval: Duration = .milliseconds(20),
  settleIterations: Int = 16,
  condition: @escaping @Sendable () async -> Bool
) async -> Bool {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: timeout)

  while clock.now < deadline {
    if await condition() {
      return true
    }
    await drainAsyncWork(iterations: settleIterations)
    try? await Task.sleep(for: pollInterval)
  }

  return await condition()
}

@MainActor
func waitForProjectionObserverStats<R: Reducer>(
  _ store: Store<R>,
  timeout: Duration = .seconds(2),
  pollInterval: Duration = .milliseconds(10),
  condition: @escaping @MainActor (ProjectionObserverRegistryStats) -> Bool
) async {
  await waitUntil(timeout: timeout, pollInterval: pollInterval) {
    condition(store.projectionObserverStats)
  }
}

@MainActor
func waitForProjectionRefreshPass<R: Reducer>(
  _ store: Store<R>,
  after previousStats: ProjectionObserverRegistryStats,
  timeout: Duration = .seconds(2),
  pollInterval: Duration = .milliseconds(10)
) async {
  await waitForProjectionObserverStats(
    store,
    timeout: timeout,
    pollInterval: pollInterval
  ) { stats in
    stats.refreshPassCount > previousStats.refreshPassCount
  }
}

var isHeavyStressEnabled: Bool {
  ProcessInfo.processInfo.environment["INNOFLOW_HEAVY_STRESS"] == "1"
}

var isPerformanceBenchmarkEnabled: Bool {
  ProcessInfo.processInfo.environment["INNOFLOW_PERF_BENCHMARKS"] == "1"
}

struct SeededGenerator {
  private var state: UInt64

  init(seed: UInt64) {
    self.state = seed == 0 ? 0x1234_5678_9ABC_DEF0 : seed
  }

  mutating func next() -> UInt64 {
    state = 2_862_933_555_777_941_757 &* state &+ 3_037_000_493
    return state
  }

  mutating func nextInt(upperBound: Int) -> Int {
    precondition(upperBound > 0)
    return Int(next() % UInt64(upperBound))
  }
}

struct TypecheckResult {
  let status: Int32
  let output: String
}

extension TypecheckResult {
  var normalizedOutput: String {
    output.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

private final class ThreadSafeDataBuffer: Sendable {
  private let data = OSAllocatedUnfairLock<Data>(initialState: .init())

  func append(_ chunk: Data) {
    data.withLock { $0.append(chunk) }
  }

  func snapshot() -> Data {
    data.withLock { $0 }
  }
}

enum CompileContractError: Error, CustomStringConvertible {
  case moduleNotFound(attemptedPaths: [String])

  var description: String {
    switch self {
    case .moduleNotFound(let attemptedPaths):
      let formattedPaths =
        attemptedPaths
        .map { "- \($0)" }
        .joined(separator: "\n")
      return """
        Failed to locate InnoFlow.swiftmodule.
        Attempted search locations:
        \(formattedPaths)
        """
    }
  }
}

func findBuiltModuleDirectory(
  named moduleName: String,
  in packageRoot: URL,
  configuration: String? = nil,
  additionalSearchRoots: [URL] = []
) throws -> URL {
  let fileManager = FileManager.default
  let buildDirectory = packageRoot.appendingPathComponent(".build", isDirectory: true)
  var attemptedPaths: [String] = []

  func appendCandidate(_ url: URL) {
    attemptedPaths.append(url.path)
    attemptedPaths.append(url.appendingPathComponent("Modules", isDirectory: true).path)
    attemptedPaths.append(url.appendingPathComponent("Modules-tool", isDirectory: true).path)
    attemptedPaths.append(url.appendingPathComponent("debug", isDirectory: true).path)
    attemptedPaths.append(url.appendingPathComponent("release", isDirectory: true).path)
  }

  func appendCandidateAndAncestors(from url: URL, limit: Int = 8) {
    var current = url
    for _ in 0..<limit {
      appendCandidate(current)
      let parent = current.deletingLastPathComponent()
      if parent.path == current.path { break }
      current = parent
    }
  }

  for root in additionalSearchRoots {
    appendCandidateAndAncestors(from: root)
  }
  if let executableURL = Bundle.main.executableURL {
    appendCandidateAndAncestors(from: executableURL.deletingLastPathComponent())
  }
  if let executablePath = CommandLine.arguments.first, !executablePath.isEmpty {
    appendCandidateAndAncestors(
      from: URL(fileURLWithPath: executablePath).deletingLastPathComponent()
    )
  }
  appendCandidate(packageRoot)
  appendCandidate(buildDirectory)
  appendCandidate(buildDirectory.appendingPathComponent("arm64-apple-macosx", isDirectory: true))
  appendCandidate(buildDirectory.appendingPathComponent("x86_64-apple-macosx", isDirectory: true))

  if let buildChildren = try? fileManager.contentsOfDirectory(
    at: buildDirectory,
    includingPropertiesForKeys: [.isDirectoryKey],
    options: [.skipsHiddenFiles]
  ) {
    for child in buildChildren {
      appendCandidate(child)
    }
  }

  let orderedAttemptedPaths = attemptedPaths.reduce(into: [String]()) { result, path in
    if !result.contains(path) {
      result.append(path)
    }
  }
  attemptedPaths = Array(Set(attemptedPaths)).sorted()

  var matches: [(directory: URL, modificationDate: Date)] = []

  func appendMatchIfPresent(at directory: URL) {
    let moduleURL = directory.appendingPathComponent("\(moduleName).swiftmodule")
    guard fileManager.fileExists(atPath: moduleURL.path) else { return }
    let resourceValues = try? moduleURL.resourceValues(forKeys: [.contentModificationDateKey])
    let modificationDate = resourceValues?.contentModificationDate ?? .distantPast
    matches.append((directory, modificationDate))
  }

  for attemptedPath in orderedAttemptedPaths {
    if let configuration,
      !URL(fileURLWithPath: attemptedPath).pathComponents.contains(configuration)
    {
      continue
    }

    let directory = URL(fileURLWithPath: attemptedPath, isDirectory: true)
    appendMatchIfPresent(at: directory)
  }

  guard
    let enumerator = fileManager.enumerator(
      at: buildDirectory,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles]
    )
  else {
    throw CompileContractError.moduleNotFound(attemptedPaths: attemptedPaths)
  }

  for case let fileURL as URL in enumerator
  where fileURL.lastPathComponent == "\(moduleName).swiftmodule" {
    if let configuration,
      !fileURL.path.contains("/\(configuration)/")
    {
      continue
    }
    let resourceValues = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey])
    let modificationDate = resourceValues?.contentModificationDate ?? .distantPast
    matches.append((fileURL.deletingLastPathComponent(), modificationDate))
  }

  if let newest = matches.max(by: { $0.modificationDate < $1.modificationDate }) {
    return newest.directory
  }

  throw CompileContractError.moduleNotFound(attemptedPaths: attemptedPaths)
}

func findBuiltInnoFlowModuleDirectory(
  in packageRoot: URL,
  configuration: String? = nil
) throws -> URL {
  try findBuiltModuleDirectory(
    named: "InnoFlow",
    in: packageRoot,
    configuration: configuration
  )
}

func typecheckSource(
  _ source: String,
  moduleDirectory: URL
) throws -> TypecheckResult {
  let temporaryDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

  let sourceFile = temporaryDirectory.appendingPathComponent("CompileContract.swift")
  try source.write(to: sourceFile, atomically: true, encoding: .utf8)

  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
  process.arguments = [
    "swiftc",
    "-typecheck",
    sourceFile.path,
    "-I",
    moduleDirectory.path,
  ]

  let stdoutPipe = Pipe()
  let stderrPipe = Pipe()
  process.standardOutput = stdoutPipe
  process.standardError = stderrPipe

  let stdoutBuffer = ThreadSafeDataBuffer()
  let stderrBuffer = ThreadSafeDataBuffer()

  stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
    let data = handle.availableData
    guard !data.isEmpty else { return }
    stdoutBuffer.append(data)
  }

  stderrPipe.fileHandleForReading.readabilityHandler = { handle in
    let data = handle.availableData
    guard !data.isEmpty else { return }
    stderrBuffer.append(data)
  }

  try process.run()
  process.waitUntilExit()

  stdoutPipe.fileHandleForReading.readabilityHandler = nil
  stderrPipe.fileHandleForReading.readabilityHandler = nil

  var stderrData = stderrBuffer.snapshot()

  var stdoutData = stdoutBuffer.snapshot()
  let stderrTail = stderrPipe.fileHandleForReading.readDataToEndOfFile()
  let stdoutTail = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
  if !stdoutTail.isEmpty {
    stdoutData.append(stdoutTail)
  }
  if !stderrTail.isEmpty {
    stderrData.append(stderrTail)
  }

  let stdoutText = String(data: stdoutData, encoding: .utf8) ?? ""
  let stderrText = String(data: stderrData, encoding: .utf8) ?? ""

  return TypecheckResult(
    status: process.terminationStatus,
    output: stdoutText + "\n" + stderrText
  )
}

struct ProcessResult {
  let status: Int32
  let output: String
}

extension ProcessResult {
  var normalizedOutput: String {
    output.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

enum StaleScopedStoreScenario: String {
  case parentReleased = "parent-released"
  case collectionEntryRemoved = "collection-entry-removed"
  case selectedParentReleased = "selected-parent-released"
}

enum StaleScopeHarnessError: Error, CustomStringConvertible {
  case objectFilesNotFound(buildDirectory: String)
  case compileFailed(output: String)

  var description: String {
    switch self {
    case .objectFilesNotFound(let buildDirectory):
      return "Failed to locate compiled InnoFlow object files in \(buildDirectory)"
    case .compileFailed(let output):
      return "Failed to compile stale scope harness.\n\(output)"
    }
  }
}

func currentInnoFlowPackageRoot() -> URL {
  URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
}

func findBuiltObjectFiles(
  for targetName: String,
  in packageRoot: URL,
  configuration: String? = nil
) throws -> [URL] {
  let buildDirectory = packageRoot.appendingPathComponent(".build", isDirectory: true)
  guard
    let enumerator = FileManager.default.enumerator(
      at: buildDirectory,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles]
    )
  else {
    throw StaleScopeHarnessError.objectFilesNotFound(buildDirectory: buildDirectory.path)
  }

  let objectFiles =
    (enumerator.compactMap { $0 as? URL })
    .filter {
      $0.pathExtension == "o"
        && $0.deletingLastPathComponent().lastPathComponent == "\(targetName).build"
        && (configuration == nil || $0.path.contains("/\(configuration!)/"))
    }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }

  guard !objectFiles.isEmpty else {
    throw StaleScopeHarnessError.objectFilesNotFound(buildDirectory: buildDirectory.path)
  }

  return objectFiles
}

func findBuiltInnoFlowObjectFiles(
  in packageRoot: URL,
  configuration: String? = nil
) throws -> [URL] {
  try findBuiltObjectFiles(
    for: "InnoFlow",
    in: packageRoot,
    configuration: configuration
  )
}

func runProcess(
  executableURL: URL,
  arguments: [String],
  environment: [String: String] = [:],
  currentDirectoryURL: URL? = nil
) throws -> ProcessResult {
  let process = Process()
  process.executableURL = executableURL
  process.arguments = arguments
  process.currentDirectoryURL = currentDirectoryURL

  if !environment.isEmpty {
    var mergedEnvironment = ProcessInfo.processInfo.environment
    for (key, value) in environment {
      mergedEnvironment[key] = value
    }
    process.environment = mergedEnvironment
  }

  let stdoutPipe = Pipe()
  let stderrPipe = Pipe()
  process.standardOutput = stdoutPipe
  process.standardError = stderrPipe

  let stdoutBuffer = ThreadSafeDataBuffer()
  let stderrBuffer = ThreadSafeDataBuffer()

  stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
    let data = handle.availableData
    guard !data.isEmpty else { return }
    stdoutBuffer.append(data)
  }

  stderrPipe.fileHandleForReading.readabilityHandler = { handle in
    let data = handle.availableData
    guard !data.isEmpty else { return }
    stderrBuffer.append(data)
  }

  try process.run()
  process.waitUntilExit()

  stdoutPipe.fileHandleForReading.readabilityHandler = nil
  stderrPipe.fileHandleForReading.readabilityHandler = nil

  var stdoutData = stdoutBuffer.snapshot()
  var stderrData = stderrBuffer.snapshot()

  let stdoutTail = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
  let stderrTail = stderrPipe.fileHandleForReading.readDataToEndOfFile()
  if !stdoutTail.isEmpty {
    stdoutData.append(stdoutTail)
  }
  if !stderrTail.isEmpty {
    stderrData.append(stderrTail)
  }

  return ProcessResult(
    status: process.terminationStatus,
    output: (String(data: stdoutData, encoding: .utf8) ?? "")
      + "\n"
      + (String(data: stderrData, encoding: .utf8) ?? "")
  )
}

func runStaleScopedStoreHarness(
  scenario: StaleScopedStoreScenario
) throws -> ProcessResult {
  let packageRoot = currentInnoFlowPackageRoot()
  let temporaryDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

  let sourceFile = temporaryDirectory.appendingPathComponent("StaleScopeProbe.swift")
  let executableURL = temporaryDirectory.appendingPathComponent("StaleScopeProbe")
  try staleScopedStoreHarnessSource.write(to: sourceFile, atomically: true, encoding: .utf8)

  // Inline-compile InnoFlow sources with the probe at `-Onone` so debug-only
  // `assertionFailure` traps are live and so the build is independent of the
  // enclosing `swift test` configuration (previously we linked `.build/*/*.o`,
  // which produced duplicate-symbol link errors under `swift test -c release`
  // whenever both debug and release `.build/` directories existed).
  let compileResult = try runProcess(
    executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
    arguments: [
      "swiftc",
      "-Onone",
      "-parse-as-library",
      "-package-name", "InnoFlow",
      sourceFile.path,
    ] + (try innoFlowCoreSourcePaths(in: packageRoot)) + [
      "-o", executableURL.path,
    ]
  )

  guard compileResult.status == 0 else {
    throw StaleScopeHarnessError.compileFailed(output: compileResult.normalizedOutput)
  }

  return try runProcess(
    executableURL: executableURL,
    arguments: [],
    environment: ["INNOFLOW_STALE_SCOPE_SCENARIO": scenario.rawValue]
  )
}

enum ConditionalReducerReleaseScenario: String {
  case ifLetAbsentState = "iflet-absent-state"
  case ifCaseLetMismatchedState = "ifcase-mismatched-state"
}

enum StaleScopedStoreReleaseScenario: String {
  case parentReleased = "parent-released"
  case collectionEntryRemoved = "collection-entry-removed"
  case selectedParentReleased = "selected-parent-released"
}

func runStaleScopedStoreReleaseHarness(
  scenario: StaleScopedStoreReleaseScenario
) throws -> ProcessResult {
  let packageRoot = currentInnoFlowPackageRoot()
  let temporaryDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

  let sourceFile = temporaryDirectory.appendingPathComponent("StaleScopeReleaseProbe.swift")
  let executableURL = temporaryDirectory.appendingPathComponent("StaleScopeReleaseProbe")
  try staleScopedStoreReleaseHarnessSource.write(to: sourceFile, atomically: true, encoding: .utf8)

  let compileResult = try runProcess(
    executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
    arguments: [
      "swiftc",
      "-O",
      "-parse-as-library",
      "-package-name",
      "InnoFlow",
      sourceFile.path,
    ] + (try innoFlowCoreSourcePaths(in: packageRoot)) + [
      "-o",
      executableURL.path,
    ]
  )

  guard compileResult.status == 0 else {
    throw StaleScopeHarnessError.compileFailed(output: compileResult.normalizedOutput)
  }

  return try runProcess(
    executableURL: executableURL,
    arguments: [],
    environment: ["INNOFLOW_STALE_SCOPE_RELEASE_SCENARIO": scenario.rawValue]
  )
}

enum PhaseMapCrashScenario: String {
  case directMutationCrash = "direct-mutation-crash"
  case undeclaredTargetCrash = "undeclared-target-crash"
}

enum PhaseMapReleaseScenario: String {
  case directMutationRestore = "direct-mutation-restore"
  case undeclaredTargetNoOp = "undeclared-target-noop"
}

enum ConditionalReducerHarnessError: Error, CustomStringConvertible {
  case compileFailed(output: String)

  var description: String {
    switch self {
    case .compileFailed(let output):
      return "Failed to compile conditional reducer release harness.\n\(output)"
    }
  }
}

enum PhaseMapHarnessError: Error, CustomStringConvertible {
  case compileFailed(output: String)

  var description: String {
    switch self {
    case .compileFailed(let output):
      return "Failed to compile PhaseMap harness.\n\(output)"
    }
  }
}

func runConditionalReducerReleaseHarness(
  scenario: ConditionalReducerReleaseScenario
) throws -> ProcessResult {
  let packageRoot = currentInnoFlowPackageRoot()
  let temporaryDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

  let sourceFile = temporaryDirectory.appendingPathComponent("ConditionalReducerProbe.swift")
  let executableURL = temporaryDirectory.appendingPathComponent("ConditionalReducerProbe")
  try conditionalReducerReleaseHarnessSource.write(
    to: sourceFile, atomically: true, encoding: .utf8)

  let compileResult = try runProcess(
    executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
    arguments: [
      "swiftc",
      "-O",
      "-parse-as-library",
      "-package-name",
      "InnoFlow",
      sourceFile.path,
    ] + (try innoFlowCoreSourcePaths(in: packageRoot)) + [
      "-o",
      executableURL.path,
    ]
  )

  guard compileResult.status == 0 else {
    throw ConditionalReducerHarnessError.compileFailed(output: compileResult.normalizedOutput)
  }

  return try runProcess(
    executableURL: executableURL,
    arguments: [],
    environment: ["INNOFLOW_CONDITIONAL_REDUCER_SCENARIO": scenario.rawValue]
  )
}

func innoFlowCoreSourcePaths(in packageRoot: URL) throws -> [String] {
  try FileManager.default
    .contentsOfDirectory(
      at: packageRoot.appendingPathComponent("Sources/InnoFlowCore", isDirectory: true),
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    )
    .filter { $0.pathExtension == "swift" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
    .map(\.path)
}

func runPhaseMapCrashHarness(
  scenario: PhaseMapCrashScenario
) throws -> ProcessResult {
  let packageRoot = currentInnoFlowPackageRoot()
  let temporaryDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

  let sourceFile = temporaryDirectory.appendingPathComponent("PhaseMapCrashProbe.swift")
  let executableURL = temporaryDirectory.appendingPathComponent("PhaseMapCrashProbe")
  try phaseMapCrashHarnessSource.write(to: sourceFile, atomically: true, encoding: .utf8)

  // Inline-compile InnoFlow sources with the probe at `-Onone` so the
  // PhaseMap `assertionFailure` traps we are asserting on are live, and so
  // the build is independent of the enclosing `swift test` configuration.
  // Previously we linked `.build/*/*.o`, which surfaced duplicate-symbol
  // link errors under `swift test -c release` whenever both debug and
  // release `.build/` directories existed.
  let compileResult = try runProcess(
    executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
    arguments: [
      "swiftc",
      "-Onone",
      "-parse-as-library",
      "-package-name", "InnoFlow",
      sourceFile.path,
    ] + (try innoFlowCoreSourcePaths(in: packageRoot)) + [
      "-o", executableURL.path,
    ]
  )

  guard compileResult.status == 0 else {
    throw PhaseMapHarnessError.compileFailed(output: compileResult.normalizedOutput)
  }

  return try runProcess(
    executableURL: executableURL,
    arguments: [],
    environment: ["INNOFLOW_PHASEMAP_CRASH_SCENARIO": scenario.rawValue]
  )
}

func runPhaseMapReleaseHarness(
  scenario: PhaseMapReleaseScenario
) throws -> ProcessResult {
  let packageRoot = currentInnoFlowPackageRoot()
  let temporaryDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

  let sourceFile = temporaryDirectory.appendingPathComponent("PhaseMapReleaseProbe.swift")
  let executableURL = temporaryDirectory.appendingPathComponent("PhaseMapReleaseProbe")
  try phaseMapReleaseHarnessSource.write(to: sourceFile, atomically: true, encoding: .utf8)

  let compileResult = try runProcess(
    executableURL: URL(fileURLWithPath: "/usr/bin/xcrun"),
    arguments: [
      "swiftc",
      "-O",
      "-parse-as-library",
      "-package-name",
      "InnoFlow",
      sourceFile.path,
    ] + (try innoFlowCoreSourcePaths(in: packageRoot)) + [
      "-o",
      executableURL.path,
    ]
  )

  guard compileResult.status == 0 else {
    throw PhaseMapHarnessError.compileFailed(output: compileResult.normalizedOutput)
  }

  return try runProcess(
    executableURL: executableURL,
    arguments: [],
    environment: ["INNOFLOW_PHASEMAP_RELEASE_SCENARIO": scenario.rawValue]
  )
}

private let conditionalReducerReleaseHarnessSource = #"""
  import Foundation

  struct ReleaseIfLetFeature: Reducer {
    struct ChildState: Equatable, Sendable {
      var count = 0
    }

    struct State: Equatable, Sendable {
      var child: ChildState?
      var untouched = 7
    }

    enum Action: Equatable, Sendable {
      case child(ChildAction)

      static let childCasePath = CasePath<Self, ChildAction>(
        embed: Action.child,
        extract: { action in
          guard case .child(let childAction) = action else { return nil }
          return childAction
        }
      )
    }

    enum ChildAction: Equatable, Sendable {
      case increment
    }

    struct ChildReducer: Reducer {
      func reduce(into state: inout ChildState, action: ChildAction) -> EffectTask<ChildAction> {
        switch action {
        case .increment:
          state.count += 1
          return .none
        }
      }
    }

    func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
      CombineReducers<State, Action> {
        Reduce { _, _ in .none }
        IfLet(
          state: \.child,
          action: Action.childCasePath,
          reducer: ChildReducer()
        )
      }
      .reduce(into: &state, action: action)
    }
  }

  struct ReleaseIfCaseLetFeature: Reducer {
    struct ChildState: Equatable, Sendable {
      var count = 0
    }

    enum State: Equatable, Sendable {
      case idle
      case child(ChildState)
    }

    enum Action: Equatable, Sendable {
      case child(ChildAction)

      static let childCasePath = CasePath<Self, ChildAction>(
        embed: Action.child,
        extract: { action in
          guard case .child(let childAction) = action else { return nil }
          return childAction
        }
      )
    }

    enum ChildAction: Equatable, Sendable {
      case increment
    }

    static let childStateCasePath = CasePath<State, ChildState>(
      embed: State.child,
      extract: { state in
        guard case .child(let childState) = state else { return nil }
        return childState
      }
    )

    struct ChildReducer: Reducer {
      func reduce(into state: inout ChildState, action: ChildAction) -> EffectTask<ChildAction> {
        switch action {
        case .increment:
          state.count += 1
          return .none
        }
      }
    }

    func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
      CombineReducers<State, Action> {
        Reduce { _, _ in .none }
        IfCaseLet(
          state: Self.childStateCasePath,
          action: Action.childCasePath,
          reducer: ChildReducer()
        )
      }
      .reduce(into: &state, action: action)
    }
  }

  @main
  struct ConditionalReducerProbe {
    @MainActor
    static func main() {
      switch ProcessInfo.processInfo.environment["INNOFLOW_CONDITIONAL_REDUCER_SCENARIO"] {
      case "iflet-absent-state":
        let store = Store(
          reducer: ReleaseIfLetFeature(),
          initialState: .init(child: nil, untouched: 7)
        )
        store.send(.child(.increment))
        guard store.state == .init(child: nil, untouched: 7) else {
          fputs("IfLet mutated state unexpectedly\n", stderr)
          Foundation.exit(1)
        }
        print("ok")

      case "ifcase-mismatched-state":
        let store = Store(
          reducer: ReleaseIfCaseLetFeature(),
          initialState: .idle
        )
        store.send(.child(.increment))
        guard store.state == .idle else {
          fputs("IfCaseLet mutated state unexpectedly\n", stderr)
          Foundation.exit(1)
        }
        print("ok")

      default:
        fputs("Unknown conditional reducer scenario\n", stderr)
        Foundation.exit(2)
      }
    }
  }
  """#

private let staleScopedStoreHarnessSource = #"""
  import Foundation

  struct ParentReleasedFeature: Reducer {
    struct Child: Equatable, Sendable {
      var value = 1
    }

    struct State: Equatable, Sendable {
      var child = Child()
    }

    enum Action: Equatable, Sendable {
      case child(ChildAction)

      static let childCasePath = CasePath<Self, ChildAction>(
        embed: Action.child,
        extract: { action in
          guard case .child(let childAction) = action else { return nil }
          return childAction
        }
      )
    }

    enum ChildAction: Equatable, Sendable {
      case noop
    }

    func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
      .none
    }
  }

  struct CollectionRemovedFeature: Reducer {
    struct Todo: Identifiable, Equatable, Sendable {
      let id: UUID
      var title: String
    }

    struct State: Equatable, Sendable {
      var todos: [Todo] = [
        Todo(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, title: "One")
      ]
      var routedActions: [String] = []
    }

    enum Action: Equatable, Sendable {
      case todo(id: UUID, action: TodoAction)
      case remove(id: UUID)

      static let todoActionPath = CollectionActionPath<Self, UUID, TodoAction>(
        embed: Action.todo(id:action:),
        extract: { action in
          guard case let .todo(id, childAction) = action else { return nil }
          return (id, childAction)
        }
      )
    }

    enum TodoAction: Equatable, Sendable {
      case rename(String)
    }

    func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
      switch action {
      case .todo(let id, .rename(let title)):
        state.routedActions.append("todo:\(id)")
        guard let index = state.todos.firstIndex(where: { $0.id == id }) else {
          return .none
        }
        state.todos[index].title = title
        return .none

      case .remove(let id):
        state.todos.removeAll { $0.id == id }
        return .none
      }
    }
  }

  @main
  struct StaleScopeProbe {
    @MainActor
    static func main() {
      switch ProcessInfo.processInfo.environment["INNOFLOW_STALE_SCOPE_SCENARIO"] {
      case "parent-released":
        let scoped:
          ScopedStore<ParentReleasedFeature, ParentReleasedFeature.Child, ParentReleasedFeature.ChildAction> =
            {
              let store = Store(reducer: ParentReleasedFeature(), initialState: .init())
              return store.scope(state: \.child, action: ParentReleasedFeature.Action.childCasePath)
            }()
        _ = scoped.state.value

      case "collection-entry-removed":
        let store = Store(reducer: CollectionRemovedFeature(), initialState: .init())
        let targetID = store.state.todos[0].id
        let row = store.scope(
          collection: \.todos,
          action: CollectionRemovedFeature.Action.todoActionPath
        )[0]
        store.send(.remove(id: targetID))
        row.send(.rename("Updated"))

      case "selected-parent-released":
        let selected: SelectedStore<Int> = {
          let store = Store(reducer: ParentReleasedFeature(), initialState: .init())
          return store.select(\.child.value)
        }()
        _ = selected.value

      default:
        fatalError("Unknown stale scope scenario")
      }
    }
  }
  """#

private let phaseMapCrashHarnessSource = #"""
  import Foundation

  struct CrashPhaseMutationFeature: Reducer {
    struct State: Equatable, Sendable {
      enum Phase: Hashable, Sendable {
        case idle
        case loading
        case loaded
      }

      var phase: Phase = .idle
      var values: [Int] = []
    }

    enum Action: Equatable, Sendable {
      case load
      case loaded([Int])
    }

    static let loadedCasePath = CasePath<Action, [Int]>(
      embed: Action.loaded,
      extract: { action in
        guard case .loaded(let payload) = action else { return nil }
        return payload
      }
    )

    static let phaseMap = PhaseMap(\State.phase) {
      From(.idle) {
        On(Action.load, to: .loading)
      }
      From(.loading) {
        On(Self.loadedCasePath, to: .loaded)
      }
    }

    func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
      let map: PhaseMap<State, Action, State.Phase> = Self.phaseMap

      return Reduce<State, Action> { state, action in
        switch action {
        case .load:
          state.phase = .loaded
          return .none
        case .loaded(let values):
          state.values = values
          return .none
        }
      }
      .phaseMap(map)
      .reduce(into: &state, action: action)
    }
  }

  struct CrashInvalidTargetFeature: Reducer {
    struct State: Equatable, Sendable {
      enum Phase: Hashable, Sendable {
        case failed
        case idle
        case loaded
        case unexpected
      }

      var phase: Phase = .failed
      var log: [String] = []
    }

    enum Action: Equatable, Sendable {
      case attemptRecover(Bool)
    }

    static let attemptRecoverCasePath = CasePath<Action, Bool>(
      embed: Action.attemptRecover,
      extract: { action in
        guard case .attemptRecover(let payload) = action else { return nil }
        return payload
      }
    )

    static let phaseMap = PhaseMap(\State.phase) {
      From(.failed) {
        On(Self.attemptRecoverCasePath, targets: [.idle, .loaded]) { _, shouldRecover in
          shouldRecover ? .unexpected : nil
        }
      }
    }

    func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
      let map: PhaseMap<State, Action, State.Phase> = Self.phaseMap

      return Reduce<State, Action> { state, action in
        switch action {
        case .attemptRecover(let shouldRecover):
          state.log.append(shouldRecover ? "recover" : "skip")
          return .none
        }
      }
      .phaseMap(map)
      .reduce(into: &state, action: action)
    }
  }

  @main
  struct PhaseMapCrashProbe {
    @MainActor
    static func main() {
      switch ProcessInfo.processInfo.environment["INNOFLOW_PHASEMAP_CRASH_SCENARIO"] {
      case "direct-mutation-crash":
        let store = Store(reducer: CrashPhaseMutationFeature(), initialState: .init())
        store.send(.load)

      case "undeclared-target-crash":
        let store = Store(reducer: CrashInvalidTargetFeature(), initialState: .init())
        store.send(.attemptRecover(true))

      default:
        fputs("Unknown PhaseMap crash scenario\n", stderr)
        Foundation.exit(2)
      }
    }
  }
  """#

private let phaseMapReleaseHarnessSource = #"""
  import Foundation

  struct ReleasePhaseMutationFeature: Reducer {
    struct State: Equatable, Sendable {
      enum Phase: Hashable, Sendable {
        case idle
        case loading
        case loaded
      }

      var phase: Phase = .idle
      var values: [Int] = []
    }

    enum Action: Equatable, Sendable {
      case load
      case loaded([Int])
    }

    static let loadedCasePath = CasePath<Action, [Int]>(
      embed: Action.loaded,
      extract: { action in
        guard case .loaded(let payload) = action else { return nil }
        return payload
      }
    )

    static let phaseMap = PhaseMap(\State.phase) {
      From(.idle) {
        On(Action.load, to: .loading)
      }
      From(.loading) {
        On(Self.loadedCasePath, to: .loaded)
      }
    }

    func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
      let map: PhaseMap<State, Action, State.Phase> = Self.phaseMap

      return Reduce<State, Action> { state, action in
        switch action {
        case .load:
          state.phase = .loaded
          return .none
        case .loaded(let values):
          state.phase = .idle
          state.values = values
          return .none
        }
      }
      .phaseMap(map)
      .reduce(into: &state, action: action)
    }
  }

  struct ReleaseInvalidTargetFeature: Reducer {
    struct State: Equatable, Sendable {
      enum Phase: Hashable, Sendable {
        case failed
        case idle
        case loaded
        case unexpected
      }

      var phase: Phase = .failed
      var log: [String] = []
    }

    enum Action: Equatable, Sendable {
      case attemptRecover(Bool)
    }

    static let attemptRecoverCasePath = CasePath<Action, Bool>(
      embed: Action.attemptRecover,
      extract: { action in
        guard case .attemptRecover(let payload) = action else { return nil }
        return payload
      }
    )

    static let phaseMap = PhaseMap(\State.phase) {
      From(.failed) {
        On(Self.attemptRecoverCasePath, targets: [.idle, .loaded]) { _, shouldRecover in
          shouldRecover ? .unexpected : nil
        }
      }
    }

    func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
      let map: PhaseMap<State, Action, State.Phase> = Self.phaseMap

      return Reduce<State, Action> { state, action in
        switch action {
        case .attemptRecover(let shouldRecover):
          state.log.append(shouldRecover ? "recover" : "skip")
          return .none
        }
      }
      .phaseMap(map)
      .reduce(into: &state, action: action)
    }
  }

  @main
  struct PhaseMapReleaseProbe {
    @MainActor
    static func main() {
      switch ProcessInfo.processInfo.environment["INNOFLOW_PHASEMAP_RELEASE_SCENARIO"] {
      case "direct-mutation-restore":
        let store = Store(reducer: ReleasePhaseMutationFeature(), initialState: .init())
        store.send(.load)
        guard store.state.phase == .loading else {
          fputs("Expected load to restore the previous phase and apply the declared loading transition\n", stderr)
          Foundation.exit(1)
        }

        store.send(.loaded([1, 2, 3]))
        guard store.state.phase == .loaded, store.state.values == [1, 2, 3] else {
          fputs("Expected loaded payload to preserve reducer work and then transition to .loaded\n", stderr)
          Foundation.exit(1)
        }
        print("ok")

      case "undeclared-target-noop":
        let store = Store(reducer: ReleaseInvalidTargetFeature(), initialState: .init())
        store.send(.attemptRecover(true))
        guard store.state.phase == .failed, store.state.log == ["recover"] else {
          fputs("Expected undeclared dynamic target to keep the previous phase while preserving reducer work\n", stderr)
          Foundation.exit(1)
        }

        store.send(.attemptRecover(false))
        guard store.state.phase == .failed, store.state.log == ["recover", "skip"] else {
          fputs("Expected nil guard result to keep the previous phase and append reducer work\n", stderr)
          Foundation.exit(1)
        }
        print("ok")

      default:
        fputs("Unknown PhaseMap release scenario\n", stderr)
        Foundation.exit(2)
      }
    }
  }
  """#

private let staleScopedStoreReleaseHarnessSource = #"""
  import Foundation

  struct ReleaseParentReleasedFeature: Reducer {
    struct Child: Equatable, Sendable {
      var value = 42
    }

    struct State: Equatable, Sendable {
      var child = Child()
    }

    enum Action: Equatable, Sendable {
      case child(ChildAction)

      static let childCasePath = CasePath<Self, ChildAction>(
        embed: Action.child,
        extract: { action in
          guard case .child(let childAction) = action else { return nil }
          return childAction
        }
      )
    }

    enum ChildAction: Equatable, Sendable {
      case noop
    }

    func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
      .none
    }
  }

  struct ReleaseCollectionRemovedFeature: Reducer {
    struct Todo: Identifiable, Equatable, Sendable {
      let id: UUID
      var title: String
    }

    struct State: Equatable, Sendable {
      var todos: [Todo] = [
        Todo(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, title: "One")
      ]
      var routedActions: [String] = []
    }

    enum Action: Equatable, Sendable {
      case todo(id: UUID, action: TodoAction)
      case remove(id: UUID)

      static let todoActionPath = CollectionActionPath<Self, UUID, TodoAction>(
        embed: Action.todo(id:action:),
        extract: { action in
          guard case let .todo(id, childAction) = action else { return nil }
          return (id, childAction)
        }
      )
    }

    enum TodoAction: Equatable, Sendable {
      case rename(String)
    }

    func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
      switch action {
      case .todo(let id, .rename(let title)):
        state.routedActions.append("todo:\(id)")
        guard let index = state.todos.firstIndex(where: { $0.id == id }) else {
          return .none
        }
        state.todos[index].title = title
        return .none

      case .remove(let id):
        state.todos.removeAll { $0.id == id }
        return .none
      }
    }
  }

  @main
  struct StaleScopeReleaseProbe {
    @MainActor
    static func main() {
      switch ProcessInfo.processInfo.environment["INNOFLOW_STALE_SCOPE_RELEASE_SCENARIO"] {
      case "parent-released":
        let scoped:
          ScopedStore<
            ReleaseParentReleasedFeature,
            ReleaseParentReleasedFeature.Child,
            ReleaseParentReleasedFeature.ChildAction
          > = {
            let store = Store(
              reducer: ReleaseParentReleasedFeature(), initialState: .init())
            return store.scope(
              state: \.child,
              action: ReleaseParentReleasedFeature.Action.childCasePath
            )
          }()
        // Parent store is now released. Release builds must return the
        // cached child state instead of aborting the process.
        let cached = scoped.state
        guard cached.value == 42 else {
          fputs("Expected cached ScopedStore value 42, got \(cached.value)\n", stderr)
          Foundation.exit(1)
        }
        // Sending after parent release must be a silent no-op.
        scoped.send(.noop)
        print("ok")

      case "collection-entry-removed":
        let store = Store(
          reducer: ReleaseCollectionRemovedFeature(), initialState: .init())
        let targetID = store.state.todos[0].id
        let row = store.scope(
          collection: \.todos,
          action: ReleaseCollectionRemovedFeature.Action.todoActionPath
        )[0]
        store.send(.remove(id: targetID))
        // Both read and write after the entry is removed must tolerate the
        // lifecycle race without aborting.
        row.send(.rename("Updated"))
        let cached = row.state
        guard cached.id == targetID, cached.title == "One" else {
          fputs("Expected cached removed row state, got \(cached)\n", stderr)
          Foundation.exit(1)
        }
        guard store.state.todos.isEmpty, store.state.routedActions.isEmpty else {
          fputs("Expected stale row send to be a no-op, got \(store.state)\n", stderr)
          Foundation.exit(1)
        }
        print("ok")

      case "selected-parent-released":
        let selected: SelectedStore<Int> = {
          let store = Store(
            reducer: ReleaseParentReleasedFeature(), initialState: .init())
          return store.select(\.child.value)
        }()
        // Release builds must return the cached projected value instead of
        // aborting.
        let cachedValue = selected.value
        guard cachedValue == 42 else {
          fputs(
            "Expected cached SelectedStore value 42, got \(cachedValue)\n", stderr)
          Foundation.exit(1)
        }
        print("ok")

      default:
        fputs("Unknown stale scope release scenario\n", stderr)
        Foundation.exit(2)
      }
    }
  }
  """#
