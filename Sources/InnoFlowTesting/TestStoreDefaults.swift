// MARK: - TestStoreDefaults.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation

/// Process-wide defaults for `TestStore` deadlines.
///
/// A deadline is a failure backstop, not a pacing interval: a passing test
/// never waits for it, and raising it only delays the report of a test that
/// was going to fail. On a saturated machine — a parallel test run, a busy CI
/// host — an effect that completes correctly can still miss a one-second
/// deadline, so the default is configurable for the whole process without
/// touching individual tests.
public enum TestStoreDefaults {
  /// Environment variable that overrides ``effectTimeout`` with a positive
  /// number of seconds, for example `INNOFLOW_TESTSTORE_EFFECT_TIMEOUT=10`.
  ///
  /// Whitespace around the value is ignored, and an empty value counts as
  /// unset. A value above one day is clamped to one day. Any other value that
  /// is not a positive number — `0`, `-3`, `10s`, `1,5` — leaves the
  /// one-second default in place. Whenever the value is not used as written,
  /// the process says so once on standard error, naming the variable and the
  /// value, instead of silently running with a different deadline.
  public static let effectTimeoutEnvironmentKey = "INNOFLOW_TESTSTORE_EFFECT_TIMEOUT"

  /// The deadline a `TestStore` applies to `receive`, `finish` and effect
  /// draining when its initializer is not given one: one second, or the value
  /// of ``effectTimeoutEnvironmentKey``. Read once per process.
  public static let effectTimeout: Duration = resolveEffectTimeout(
    environment: ProcessInfo.processInfo.environment
  )

  /// The deadline used when the environment states no usable override.
  static let fallbackEffectTimeout: Duration = .seconds(1)

  /// The largest deadline an override can request: one day.
  ///
  /// A deadline only delays the report of a failing test, so nothing longer
  /// is meaningful, and the bound keeps every later `Duration` computation —
  /// the millisecond conversion here, deadline instants in the store — far
  /// from overflow.
  static let maximumEffectTimeout: Duration = .seconds(86_400)

  /// Resolves the effect deadline and reports an override that is not used as
  /// written on standard error.
  static func resolveEffectTimeout(environment: [String: String]) -> Duration {
    resolveEffectTimeout(environment: environment, diagnose: writeToStandardError)
  }

  /// Resolves the effect deadline, handing `diagnose` one message when the
  /// override is present but not used as written.
  static func resolveEffectTimeout(
    environment: [String: String],
    diagnose: (String) -> Void
  ) -> Duration {
    guard let rawValue = environment[effectTimeoutEnvironmentKey] else {
      return fallbackEffectTimeout
    }
    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.isEmpty == false else {
      return fallbackEffectTimeout
    }
    // `seconds > 0` is false for NaN as well as for zero and negative values.
    guard let seconds = Double(trimmed), seconds > 0 else {
      diagnose(
        """
        InnoFlowTesting: ignoring \(effectTimeoutEnvironmentKey)="\(rawValue)": expected a \
        positive number of seconds such as 10 or 2.5. TestStore keeps its default effect \
        timeout of \(fallbackEffectTimeout).
        """
      )
      return fallbackEffectTimeout
    }
    // Compare before converting: a value such as 1e16, or an overflowed
    // literal that parsed as infinity, cannot be represented in milliseconds.
    guard seconds <= Double(maximumEffectTimeout.components.seconds) else {
      diagnose(
        """
        InnoFlowTesting: \(effectTimeoutEnvironmentKey)="\(rawValue)" exceeds the largest \
        supported effect timeout. TestStore uses \(maximumEffectTimeout) instead.
        """
      )
      return maximumEffectTimeout
    }
    return .milliseconds(Int64((seconds * 1_000).rounded(.up)))
  }

  private static func writeToStandardError(_ message: String) {
    try? FileHandle.standardError.write(contentsOf: Data("\(message)\n".utf8))
  }
}
