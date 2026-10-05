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

# Test/case lines copied from Release Preflight run 37314847278, attempt 1,
# swift-6.3-toolchain output (2026-10-05). Only the enclosing run/suite summary
# is reduced to these two declarations. This fixture is not release evidence.
# https://github.com/InnoSquadCorp/InnoFlow/actions/runs/37314847278
unquoted_parameterized = <<~OUTPUT
  ◇ Test run started.
  ◇ Suite "Collection optional child lifetime consistency" started.
  ◇ Test firstAnimatedChildOutputUsesFinalComposedState(useIdentified:) started.
  ◇ Test case passing 1 argument useIdentified → false to firstAnimatedChildOutputUsesFinalComposedState(useIdentified:) started.
  ◇ Test case passing 1 argument useIdentified → true to firstAnimatedChildOutputUsesFinalComposedState(useIdentified:) started.
  ✔ Test firstAnimatedChildOutputUsesFinalComposedState(useIdentified:) with 2 test cases passed after 0.010 seconds.
  ◇ Test animatedParentMutationReconcilesExistingOwnersWithoutMetadata(useIdentified:removeAndReenter:) started.
  ◇ Test case passing 2 arguments useIdentified → false, removeAndReenter → false to animatedParentMutationReconcilesExistingOwnersWithoutMetadata(useIdentified:removeAndReenter:) started.
  ◇ Test case passing 2 arguments useIdentified → false, removeAndReenter → true to animatedParentMutationReconcilesExistingOwnersWithoutMetadata(useIdentified:removeAndReenter:) started.
  ◇ Test case passing 2 arguments useIdentified → true, removeAndReenter → false to animatedParentMutationReconcilesExistingOwnersWithoutMetadata(useIdentified:removeAndReenter:) started.
  ◇ Test case passing 2 arguments useIdentified → true, removeAndReenter → true to animatedParentMutationReconcilesExistingOwnersWithoutMetadata(useIdentified:removeAndReenter:) started.
  ✔ Test animatedParentMutationReconcilesExistingOwnersWithoutMetadata(useIdentified:removeAndReenter:) with 4 test cases passed after 0.018 seconds.
  ✔ Suite "Collection optional child lifetime consistency" passed after 0.028 seconds.
  ✔ Test run with 2 tests in 1 suite passed after 0.028 seconds.
OUTPUT
unquoted_parameterized_check = {
  "minimumTestCount" => 2,
  "maximumTestCount" => 2,
  "expectedTestRunCount" => 1,
  "expectedResultSuites" => ["Collection optional child lifetime consistency"],
  "expectedTestNames" => [
    "firstAnimatedChildOutputUsesFinalComposedState(useIdentified:)",
    "animatedParentMutationReconcilesExistingOwnersWithoutMetadata(useIdentified:removeAndReenter:)",
  ],
}
assert_result("Swift 6.3 unquoted parameterized real-log excerpt", unquoted_parameterized,
  accepted: true, check: unquoted_parameterized_check)
unquoted_case = unquoted_parameterized.lines.find { |line| line.include?("Test case passing 1 argument") }
{
  "unknown owner" => unquoted_case.sub("to firstAnimated", "to unknownFirstAnimated"),
  "missing owner" => unquoted_case.sub(/to .* started/, "to started"),
  "unterminated quoted owner" => unquoted_case.sub("to firstAnimated", 'to "firstAnimated'),
  "unmatched closing quote" => unquoted_case.sub(" started.", '" started.'),
  "unknown case start syntax" => unquoted_case.sub("started.", "started eventually"),
  "missing argument description" => unquoted_case.sub("passing 1 argument useIdentified → false", "passing"),
  "unknown case terminal" => unquoted_case.sub("started.", "passed after 0.001 seconds."),
}.each do |name, malformed_case|
  assert_result("unquoted parameterized #{name}", unquoted_parameterized.sub(unquoted_case, malformed_case),
    accepted: false, check: unquoted_parameterized_check)
end
assert_result("unquoted case count mismatch",
  unquoted_parameterized.sub("with 2 test cases", "with 3 test cases"),
  accepted: false, check: unquoted_parameterized_check)
assert_result("unquoted duplicate case start",
  unquoted_parameterized.sub(unquoted_case, unquoted_case + unquoted_case),
  accepted: false, check: unquoted_parameterized_check)
%w[started passed].each do |event|
  missing_event = unquoted_parameterized.lines.reject do |line|
    line.match?(/Test firstAnimated.* #{event}/)
  end.join
  assert_result("unquoted parameterized missing test #{event}", missing_event,
    accepted: false, check: unquoted_parameterized_check)
end
%w[failed skipped cancelled].each do |result|
  assert_result("unquoted parameterized #{result}",
    unquoted_parameterized.sub("with 2 test cases passed", "with 2 test cases #{result}"),
    accepted: false, check: unquoted_parameterized_check)
end
assert_result("unquoted cases do not inflate declarations", unquoted_parameterized,
  accepted: false, check: unquoted_parameterized_check.merge("minimumTestCount" => 6, "maximumTestCount" => 6))
assert_result("unquoted parameterized required identity is exact", unquoted_parameterized,
  accepted: false, check: unquoted_parameterized_check.merge("expectedTestNames" => ["unknown(useIdentified:)"]))

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

# Swift Testing reports unnamed tests as identifiers. These are not run, suite,
# or XCTest case events even when their identifiers start with reserved words.
reserved_prefix_names = %w[runLaneSnapshotProvider() SuiteStatus() CaseExtraction() run() Suite() Case()]
reserved_prefix_check = {
  "minimumTestCount" => reserved_prefix_names.length,
  "maximumTestCount" => reserved_prefix_names.length,
  "expectedTestRunCount" => 1,
  "expectedTestNames" => reserved_prefix_names,
}
reserved_prefix_output = "◇ Test run started.\n" + reserved_prefix_names.map do |name|
  "◇ Test #{name} started.\n✔ Test #{name} passed after 0.001 seconds.\n"
end.join + "✔ Test run with #{reserved_prefix_names.length} tests in 0 suites passed after 0.001 seconds.\n"
assert_result("reserved-prefix identifiers", reserved_prefix_output, accepted: true, check: reserved_prefix_check)
%w[failed skipped cancelled].each do |result|
  assert_result("reserved-prefix #{result}",
    reserved_prefix_output.sub("runLaneSnapshotProvider() passed", "runLaneSnapshotProvider() #{result}"),
    accepted: false, check: reserved_prefix_check)
end
%w[started passed].each do |event|
  missing_event = reserved_prefix_output.lines.reject { |line| line.include?("runLaneSnapshotProvider() #{event}") }.join
  assert_result("reserved-prefix missing #{event}", missing_event, accepted: false, check: reserved_prefix_check)
end
assert_result("reserved-prefix summary count mismatch",
  reserved_prefix_output.sub("with 6 tests", "with 7 tests"), accepted: false)

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

# Counts are exact source-declaration expectations. Passing additional leaves
# or a parameterized case count must not silently widen the inventory.
assert_result("exact declaration count", normal, accepted: true,
  check: { "minimumTestCount" => 1, "maximumTestCount" => 1 })
assert_result("passing extra bundle exceeds inventory", normal + second_bundle, accepted: false,
  check: { "minimumTestCount" => 1, "maximumTestCount" => 1 })
assert_result("missing bundle below inventory", normal, accepted: false,
  check: { "minimumTestCount" => 2, "maximumTestCount" => 2 })
assert_result("parameterized declarations counted once", parameterized, accepted: true,
  check: { "minimumTestCount" => 2, "maximumTestCount" => 2 })
assert_result("parameter cases do not inflate declaration count", parameterized, accepted: false,
  check: { "minimumTestCount" => 3, "maximumTestCount" => 3 })

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

capability_check = {"requiredCapabilityTests" => [{"suite" => "FlowTask dispatch lifetime", "name" => "normal completion", "occurrences" => 1}]}
assert_result("capability must execute", normal, accepted: true, check: capability_check)
assert_result("capability cannot skip", normal.sub("passed after 0.001", "skipped after 0.001"), accepted: false, check: capability_check)
assert_result("capability cannot be substituted", normal.gsub("normal completion", "another completion"), accepted: false, check: capability_check)
assert_result("capability cannot change suite", normal.gsub("FlowTask dispatch lifetime", "Other suite"), accepted: false, check: capability_check)
assert_result("full principle requires both executions", normal, accepted: false,
  check: {"requiredCapabilityTests" => [capability_check.fetch("requiredCapabilityTests").first.merge("occurrences" => 2)]})
assert_result("full principle two executions", normal + normal, accepted: true,
  check: {"requiredCapabilityTests" => [capability_check.fetch("requiredCapabilityTests").first.merge("occurrences" => 2)]})
puts "[release-evidence-output-parser-selftest] All checks passed"
