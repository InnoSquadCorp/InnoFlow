# frozen_string_literal: true

module ReleaseEvidenceOutputParser
  ANSI_ESCAPE = /\e\[[0-9;?]*[ -\/]*[@-~]/
  EVENT_PREFIX = "\\A[^A-Za-z0-9_]*"
  RUN_START = /#{EVENT_PREFIX}Test run started\.(?:\s|$)/i
  RUN_SUMMARY = /#{EVENT_PREFIX}Test run with ([0-9]+) tests?(?: in ([0-9]+) suites?)? (passed|failed)(?: after|\.|$)/i
  TEST_QUOTED_START = /#{EVENT_PREFIX}Test "(.*)"(?: with ([0-9]+) test cases?)? started\.(?:\s|$)/i
  TEST_UNQUOTED_START = /#{EVENT_PREFIX}Test (?!(?:run|Suite|Case|"))(.*?)(?: with ([0-9]+) test cases?)? started\.(?:\s|$)/i
  TEST_QUOTED_TERMINAL = /#{EVENT_PREFIX}Test "(.*)"(?: with ([0-9]+) test cases?)? (passed|failed|skipped|cancelled)(?: after| because|:|\.|$)/i
  TEST_UNQUOTED_TERMINAL = /#{EVENT_PREFIX}Test (?!(?:run|Suite|Case|"))(.*?)(?: with ([0-9]+) test cases?)? (passed|failed|skipped|cancelled)(?: after| because|:|\.|$)/i
  TEST_CASE_START = /#{EVENT_PREFIX}Test case .* to "(.*)" started\.(?:\s|$)/i
  SUITE_QUOTED_START = /#{EVENT_PREFIX}Suite "(.*)" started\.(?:\s|$)/i
  SUITE_UNQUOTED_START = /#{EVENT_PREFIX}Suite (?!(?:"))(.*?) started\.(?:\s|$)/i
  SUITE_QUOTED_TERMINAL = /#{EVENT_PREFIX}Suite "(.*)" (passed|failed|skipped|cancelled)(?: after| because|:|\.|$)/i
  SUITE_UNQUOTED_TERMINAL = /#{EVENT_PREFIX}Suite (?!(?:"))(.*?) (passed|failed|skipped|cancelled)(?: after| because|:|\.|$)/i
  SIGNAL_DIAGNOSTIC = /(?:unexpected signal(?: code)?|terminated by signal|signal [0-9]+)/i

  module_function

  def parse(check, raw_output)
    output = raw_output.encode("UTF-8", invalid: :replace, undef: :replace)
      .gsub(ANSI_ESCAPE, "")
    failures = []
    runs = []
    current_run = nil

    output.each_line.with_index(1) do |line, line_number|
      if line.match?(RUN_START)
        failures << "new test run before previous run completed at line=#{line_number}" if current_run
        current_run = new_run
        next
      end

      if (match = line.match(TEST_QUOTED_START) || line.match(TEST_UNQUOTED_START))
        current_run = require_run(current_run, failures, "test start", line_number)
        name = match[1].strip
        suite = current_run.fetch("suiteStack").last
        identity = [suite, name]
        failures << "duplicate test start run=#{runs.length + 1} test=#{name.inspect} line=#{line_number}" if current_run.fetch("activeTests").key?(name)
        failures << "repeated test identity run=#{runs.length + 1} suite=#{suite.inspect} test=#{name.inspect} line=#{line_number}" if current_run.fetch("completedTests").include?(identity)
        current_run.fetch("activeTests")[name] = identity
        current_run.fetch("testStarts")[name] += 1
        next
      end

      if (match = line.match(TEST_CASE_START))
        current_run = require_run(current_run, failures, "test case start", line_number)
        name = match[1].strip
        failures << "test case without active test run=#{runs.length + 1} test=#{name.inspect} line=#{line_number}" unless current_run.fetch("activeTests").key?(name)
        current_run.fetch("caseStarts")[name] += 1
        next
      end

      if (match = line.match(TEST_QUOTED_TERMINAL) || line.match(TEST_UNQUOTED_TERMINAL))
        current_run = require_run(current_run, failures, "test terminal", line_number)
        name = match[1].strip
        identity = current_run.fetch("activeTests").delete(name)
        failures << "test terminal before start run=#{runs.length + 1} test=#{name.inspect} line=#{line_number}" unless identity
        if identity && identity.first != current_run.fetch("suiteStack").last
          failures << "test terminal outside owning suite run=#{runs.length + 1} test=#{name.inspect} line=#{line_number}"
        end
        current_run.fetch("completedTests") << identity if identity
        case_count = match[2]&.to_i
        started_cases = current_run.fetch("caseStarts")[name]
        if started_cases.positive? && started_cases != case_count
          failures << "test case count mismatch run=#{runs.length + 1} test=#{name.inspect} started=#{started_cases} terminal=#{case_count.inspect}"
        end
        current_run.fetch("testTerminals") << {
          "name" => name,
          "count" => 1,
          "caseCount" => case_count,
          "result" => match[3].downcase,
        }
        next
      end

      if (match = line.match(SUITE_QUOTED_START) || line.match(SUITE_UNQUOTED_START))
        current_run = require_run(current_run, failures, "suite start", line_number)
        name = match[1].strip
        current_run.fetch("suiteStack") << name
        current_run.fetch("suiteStarts")[name] += 1
        next
      end

      if (match = line.match(SUITE_QUOTED_TERMINAL) || line.match(SUITE_UNQUOTED_TERMINAL))
        current_run = require_run(current_run, failures, "suite terminal", line_number)
        name = match[1].strip
        if current_run.fetch("suiteStack").last == name
          current_run.fetch("suiteStack").pop
        else
          failures << "suite terminal before/outside start run=#{runs.length + 1} suite=#{name.inspect} line=#{line_number}"
        end
        current_run.fetch("suiteTerminals") << {
          "name" => name,
          "result" => match[2].downcase,
        }
        next
      end

      if (match = line.match(RUN_SUMMARY))
        if current_run.nil?
          failures << "test run summary without start at line=#{line_number}"
          current_run = new_run
        end
        current_run["summary"] = {
          "testCount" => match[1].to_i,
          "suiteCount" => match[2]&.to_i || 0,
          "result" => match[3].downcase,
        }
        validate_run(current_run, failures, runs.length + 1)
        runs << current_run
        current_run = nil
        next
      end

      lifecycle_words = /\b(?:started|passed|failed|skipped|cancelled)\b/i
      swift_event_prefix = /#{EVENT_PREFIX}(?:Test|Suite)\b/i
      legacy_xctest_event = /\A\s*Test (?:Suite|Case)\b/i
      if line.match?(swift_event_prefix) && line.match?(lifecycle_words) && !line.match?(legacy_xctest_event)
        failures << "unrecognized test lifecycle event at line=#{line_number}"
        next
      end

      failures << "unexpected signal" if line.match?(SIGNAL_DIAGNOSTIC)
    end

    failures << "unfinished test run" if current_run
    failures << "missing Swift Testing pass summary" if runs.empty?
    failures << "failed XCTest suite" if output.match?(/Test Suite .* failed at/)

    all_test_terminals = runs.flat_map { |run| run.fetch("testTerminals") }
    all_suite_terminals = runs.flat_map { |run| run.fetch("suiteTerminals") }
    failures << "failed test run" if runs.any? { |run| run.dig("summary", "result") == "failed" }
    failures << "failed test leaf" if all_test_terminals.any? { |terminal| terminal.fetch("result") == "failed" }
    failures << "skipped test" if all_test_terminals.any? { |terminal| terminal.fetch("result") == "skipped" }
    failures << "cancelled test" if all_test_terminals.any? { |terminal| terminal.fetch("result") == "cancelled" }
    failures << "failed suite" if all_suite_terminals.any? { |terminal| terminal.fetch("result") == "failed" }
    failures << "skipped suite" if all_suite_terminals.any? { |terminal| terminal.fetch("result") == "skipped" }
    failures << "cancelled suite" if all_suite_terminals.any? { |terminal| terminal.fetch("result") == "cancelled" }

    passed_runs = runs.select { |run| run.dig("summary", "result") == "passed" }
    passed_tests = passed_runs.flat_map { |run| run.fetch("testTerminals") }
      .select { |terminal| terminal.fetch("result") == "passed" }
    passed_suites = passed_runs.flat_map { |run| run.fetch("suiteTerminals") }
      .select { |terminal| terminal.fetch("result") == "passed" }
    test_count = passed_runs.sum { |run| run.dig("summary", "testCount") }
    suite_count = passed_runs.sum { |run| run.dig("summary", "suiteCount") }
    passed_test_names = passed_tests.map { |terminal| terminal.fetch("name") }.uniq
    passed_suite_names = passed_suites.map { |terminal| terminal.fetch("name") }.uniq

    failures << "zero discovered tests" if test_count.zero?

    minimum = check.fetch("minimumTestCount", 1).to_i
    maximum = check["maximumTestCount"]&.to_i
    failures << "testCount=#{test_count} minimum=#{minimum}" if test_count < minimum
    failures << "testCount=#{test_count} maximum=#{maximum}" if maximum && test_count > maximum
    if check["expectedTestRunCount"]
      failures << "testRunCount=#{passed_runs.length}" unless passed_runs.length == check.fetch("expectedTestRunCount").to_i
    end
    Array(check["expectedResultSuites"]).each do |suite|
      failures << "missingSuite=#{suite}" unless passed_suite_names.include?(suite)
    end
    Array(check["expectedTestNames"]).each do |test_name|
      failures << "missingTest=#{test_name}" unless passed_test_names.include?(test_name)
    end

    {
      "failures" => failures.uniq,
      "result" => {
        "testCount" => test_count,
        "suiteCount" => suite_count,
        "testRunCount" => passed_runs.length,
        "passedSuites" => passed_suite_names.sort,
        "passedTests" => passed_test_names.sort,
      },
    }
  end

  def new_run
    {
      "testStarts" => Hash.new(0),
      "testTerminals" => [],
      "activeTests" => {},
      "completedTests" => [],
      "caseStarts" => Hash.new(0),
      "suiteStarts" => Hash.new(0),
      "suiteTerminals" => [],
      "suiteStack" => [],
      "summary" => nil,
    }
  end

  def require_run(current_run, failures, event, line_number)
    return current_run if current_run
    failures << "#{event} without test run start at line=#{line_number}"
    new_run
  end

  def validate_run(run, failures, run_number)
    summary = run.fetch("summary")
    failures << "run=#{run_number} has active tests" unless run.fetch("activeTests").empty?
    failures << "run=#{run_number} has active suites" unless run.fetch("suiteStack").empty?
    test_terminal_counts = run.fetch("testTerminals").each_with_object(Hash.new(0)) do |terminal, counts|
      counts[terminal.fetch("name")] += 1
    end
    suite_terminal_counts = run.fetch("suiteTerminals").each_with_object(Hash.new(0)) do |terminal, counts|
      counts[terminal.fetch("name")] += 1
    end

    compare_lifecycle_counts("test", run.fetch("testStarts"), test_terminal_counts, failures, run_number)
    compare_lifecycle_counts("suite", run.fetch("suiteStarts"), suite_terminal_counts, failures, run_number)

    terminal_test_count = run.fetch("testTerminals").sum { |terminal| terminal.fetch("count") }
    terminal_suite_count = run.fetch("suiteTerminals").length
    if summary.fetch("testCount") != terminal_test_count
      failures << "run=#{run_number} summary tests=#{summary.fetch("testCount")} leaves=#{terminal_test_count}"
    end
    if summary.fetch("suiteCount") != terminal_suite_count
      failures << "run=#{run_number} summary suites=#{summary.fetch("suiteCount")} terminals=#{terminal_suite_count}"
    end
  end

  def compare_lifecycle_counts(kind, starts, terminals, failures, run_number)
    (starts.keys | terminals.keys).sort.each do |name|
      next if starts[name] == terminals[name]
      failures << "run=#{run_number} #{kind}=#{name.inspect} starts=#{starts[name]} terminals=#{terminals[name]}"
    end
  end
end
