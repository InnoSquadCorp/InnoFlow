// MARK: - CompiledHarnessCacheTests.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Dispatch
import Foundation
import Synchronization
import Testing

@Suite("Compiled subprocess harness cache")
struct CompiledHarnessCacheTests {
  private func key(
    name: String = "Probe",
    source: String = "probe source",
    arguments: [String] = ["swiftc", "-Onone"],
    inputPath: String = "Core.swift",
    inputContents: String = "core source",
    environment: [String] = ["DEVELOPER_DIR=xcode"]
  ) -> CompiledHarnessCache.Key {
    .init(
      name: name,
      source: source,
      compilerArguments: arguments,
      inputSources: [.init(path: inputPath, contents: Data(inputContents.utf8))],
      toolchainEnvironment: environment
    )
  }

  @Test("Sixteen scenario requests compile only their five distinct variants")
  func reusesFiveVariants() throws {
    let cache = CompiledHarnessCache()
    defer { cache.removeAll() }
    var compilationCount = 0
    let requests = [
      ("StaleDebug", 5), ("StaleRelease", 5), ("ConditionalRelease", 2),
      ("PhaseDebug", 2), ("PhaseRelease", 2),
    ]
    for (name, count) in requests {
      var paths: Set<URL> = []
      for _ in 0..<count {
        let executable = try cache.executable(for: key(name: name)) { source, executable in
          #expect(try String(contentsOf: source, encoding: .utf8) == "probe source")
          compilationCount += 1
          try writeExecutable(at: executable)
        }
        paths.insert(executable)
      }
      #expect(paths.count == 1)
    }
    #expect(compilationCount == 5)
  }

  @Test("Source, optimization, input files and toolchain inputs never alias")
  func separatesCompilerInputs() throws {
    let cache = CompiledHarnessCache()
    defer { cache.removeAll() }
    let variants = [
      key(), key(source: "changed probe"), key(arguments: ["swiftc", "-O"]),
      key(inputPath: "OtherCore.swift"), key(inputContents: "changed core"),
      key(environment: ["DEVELOPER_DIR=other-xcode"]),
    ]
    var paths: Set<URL> = []
    for variant in variants {
      paths.insert(
        try cache.executable(for: variant) { _, executable in
          try writeExecutable(at: executable)
        })
    }
    #expect(paths.count == variants.count)
  }

  @Test("A failed build is removed and the same key can retry successfully")
  func retriesFailure() throws {
    enum Failure: Error { case compilation }
    let cache = CompiledHarnessCache()
    defer { cache.removeAll() }
    var failedDirectory: URL?
    #expect(throws: Failure.self) {
      try cache.executable(for: key()) { source, executable in
        failedDirectory = source.deletingLastPathComponent()
        try writeExecutable(at: executable)
        throw Failure.compilation
      }
    }
    let directory = try #require(failedDirectory)
    #expect(!FileManager.default.fileExists(atPath: directory.path))
    let executable = try cache.executable(for: key()) { _, executable in
      try writeExecutable(at: executable)
    }
    #expect(FileManager.default.isExecutableFile(atPath: executable.path))
  }

  @Test("A missing compiler output is not cached as success")
  func rejectsMissingOutput() throws {
    let cache = CompiledHarnessCache()
    defer { cache.removeAll() }
    #expect(throws: CompiledHarnessCache.CacheError.self) {
      try cache.executable(for: key()) { _, _ in }
    }
    let executable = try cache.executable(for: key()) { _, executable in
      try writeExecutable(at: executable)
    }
    #expect(FileManager.default.isExecutableFile(atPath: executable.path))
  }

  @Test("A deleted executable is rebuilt instead of returning a stale path")
  func rebuildsMissingExecutable() throws {
    let cache = CompiledHarnessCache()
    defer { cache.removeAll() }
    let first = try cache.executable(for: key()) { _, executable in
      try writeExecutable(at: executable)
    }
    try FileManager.default.removeItem(at: first)
    let second = try cache.executable(for: key()) { _, executable in
      try writeExecutable(at: executable)
    }
    #expect(first != second)
    #expect(FileManager.default.isExecutableFile(atPath: second.path))
  }

  @Test("Concurrent requests publish one completed executable")
  func coalescesConcurrentRequests() {
    let cache = CompiledHarnessCache()
    defer { cache.removeAll() }
    let counter = CompilationCounter()
    let input = key()
    DispatchQueue.concurrentPerform(iterations: 16) { _ in
      do {
        let executable = try cache.executable(for: input) { _, executable in
          counter.increment()
          try writeExecutable(at: executable)
        }
        #expect(FileManager.default.isExecutableFile(atPath: executable.path))
      } catch {
        Issue.record(error)
      }
    }
    #expect(counter.value == 1)
  }

  @Test("New cache instances do not inherit previous invocation artifacts")
  func isolatesInstancesAndCleansUp() throws {
    let first = CompiledHarnessCache()
    let second = CompiledHarnessCache()
    defer {
      first.removeAll()
      second.removeAll()
    }
    let firstExecutable = try first.executable(for: key()) { _, executable in
      try writeExecutable(at: executable)
    }
    let secondExecutable = try second.executable(for: key()) { _, executable in
      try writeExecutable(at: executable)
    }
    #expect(firstExecutable != secondExecutable)
    first.removeAll()
    #expect(!FileManager.default.fileExists(atPath: firstExecutable.path))
    #expect(FileManager.default.isExecutableFile(atPath: secondExecutable.path))
  }

  #if os(macOS) || os(Linux)
    @Test("Reusing the executable still runs each scenario in a fresh process")
    func preservesProcessIsolation() throws {
      let cache = CompiledHarnessCache()
      defer { cache.removeAll() }
      let executable = try cache.executable(for: key()) { _, executable in
        try writeExecutable(
          at: executable, source: "#!/bin/sh\nprintf '%s:%s' \"$SCENARIO\" \"$$\"\n")
      }
      var processIDs: Set<String> = []
      for scenario in 0..<16 {
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.environment = ["SCENARIO": String(scenario)]
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        let text = String(
          decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(process.terminationStatus == 0)
        let fields = text.split(separator: ":")
        #expect(fields.first == Substring(String(scenario)))
        processIDs.insert(String(try #require(fields.last)))
      }
      #expect(processIDs.count == 16)
    }
  #endif
}

private func writeExecutable(at url: URL, source: String = "#!/bin/sh\nexit 0\n") throws {
  try source.write(to: url, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
}

private final class CompilationCounter: Sendable {
  private let count = Mutex(0)
  var value: Int { count.withLock { $0 } }
  func increment() { count.withLock { $0 += 1 } }
}
