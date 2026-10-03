#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "digest"
require "open3"
require "tmpdir"

begin
  root = ARGV.fetch(0, File.expand_path("..", __dir__))
  policy_path = File.join(root, "docs/contracts/release-evidence-policy.json")
  source_path = File.join(root, "Tests/InnoFlowTests/CompileContractTests.swift")
  policy = JSON.parse(File.read(policy_path))
  expected_ids_by_stage = {
    "local-preflight" => %w[
      static-format static-innoflow-diff static-principle doc-swift-syntax doc-fence-review doc-copyable-examples coverage full-principle
      tsan-focused asan-focused external-macro-consumer migration-consumer catalyst-macro-consumer
      swift-6.3-toolchain sample-swift-6.3 swift-6.4-toolchain sdk-macos sdk-ios sdk-tvos
      sdk-watchos sdk-visionos sample-sdk-tvos sample-sdk-watchos sample-sdk-visionos runtime-ios-18.5 runtime-ios-27.0
      runtime-tvos-18.5 runtime-tvos-27.0 runtime-watchos-11.5
      runtime-watchos-27.0 runtime-visionos-2.5 runtime-visionos-27.0
    ],
    "pre-publication" => %w[remote-ci tag-api-baseline release-approval],
    "post-publication" => %w[public-package-install],
  }
  actual_ids_by_stage = policy.fetch("checks").group_by { |entry| entry.fetch("stage") }
    .transform_values { |entries| entries.map { |entry| entry.fetch("id") } }
  abort "[release-evidence-policy] framework-only check inventory changed" unless actual_ids_by_stage == expected_ids_by_stage
  abort "[release-evidence-policy] framework-only policy must not contain product matrices" unless policy.fetch("matrices", []).empty?
  abort "[release-evidence-policy] retired product dependency remains" if File.read(policy_path).match?(/mulbyul/i)
  migration = policy.fetch("checks").find { |entry| entry["id"] == "migration-consumer" }
  abort "[release-evidence-policy] migration consumer command changed" unless
    migration&.dig("commandContract") == { "executable" => "scripts/check-migration-consumer.sh", "exactArguments" => [] } &&
    migration["profile"] == "command"
  doc_syntax = policy.fetch("checks").find { |entry| entry["id"] == "doc-swift-syntax" }
  abort "[release-evidence-policy] documentation syntax contract changed" unless
    doc_syntax&.dig("commandContract") == { "executable" => "scripts/check-doc-swift-syntax.rb", "exactArguments" => [] } &&
    doc_syntax["profile"] == "command" && File.executable?(File.join(root, "scripts/check-doc-swift-syntax.rb"))
  doc_copyable = policy.fetch("checks").find { |entry| entry["id"] == "doc-copyable-examples" }
  abort "[release-evidence-policy] copyable documentation contract changed" unless
    doc_copyable&.dig("commandContract") == { "executable" => "scripts/check-doc-copyable-examples.rb", "exactArguments" => [] } &&
    doc_copyable["profile"] == "command" && File.executable?(File.join(root, "scripts/check-doc-copyable-examples.rb"))
  doc_review = policy.fetch("checks").find { |entry| entry["id"] == "doc-fence-review" }
  abort "[release-evidence-policy] complete documentation review contract changed" unless
    doc_review&.dig("commandContract") == { "executable" => "scripts/report-doc-fence-review.rb", "exactArguments" => ["--require-complete"] } &&
    doc_review["profile"] == "command" && File.executable?(File.join(root, "scripts/report-doc-fence-review.rb"))
  sample_inventory_relative = "docs/contracts/sample-test-inventory.json"
  sample_inventory_path = File.join(root, sample_inventory_relative)
  sample_inventory = JSON.parse(File.read(sample_inventory_path))
  sample_package = "Examples/InnoFlowSampleApp/InnoFlowSampleAppPackage"
  sample_target = "InnoFlowSampleAppFeatureTests"
  sample_sources = sample_inventory.fetch("sourceFiles")
  sample_source_paths = ["#{sample_package}/Package.swift"] +
    Dir.glob(File.join(root, sample_package, "Tests", sample_target, "**", "*.swift"))
      .map { |path| path.delete_prefix(root + "/") }
  abort "[release-evidence-policy] sample source inventory changed" unless
    sample_inventory["schemaVersion"] == 1 && sample_inventory["hostTargets"] == [sample_target] &&
    sample_sources.keys.sort == sample_source_paths.sort
  sample_sources.each do |path, sha|
    abort "[release-evidence-policy] sample test source changed: #{path}" unless
      sha.is_a?(String) && sha.match?(/\A[0-9a-f]{64}\z/) && Digest::SHA256.file(File.join(root, path)).hexdigest == sha
  end
  sample_tests = sample_inventory.fetch("tests")
  sample_keys = sample_tests.map { |test| test.fetch("identifier") }
  abort "[release-evidence-policy] sample declarations are empty, duplicated, or unsorted" unless
    !sample_keys.empty? && sample_keys == sample_keys.uniq.sort
  sample_tests.each do |test|
    abort "[release-evidence-policy] invalid sample test declaration" unless
      test["target"] == sample_target && test["conditionalContexts"] == [] &&
      sample_sources.key?(test["file"]) && test["file"].start_with?("#{sample_package}/Tests/#{sample_target}/")
  end
  sample = policy.fetch("checks").find { |entry| entry["id"] == "sample-swift-6.3" }
  abort "[release-evidence-policy] Swift 6.3 sample contract changed" unless
    sample&.dig("commandContract") == {
      "executable" => "scripts/check-sample-swift63.sh", "requiredArguments" => ["--scratch-path"]
    } && sample["minimumTestCount"] == sample_tests.length && sample["maximumTestCount"] == sample_tests.length &&
    sample["swiftTestInventory"] == sample_inventory_relative &&
    sample["swiftTestInventorySha256"] == Digest::SHA256.file(sample_inventory_path).hexdigest &&
    sample["expectedTestRunCount"] == 1 &&
    sample["expectedResultSuites"] == ["InnoFlowSampleAppFeature tests"] &&
    sample.dig("environment", "swift") == "6.3"
  sample_script = File.join(root, "scripts/check-sample-swift63.sh")
  abort "[release-evidence-policy] Swift 6.3 sample runner is missing" unless
    File.executable?(sample_script) && File.read(sample_script).include?("-DINNOFLOW_DISABLE_PREVIEWS")
  runner = File.join(root, "scripts/run-release-preflight.sh")
  abort "[release-evidence-policy] preflight runner must be executable" unless File.executable?(runner)
  plan, error, status = Open3.capture3(runner, "plan", "--evidence-root", File.join(Dir.tmpdir, "innoflow-preflight-plan"))
  abort "[release-evidence-policy] preflight catalog failed: #{error.strip}" unless status.success?
  planned_ids = plan.lines.map { |line| line.split("\t", 2).first }
  abort "[release-evidence-policy] preflight catalog does not cover every local check" unless
    planned_ids == expected_ids_by_stage.fetch("local-preflight")
  check = policy.fetch("checks").find { |entry| entry.fetch("id") == "external-macro-consumer" }
  abort "[release-evidence-policy] external-macro-consumer is missing" unless check

  names = Array(check["expectedTestNames"])
  abort "[release-evidence-policy] external macro test inventory is empty" if names.empty?
  abort "[release-evidence-policy] external macro test inventory contains blank names" if names.any? { |name| !name.is_a?(String) || name.empty? }
  abort "[release-evidence-policy] external macro test inventory contains duplicates" unless names.uniq.length == names.length
  abort "[release-evidence-policy] external macro suite contract changed" unless check["expectedResultSuites"] == ["Compile Contract Tests"]
  abort "[release-evidence-policy] external macro test minimum does not match inventory" unless check["minimumTestCount"] == names.length
  abort "[release-evidence-policy] external macro test maximum does not match inventory" unless check["maximumTestCount"] == names.length
  abort "[release-evidence-policy] external macro run count must be one" unless check["expectedTestRunCount"] == 1

  # The exact count is derived from reviewed SwiftSyntax declarations, never
  # widened to match a passing process. Pin all compiled test sources and the
  # manifest so additions/removals/configuration changes require regeneration.
  full_inventory_relative = "docs/contracts/swift-test-inventory.json"
  full_inventory_path = File.join(root, full_inventory_relative)
  full_inventory = JSON.parse(File.read(full_inventory_path))
  abort "[release-evidence-policy] invalid Swift test source inventory" unless
    full_inventory["schemaVersion"] == 1 &&
    full_inventory["hostTargets"] == %w[InnoFlowTests InnoFlowMacrosTests]
  full_sources = full_inventory.fetch("sourceFiles")
  actual_source_paths = ["Package.swift"] + %w[InnoFlowTests InnoFlowMacrosTests].flat_map do |target|
    Dir.glob(File.join(root, "Tests", target, "**", "*.swift")).reject do |path|
      path.delete_prefix(root + "/").split("/").include?("Fixtures")
    end.map { |path| path.delete_prefix(root + "/") }
  end
  abort "[release-evidence-policy] Swift test source file inventory changed" unless
    full_sources.keys.sort == actual_source_paths.sort
  full_sources.each do |path, sha|
    abort "[release-evidence-policy] Swift test source changed: #{path}" unless
      sha.is_a?(String) && sha.match?(/\A[0-9a-f]{64}\z/) && Digest::SHA256.file(File.join(root, path)).hexdigest == sha
  end
  full_tests = full_inventory.fetch("tests")
  full_keys = full_tests.map { |test| [test.fetch("target"), test.fetch("identifier")] }
  abort "[release-evidence-policy] Swift test declarations are empty, duplicated, or unsorted" unless
    !full_keys.empty? && full_keys == full_keys.uniq.sort
  full_tests.each do |test|
    abort "[release-evidence-policy] invalid Swift test declaration source" unless
      full_inventory.fetch("hostTargets").include?(test["target"]) &&
      full_sources.key?(test["file"]) &&
      test["file"].start_with?("Tests/#{test.fetch('target')}/") &&
      test["identifier"].is_a?(String) && !test["identifier"].empty?
    # The reviewed host inventory currently has just this declaration-level
    # condition. Unknown/platform-dependent declarations must not be counted
    # without an explicit configuration review.
    conditions = test.fetch("conditionalContexts")
    abort "[release-evidence-policy] unreviewed conditional Swift test declaration" unless
      conditions == [] ||
      (test["identifier"] == "CompiledHarnessCacheTests/preservesProcessIsolation()" &&
       conditions == ["#if os(macOS) || os(Linux)"])
  end
  baseline_count = full_tests.count do |test|
    test["target"] == "InnoFlowTests" && test["identifier"].start_with?("EffectTimingBaselineGate/")
  end
  abort "[release-evidence-policy] isolated timing baseline inventory changed" unless baseline_count == 1
  full_inventory_sha = Digest::SHA256.file(full_inventory_path).hexdigest
  {
    "swift-6.3-toolchain" => full_tests.length,
    "swift-6.4-toolchain" => full_tests.length,
    "full-principle" => full_tests.length * 2 + baseline_count,
  }.each do |id, count|
    full_check = policy.fetch("checks").find { |entry| entry.fetch("id") == id }
    abort "[release-evidence-policy] #{id} count differs from exact source inventory" unless
      full_check && full_check["minimumTestCount"] == count && full_check["maximumTestCount"] == count &&
      full_check["swiftTestInventory"] == full_inventory_relative &&
      full_check["swiftTestInventorySha256"] == full_inventory_sha
  end

  full_principle = policy.fetch("checks").find { |entry| entry.fetch("id") == "full-principle" }
  abort "[release-evidence-policy] full-principle run count changed" unless
    full_principle["expectedTestRunCount"] == 5

  # Swift 6.3 aggregates the Core and macro suites into one run, while the
  # Xcode 27 Swift 6.4 runner emits two. These counts were measured from the
  # complete baseline outputs, not inferred from the number of test targets.
  { "swift-6.3-toolchain" => 1, "swift-6.4-toolchain" => 2 }.each do |id, expected_runs|
    toolchain_check = policy.fetch("checks").find { |entry| entry.fetch("id") == id }
    abort "[release-evidence-policy] #{id} is missing" unless toolchain_check
    abort "[release-evidence-policy] #{id} run count changed" unless
      toolchain_check["expectedTestRunCount"] == expected_runs
  end

  contract = check.fetch("commandContract")
  abort "[release-evidence-policy] external macro command must be swift" unless contract["executable"] == "swift"
  abort "[release-evidence-policy] external macro command must require swift test" unless Array(contract["requiredArguments"]).include?("test")
  abort "[release-evidence-policy] external macro command must select the full suite" unless contract.dig("exclusiveOptionValues", "--filter") == "CompileContractTests"
  abort "[release-evidence-policy] external macro command must reject skip options" unless Array(contract["forbiddenArgumentPrefixes"]).include?("--skip")
  abort "[release-evidence-policy] external macro command must reject package redirection" unless Array(contract["forbiddenArgumentPrefixes"]).include?("--package-path")

  sdk_checks = policy.fetch("checks").select { |entry| entry.fetch("id").start_with?("sdk-") }
  abort "[release-evidence-policy] five SDK checks are required" unless sdk_checks.length == 5
  build_profile = policy.fetch("profiles").fetch("build")
  abort "[release-evidence-policy] SDK build profile must require raw structured results" unless
    build_profile["resultFormat"] == "xcresult-build-results" &&
    build_profile["requiresRawArtifact"] == true &&
    build_profile["artifactContent"] == "non-empty"
  sdk_checks.each do |sdk_check|
    sdk_contract = sdk_check.fetch("commandContract")
    abort "[release-evidence-policy] #{sdk_check.fetch("id")} must preserve raw build results" unless sdk_check["profile"] == "build"
    abort "[release-evidence-policy] #{sdk_check.fetch("id")} can redirect or skip the build" unless
      sdk_contract["executable"] == "scripts/run-sdk-platform-build.sh" &&
      Array(sdk_contract["requiredArguments"]) == %w[--platform --derived-data --result-bundle] &&
      sdk_contract.dig("exclusiveOptionValues", "--platform") == sdk_check.dig("environment", "platform")
  end
  sample_sdk_checks = policy.fetch("checks").select { |entry| entry.fetch("id").start_with?("sample-sdk-") }
  abort "[release-evidence-policy] three sample SDK checks are required" unless sample_sdk_checks.length == 3
  sample_sdk_checks.each do |check|
    contract = check.fetch("commandContract")
    abort "[release-evidence-policy] sample SDK contract changed: #{check.fetch('id')}" unless
      check["profile"] == "build" &&
      contract["executable"] == "scripts/run-sdk-platform-build.sh" &&
      contract["requiredArguments"] == %w[--sample --platform --derived-data --result-bundle] &&
      contract.dig("exclusiveOptionValues", "--platform") == check.dig("environment", "platform")
  end

  runtime_checks = policy.fetch("checks").select { |entry| entry.fetch("id").start_with?("runtime-") }
  abort "[release-evidence-policy] eight runtime checks are required" unless runtime_checks.length == 8
  inventory_relative = "docs/contracts/runtime-test-inventory.json"
  inventory_path = File.join(root, inventory_relative)
  inventory = JSON.parse(File.read(inventory_path))
  expected_suites = %w[
    CollectionLifetimeConsistencyTests
    CollectionScopeCacheTests
    CompletionRelayConsistencyTests
    DiagnosticsRingConsistencyTests
    DispatchDiagnosticsTests
    DispatchIdentityConsistencyTests
    EffectIsolationConsistencyTests
    EffectRunSchedulerTests
    ExplorerFailureBoundaryConsistencyTests
    ExplorerFirstDiagnosticConsistencyTests
    ExplorerSafetyConsistencyTests
    FlowScopeTests
    IdentifiedArrayTests
    InspectorGraphConsistencyTests
    MacroIdentifierConsistencyTests
    MacroMigrationConsistencyTests
    ManualTestClockTests
    ObservationConsistencyTests
    OnChangeHostConsistencyTests
    OptionalChildLifetimeConsistencyTests
    OutputCasePathTests
    PerformanceSemanticsConsistencyTests
    PhaseExplorationConsistencyTests
    RunLaneSnapshotConsistencyTests
    RuntimeConsistencyTests
    SchedulerAdmissionConsistencyTests
    SingleScopeCacheTests
    StoreScopeSelectionTests
    TestEffectLedgerConsistencyTests
    TestStoreDispatchConsistencyTests
    TestingLocationConsistencyTests
    ViewDispatchLifetimeConsistencyTests
  ]
  identifiers = inventory.fetch("expectedTestIdentifiers")
  abort "[release-evidence-policy] runtime inventory suites changed" unless inventory.fetch("suites") == expected_suites
  abort "[release-evidence-policy] runtime inventory is empty, duplicated, or unsorted" unless
    identifiers.is_a?(Array) && !identifiers.empty? && identifiers == identifiers.uniq.sort
  abort "[release-evidence-policy] runtime inventory suite mismatch" unless
    identifiers.map { |identifier| identifier.split("/", 2).first }.uniq.sort == expected_suites
  source_focused_identifiers = full_tests.select do |test|
    test["target"] == "InnoFlowTests" && expected_suites.include?(test.fetch("identifier").split("/", 2).first)
  end.map { |test| test.fetch("identifier") }.sort
  abort "[release-evidence-policy] focused inventory differs from complete source declarations" unless
    identifiers == source_focused_identifiers
  inventory_sha = Digest::SHA256.file(inventory_path).hexdigest
  runtime_checks.each do |runtime_check|
    abort "[release-evidence-policy] #{runtime_check.fetch("id")} has no pinned runtime inventory" unless
      runtime_check["testIdentifierInventory"] == inventory_relative &&
      runtime_check["testIdentifierInventorySha256"] == inventory_sha &&
      !runtime_check.key?("expectedTestIdentifiers")
  end
  runner = File.read(File.join(root, "scripts/run-focused-platform-runtime-tests.sh"))
  discovery_target_selections = runner.scan(/^\s+-only-testing:([A-Za-z_][A-Za-z0-9_]*)$/).flatten
  abort "[release-evidence-policy] runtime discovery must select only the runtime target" unless
    discovery_target_selections == ["InnoFlowTests"]
  runner_suites = runner.scan(/^\s+-only-testing:InnoFlowTests\/([A-Za-z_][A-Za-z0-9_]*)$/).flatten
  abort "[release-evidence-policy] runtime runner suite selection differs from the reviewed inventory" unless
    runner_suites.sort == expected_suites

  source = File.read(source_path)
  source_names = source.scan(/^\s+@Test\s*\(\s*"((?:[^"\\]|\\.)*)"/).flatten.map do |escaped_name|
    JSON.parse(%Q{"#{escaped_name}"})
  end
  abort "[release-evidence-policy] source test display names contain duplicates" unless source_names.uniq.length == source_names.length
  unless source_names.sort == names.sort
    missing = names - source_names
    unexpected = source_names - names
    abort "[release-evidence-policy] source inventory mismatch missing=#{missing.inspect} unexpected=#{unexpected.inspect}"
  end

  puts "[release-evidence-policy] External macro inventory and command contract passed (#{names.length} tests)"
rescue JSON::ParserError, KeyError, Errno::ENOENT, TypeError => error
  abort "[release-evidence-policy] Invalid policy: #{error.message}"
end
