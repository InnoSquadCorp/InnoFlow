#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "release-evidence-output-parser"

def assert_result(name, output, accepted:, check: {})
  result = ReleaseEvidenceOutputParser.parse({ "id" => name }.merge(check), output)
  actual = result.fetch("failures").empty?
  return if actual == accepted
  abort "#{name}: expected accepted=#{accepted}, got #{actual}: #{result.fetch("failures").join(", ")}"
end

normal = <<~OUTPUT
  Test run started.
  Suite "FlowTask dispatch lifetime" started.
  Test "normal completion" started.
  Test "normal completion" passed after 0.001 seconds.
  Suite "FlowTask dispatch lifetime" passed after 0.051 seconds.
  Test run with 1 test in 1 suite passed after 0.051 seconds.
OUTPUT
assert_result(
  "normal",
  normal,
  accepted: true,
  check: { "expectedResultSuites" => ["FlowTask dispatch lifetime"], "expectedTestNames" => ["normal completion"] }
)

parameterized = <<~OUTPUT
  Test run started.
  Suite "FlowTask reduction cancellation boundary" started.
  Test "cancellation between emission and reduction drops queued descendants" started.
  Test case passing 1 argument seed → 0 to "cancellation between emission and reduction drops queued descendants" started.
  Test case passing 1 argument seed → 1 to "cancellation between emission and reduction drops queued descendants" started.
  Test "cancellation during state observation suppresses output without rolling back state" started.
  Test "cancellation between emission and reduction drops queued descendants" with 2 test cases passed after 0.002 seconds.
  Test "cancellation during state observation suppresses output without rolling back state" passed after 0.001 seconds.
  Suite "FlowTask reduction cancellation boundary" passed after 0.002 seconds.
  Test run with 2 tests in 1 suite passed after 0.002 seconds.
OUTPUT
assert_result("parameterized", parameterized, accepted: true)

quoted_name = <<~OUTPUT
  Test run started.
  Suite "Quoted displays" started.
  Test "a \"quoted\" 이름 at C:\\tmp containing skipped and unexpected signal 9" started.
  Test "a \"quoted\" 이름 at C:\\tmp containing skipped and unexpected signal 9" passed after 0.001 seconds.
  Suite "Quoted displays" passed after 0.001 seconds.
  Test run with 1 test in 1 suite passed after 0.001 seconds.
OUTPUT
assert_result("quoted signal words in display name", quoted_name, accepted: true)

unquoted = <<~OUTPUT
  Test run started.
  Suite PerfReducerComposition started.
  Test _perf_constructOnly_N2() started.
  Test _perf_constructOnly_N2() passed after 0.001 seconds.
  Suite PerfReducerComposition passed after 0.001 seconds.
  Test run with 1 test in 1 suite passed after 0.001 seconds.
OUTPUT
assert_result("unquoted", unquoted, accepted: true)

actual_skip = normal.sub(
  'Test "normal completion" passed after 0.001 seconds.',
  'Test "normal completion" skipped: "test probe"'
)
assert_result("actual skip with colon", actual_skip, accepted: false)

actual_failure = normal.sub(
  'Test "normal completion" passed after 0.001 seconds.',
  'Test "normal completion" failed after 0.001 seconds.'
)
assert_result("actual failure", actual_failure, accepted: false)

signal_diagnostic = normal.sub(
  'Test run with 1 test in 1 suite passed after 0.051 seconds.',
  "error: Exited with unexpected signal code 6\nTest run with 1 test in 1 suite passed after 0.051 seconds."
)
assert_result("actual signal diagnostic", signal_diagnostic, accepted: false)

missing_terminal = normal.lines.reject { |line| line.include?('Test "normal completion" passed') }.join
assert_result("started test without terminal", missing_terminal, accepted: false)

missing_start = normal.lines.reject { |line| line.include?('Test "normal completion" started') }.join
assert_result("terminal test without start", missing_start, accepted: false)

missing_suite_terminal = normal.lines.reject { |line| line.include?('Suite "FlowTask dispatch lifetime" passed') }.join
assert_result("started suite without terminal", missing_suite_terminal, accepted: false)

missing_run_start = normal.lines.drop(1).join
assert_result("summary without run start", missing_run_start, accepted: false)

missing_summary = normal.lines.reject { |line| line.include?("Test run with") }.join
assert_result("run without summary", missing_summary, accepted: false)

summary_mismatch = normal.sub("Test run with 1 test", "Test run with 2 tests")
assert_result("summary count mismatch", summary_mismatch, accepted: false)

unknown_terminal = normal.sub(
  'Test "normal completion" passed after 0.001 seconds.',
  'Test "normal completion" passed eventually'
)
assert_result("unknown terminal format", unknown_terminal, accepted: false)

assert_result(
  "missing required test",
  normal,
  accepted: false,
  check: { "expectedTestNames" => ["required consumer contract"] }
)

second_bundle = <<~OUTPUT
  Test run started.
  Suite "Macro Tests" started.
  Test "macro expansion" started.
  Test "macro expansion" passed after 0.010 seconds.
  Suite "Macro Tests" passed after 0.010 seconds.
  Test run with 1 test in 1 suite passed after 0.010 seconds.
OUTPUT
assert_result(
  "multiple bundles",
  normal + second_bundle,
  accepted: true,
  check: { "minimumTestCount" => 2, "maximumTestCount" => 2, "expectedTestRunCount" => 2 }
)

duplicate_terminal = normal.sub(
  'Suite "FlowTask dispatch lifetime" passed after 0.051 seconds.',
  "Test \"normal completion\" passed after 0.001 seconds.\nSuite \"FlowTask dispatch lifetime\" passed after 0.051 seconds."
)
assert_result("duplicate terminal", duplicate_terminal, accepted: false)

terminal_before_start = <<~OUTPUT
  Test run started.
  Suite "FlowTask dispatch lifetime" started.
  Test "normal completion" passed after 0.001 seconds.
  Test "normal completion" started.
  Suite "FlowTask dispatch lifetime" passed after 0.051 seconds.
  Test run with 1 test in 1 suite passed after 0.051 seconds.
OUTPUT
assert_result("terminal before start with balanced totals", terminal_before_start, accepted: false)

duplicate_complete_lifecycle = <<~OUTPUT
  Test run started.
  Suite "Same suite" started.
  Test "repeated" started.
  Test "repeated" passed after 0.001 seconds.
  Test "repeated" started.
  Test "repeated" passed after 0.001 seconds.
  Suite "Same suite" passed after 0.001 seconds.
  Test run with 2 tests in 1 suite passed after 0.001 seconds.
OUTPUT
assert_result("repeated lifecycle in one suite", duplicate_complete_lifecycle, accepted: false)

same_display_different_suites = <<~OUTPUT
  Test run started.
  Suite "First suite" started.
  Test "same display" started.
  Test "same display" passed after 0.001 seconds.
  Suite "First suite" passed after 0.001 seconds.
  Suite "Second suite" started.
  Test "same display" started.
  Test "same display" passed after 0.001 seconds.
  Suite "Second suite" passed after 0.001 seconds.
  Test run with 2 tests in 2 suites passed after 0.001 seconds.
OUTPUT
assert_result("same display in different suites", same_display_different_suites, accepted: true)

suite_terminal_before_start = <<~OUTPUT
  Test run started.
  Suite "FlowTask dispatch lifetime" passed after 0.051 seconds.
  Suite "FlowTask dispatch lifetime" started.
  Test "normal completion" started.
  Test "normal completion" passed after 0.001 seconds.
  Test run with 1 test in 1 suite passed after 0.051 seconds.
OUTPUT
assert_result("suite terminal before start with balanced totals", suite_terminal_before_start, accepted: false)

xctest_noise = <<~OUTPUT
  Test Suite 'All tests' started at 2026-09-18 00:00:00.000.
  Test Case '-[LegacyTests testExample]' started.
  Test Case '-[LegacyTests testExample]' passed (0.001 seconds).
  Test Suite 'All tests' passed at 2026-09-18 00:00:00.001.
OUTPUT
assert_result("XCTest noise around Swift Testing", xctest_noise + normal, accepted: true)

puts "[release-evidence-output-parser-selftest] All checks passed"
