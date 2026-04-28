// MARK: - ReducerCompositionPerfTests.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.
//
// Construction-heavy composition benchmark for `CombineReducers` + `ReducerBuilder`.
//
// This file measures:
//   1. Construct-only cost: repeatedly building `CombineReducers { ... }` with
//      N child reducers. Sensitive to intermediate closure allocations inside
//      the builder chain.
//   2. Dispatch cost: sending a single action through an already-constructed
//      composition many times. Sensitive to the per-step merge/closure overhead.
//
// The tests are not pass/fail gates — they print timings so humans can compare
// before/after numbers across refactors. The `_perf` prefix is only a naming
// convention; benchmarks run only when `INNOFLOW_PERF_BENCHMARKS=1` is set.

import Foundation
import Testing

@testable import InnoFlow

private var isReducerCompositionPerfBenchmarkEnabled: Bool {
  ProcessInfo.processInfo.environment["INNOFLOW_PERF_BENCHMARKS"] == "1"
}

private var reducerCompositionPerfOutputPath: String? {
  let value = ProcessInfo.processInfo.environment["INNOFLOW_REDUCER_PERF_OUTPUT"]?
    .trimmingCharacters(in: .whitespacesAndNewlines)
  guard let value, !value.isEmpty else { return nil }
  return value
}

// MARK: - Fixture

private struct PerfBenchState: Equatable, Sendable, DefaultInitializable {
  var tick: Int = 0
}

private enum PerfBenchAction: Equatable, Sendable {
  case bump
}

private struct PerfBenchAppender: Reducer {
  typealias State = PerfBenchState
  typealias Action = PerfBenchAction

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    state.tick &+= 1
    return .none
  }
}

private struct PerfBenchConstructNode: Reducer {
  typealias State = PerfBenchState
  typealias Action = PerfBenchAction

  let seed: UInt64

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    state.tick &+= Int(truncatingIfNeeded: seed & 1)
    return .none
  }
}

private nonisolated(unsafe) var reducerConstructionBenchmarkSink: UInt64 = 0
private nonisolated(unsafe) var reducerConstructionSeed: UInt64 = 0xCBF2_9CE4_8422_2325

// MARK: - Measurement helpers

private struct PerfResult: Sendable {
  let label: String
  let iterations: Int
  let total: Duration
  var perIteration: Duration { total / iterations }

  var totalNanos: UInt64 {
    max(1, durationToNanoseconds(total))
  }

  var perIterationNanos: UInt64 {
    let total = totalNanos
    guard total > 0 else { return 0 }
    let divisor = UInt64(iterations)
    // Round up so tiny construction benchmarks do not collapse to zero in the
    // machine-readable JSONL fixture. The console formatter still reports the
    // higher-resolution `Duration`, but the persisted baseline needs a stable
    // non-zero integer for local comparisons.
    return (total + divisor - 1) / divisor
  }

  func formatted() -> String {
    let totalMs =
      Double(total.components.seconds) * 1_000
      + Double(total.components.attoseconds) / 1e15
    let perUs = totalMs * 1_000 / Double(iterations)
    let paddedLabel = label.padding(toLength: 48, withPad: " ", startingAt: 0)
    let totalMsStr = String(format: "%8.2f", totalMs)
    let perUsStr = String(format: "%8.3f", perUs)
    return "[perf] \(paddedLabel)  iters=\(iterations)  total=\(totalMsStr) ms  per=\(perUsStr) µs"
  }
}

private struct PerfRecord: Codable, Sendable {
  let label: String
  let iterations: Int
  let totalNanos: UInt64
  let perIterationNanos: UInt64
}

private actor ReducerCompositionPerfOutputWriter {
  static let shared = ReducerCompositionPerfOutputWriter()

  private var preparedPaths: Set<String> = []

  func write(
    _ result: PerfResult,
    to outputPath: String,
    file: StaticString = #filePath
  ) throws {
    let url = try repositoryRelativeOrAbsoluteFileURL(path: outputPath, file: file)

    if !preparedPaths.contains(url.path) {
      preparedPaths.insert(url.path)
      try? FileManager.default.removeItem(at: url)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true,
        attributes: nil
      )
    }

    let record = PerfRecord(
      label: result.label,
      iterations: result.iterations,
      totalNanos: result.totalNanos,
      perIterationNanos: result.perIterationNanos
    )
    let data = try JSONEncoder().encode(record)

    if FileManager.default.fileExists(atPath: url.path) {
      let handle = try FileHandle(forWritingTo: url)
      defer { try? handle.close() }
      try handle.seekToEnd()
      try handle.write(contentsOf: data)
      try handle.write(contentsOf: Data([0x0A]))
    } else {
      var payload = Data()
      payload.append(data)
      payload.append(0x0A)
      try payload.write(to: url, options: .atomic)
    }
  }
}

private func measureBlock(
  label: String, iterations: Int, samples: Int = 5, _ body: () -> Void
) -> PerfResult {
  // Warm-up to ensure JIT/codegen paths are primed.
  for _ in 0..<max(1, iterations / 10) { body() }

  let clock = ContinuousClock()
  var bestDuration: Duration?
  var bestNanos: UInt64?

  for _ in 0..<samples {
    let start = clock.now
    for _ in 0..<iterations { body() }
    let end = clock.now
    let duration = start.duration(to: end)
    let nanos = durationToNanoseconds(duration)

    if let currentBest = bestNanos, currentBest <= nanos {
      continue
    }

    bestNanos = nanos
    bestDuration = duration
  }

  return PerfResult(label: label, iterations: iterations, total: bestDuration ?? .zero)
}

private func emitPerfResult(_ result: PerfResult) async throws {
  print(result.formatted())

  guard let outputPath = reducerCompositionPerfOutputPath else { return }
  try await ReducerCompositionPerfOutputWriter.shared.write(result, to: outputPath)
}

private func durationToNanoseconds(_ duration: Duration) -> UInt64 {
  let seconds = UInt64(duration.components.seconds)
  let attoseconds = UInt64(duration.components.attoseconds)
  return seconds * 1_000_000_000 + attoseconds / 1_000_000_000
}

private func repositoryRelativeOrAbsoluteFileURL(
  path: String,
  file: StaticString = #filePath
) throws -> URL {
  if path.hasPrefix("/") {
    return URL(fileURLWithPath: path)
  }

  var directory = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
  for _ in 0..<10 {
    let candidate = directory.appendingPathComponent("Package.swift")
    if FileManager.default.fileExists(atPath: candidate.path) {
      return directory.appendingPathComponent(path)
    }
    directory.deleteLastPathComponent()
  }

  struct RepositoryRootNotFound: Error {}
  throw RepositoryRootNotFound()
}

@inline(never)
@_optimize(none)
private func nextConstructionSeed() -> UInt64 {
  reducerConstructionSeed = reducerConstructionSeed &* 2_862_933_555_777_941_757 &+ 3_037_000_493
  return reducerConstructionSeed
}

@inline(never)
@_optimize(none)
private func seededConstructNode(baseSeed: UInt64, offset: UInt64) -> PerfBenchConstructNode {
  PerfBenchConstructNode(seed: baseSeed &+ (offset &* 0x9E37_79B9_7F4A_7C15))
}

@inline(never)
@_optimize(none)
private func consumeConstructedReducer<T>(_ value: T) {
  var copy = value
  withUnsafeBytes(of: &copy) { rawBuffer in
    var checksum: UInt64 = 0xCBF2_9CE4_8422_2325
    for byte in rawBuffer {
      checksum ^= UInt64(byte)
      checksum &*= 1_099_511_628_211
    }
    reducerConstructionBenchmarkSink ^= checksum
  }
}

// MARK: - Construction benchmarks

// Explicit unrolled `CombineReducers { ... }` blocks. We do NOT use helper
// factories that return `some Reducer` because that would partially hide the
// construction cost we want to measure.

@Suite(.serialized)
struct PerfReducerComposition {

  @Test func _perf_constructOnly_N2() async throws {
    guard isReducerCompositionPerfBenchmarkEnabled else { return }

    let result = measureBlock(label: "construct-only N=2", iterations: 5_000) {
      let seed = nextConstructionSeed()
      let reducer = CombineReducers<PerfBenchState, PerfBenchAction> {
        seededConstructNode(baseSeed: seed, offset: 1)
        seededConstructNode(baseSeed: seed, offset: 2)
      }
      consumeConstructedReducer(reducer)
    }
    try await emitPerfResult(result)
  }

  @Test func _perf_constructOnly_N8() async throws {
    guard isReducerCompositionPerfBenchmarkEnabled else { return }

    let result = measureBlock(label: "construct-only N=8", iterations: 5_000) {
      let seed = nextConstructionSeed()
      let reducer = CombineReducers<PerfBenchState, PerfBenchAction> {
        seededConstructNode(baseSeed: seed, offset: 1)
        seededConstructNode(baseSeed: seed, offset: 2)
        seededConstructNode(baseSeed: seed, offset: 3)
        seededConstructNode(baseSeed: seed, offset: 4)
        seededConstructNode(baseSeed: seed, offset: 5)
        seededConstructNode(baseSeed: seed, offset: 6)
        seededConstructNode(baseSeed: seed, offset: 7)
        seededConstructNode(baseSeed: seed, offset: 8)
      }
      consumeConstructedReducer(reducer)
    }
    try await emitPerfResult(result)
  }

  @Test func _perf_constructOnly_N32() async throws {
    guard isReducerCompositionPerfBenchmarkEnabled else { return }

    let result = measureBlock(label: "construct-only N=32", iterations: 2_000) {
      let seed = nextConstructionSeed()
      let reducer = CombineReducers<PerfBenchState, PerfBenchAction> {
        seededConstructNode(baseSeed: seed, offset: 1)
        seededConstructNode(baseSeed: seed, offset: 2)
        seededConstructNode(baseSeed: seed, offset: 3)
        seededConstructNode(baseSeed: seed, offset: 4)
        seededConstructNode(baseSeed: seed, offset: 5)
        seededConstructNode(baseSeed: seed, offset: 6)
        seededConstructNode(baseSeed: seed, offset: 7)
        seededConstructNode(baseSeed: seed, offset: 8)
        seededConstructNode(baseSeed: seed, offset: 9)
        seededConstructNode(baseSeed: seed, offset: 10)
        seededConstructNode(baseSeed: seed, offset: 11)
        seededConstructNode(baseSeed: seed, offset: 12)
        seededConstructNode(baseSeed: seed, offset: 13)
        seededConstructNode(baseSeed: seed, offset: 14)
        seededConstructNode(baseSeed: seed, offset: 15)
        seededConstructNode(baseSeed: seed, offset: 16)
        seededConstructNode(baseSeed: seed, offset: 17)
        seededConstructNode(baseSeed: seed, offset: 18)
        seededConstructNode(baseSeed: seed, offset: 19)
        seededConstructNode(baseSeed: seed, offset: 20)
        seededConstructNode(baseSeed: seed, offset: 21)
        seededConstructNode(baseSeed: seed, offset: 22)
        seededConstructNode(baseSeed: seed, offset: 23)
        seededConstructNode(baseSeed: seed, offset: 24)
        seededConstructNode(baseSeed: seed, offset: 25)
        seededConstructNode(baseSeed: seed, offset: 26)
        seededConstructNode(baseSeed: seed, offset: 27)
        seededConstructNode(baseSeed: seed, offset: 28)
        seededConstructNode(baseSeed: seed, offset: 29)
        seededConstructNode(baseSeed: seed, offset: 30)
        seededConstructNode(baseSeed: seed, offset: 31)
        seededConstructNode(baseSeed: seed, offset: 32)
      }
      consumeConstructedReducer(reducer)
    }
    try await emitPerfResult(result)
  }

  // MARK: - Dispatch benchmarks

  @Test func _perf_dispatch_N8_10k() async throws {
    guard isReducerCompositionPerfBenchmarkEnabled else { return }

    let reducer = CombineReducers<PerfBenchState, PerfBenchAction> {
      PerfBenchAppender()
      PerfBenchAppender()
      PerfBenchAppender()
      PerfBenchAppender()
      PerfBenchAppender()
      PerfBenchAppender()
      PerfBenchAppender()
      PerfBenchAppender()
    }
    var state = PerfBenchState()

    let result = measureBlock(label: "dispatch N=8 × 10k", iterations: 10_000) {
      _ = reducer.reduce(into: &state, action: .bump)
    }
    try await emitPerfResult(result)
    #expect(state.tick > 0)
  }

  @Test func _perf_dispatch_N32_10k() async throws {
    guard isReducerCompositionPerfBenchmarkEnabled else { return }

    let reducer = CombineReducers<PerfBenchState, PerfBenchAction> {
      PerfBenchAppender()
      PerfBenchAppender()
      PerfBenchAppender()
      PerfBenchAppender()
      PerfBenchAppender()
      PerfBenchAppender()
      PerfBenchAppender()
      PerfBenchAppender()
      PerfBenchAppender()
      PerfBenchAppender()
      PerfBenchAppender()
      PerfBenchAppender()
      PerfBenchAppender()
      PerfBenchAppender()
      PerfBenchAppender()
      PerfBenchAppender()
      PerfBenchAppender()
      PerfBenchAppender()
      PerfBenchAppender()
      PerfBenchAppender()
      PerfBenchAppender()
      PerfBenchAppender()
      PerfBenchAppender()
      PerfBenchAppender()
      PerfBenchAppender()
      PerfBenchAppender()
      PerfBenchAppender()
      PerfBenchAppender()
      PerfBenchAppender()
      PerfBenchAppender()
      PerfBenchAppender()
      PerfBenchAppender()
    }
    var state = PerfBenchState()

    let result = measureBlock(label: "dispatch N=32 × 10k", iterations: 10_000) {
      _ = reducer.reduce(into: &state, action: .bump)
    }
    try await emitPerfResult(result)
    #expect(state.tick > 0)
  }
}
