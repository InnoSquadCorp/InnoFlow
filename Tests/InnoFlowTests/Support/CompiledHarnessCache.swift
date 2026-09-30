// MARK: - CompiledHarnessCache.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
import Synchronization

/// Reuses compilation within one test process, never across test invocations.
/// Every scenario must still launch the returned executable in a new process.
final class CompiledHarnessCache: Sendable {
  struct InputSource: Hashable, Sendable {
    let path: String
    let contents: Data
  }

  struct Key: Hashable, Sendable {
    let name: String
    let source: String
    let compilerArguments: [String]
    let inputSources: [InputSource]
    let toolchainEnvironment: [String]
  }

  enum CacheError: Error {
    case missingExecutable(URL)
  }

  private let directory: URL
  // Access to both the dictionary and its files is protected by the mutex. Hold it
  // through compilation so concurrent requests cannot publish partial output
  // or compile the same key twice. Scenario execution happens outside the lock.
  private let executables = Mutex<[Key: URL]>([:])

  init(
    directory: URL = FileManager.default.temporaryDirectory
      .appendingPathComponent("innoflow-compiled-harnesses-\(UUID().uuidString)", isDirectory: true)
  ) {
    self.directory = directory
  }

  deinit {
    try? FileManager.default.removeItem(at: directory)
  }

  func executable(
    for key: Key,
    compile: (_ sourceFile: URL, _ executable: URL) throws -> Void
  ) throws -> URL {
    try executables.withLock { executables in
      if let executable = executables[key],
        FileManager.default.isExecutableFile(atPath: executable.path)
      {
        return executable
      }

      let buildDirectory = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
      try FileManager.default.createDirectory(at: buildDirectory, withIntermediateDirectories: true)
      let sourceFile = buildDirectory.appendingPathComponent("\(key.name).swift")
      let executable = buildDirectory.appendingPathComponent(key.name)
      do {
        try key.source.write(to: sourceFile, atomically: true, encoding: .utf8)
        try compile(sourceFile, executable)
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
          throw CacheError.missingExecutable(executable)
        }
        executables[key] = executable
        return executable
      } catch {
        // Failed compilation must not poison subsequent requests or leave a
        // partially linked executable looking like a reusable success.
        try? FileManager.default.removeItem(at: buildDirectory)
        throw error
      }
    }
  }

  /// Call only when no scenario is running. The shared cache uses this at exit.
  func removeAll() {
    executables.withLock { executables in
      executables.removeAll()
      try? FileManager.default.removeItem(at: directory)
    }
  }
}
