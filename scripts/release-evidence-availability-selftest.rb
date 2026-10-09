#!/usr/bin/env ruby
# frozen_string_literal: true

require "tmpdir"
source = File.join(__dir__, "release-evidence-tool.rb")
eval(File.read(source).split(/^command_name = /, 2).first, TOPLEVEL_BINDING, source)

# Shape-controlled fixture only: no Apple runtime or xcresulttool is emulated as evidence.
def xcresult_data(path)
  document = JSON.parse(File.read(path))
  [document.fetch("summary"), document.fetch("tests")]
end

def rejects_availability?(&block)
  child = fork do
    $stderr.reopen(File::NULL, "w")
    block.call
  end
  _, status = Process.wait2(child)
  !status.success?
end

ids = %w[
  SnapshotBoundaryConsistencyTests/didSetPrecedesProjectionRefresh(animated:observed:)
  SnapshotBoundaryConsistencyTests/didSetRegistrationDoesNotRecomputeAnUnchangedMemoizedSelection()
  SnapshotBoundaryConsistencyTests/didSetRegistrationPreservesSelectorCallsAndReturnedValues(memoize:changed:)
]
diagnostics = %w[PhaseExplorationConsistencyTests/actualTransitionCoverage() TestingLocationConsistencyTests/swiftTestingUsesCallSite()]
inventory = {"expectedTestIdentifiers" => (["CommonTests/control()"] + ids + diagnostics).sort,
  "expectedFailureTestIdentifiers" => diagnostics,
  "conditionalContextsByIdentifier" => ids.to_h { |id| [id, ["#if compiler(>=6.4)"]] },
  "requiredCapabilitiesByIdentifier" => ids.to_h { |id| [id, "observation-didset-os27"] }}
identity = "Apple Swift version 6.4.0 (swiftlang-fixture)"
Dir.mktmpdir("innoflow-availability-") do |root|
  log = File.join(root, "output.log")
  raw = File.join(root, "raw.json")
  %w[18.5 27.0].each do |version|
    runtime = {"platform" => "iOS Simulator", "os" => version, "deviceId" => "fixture"}
    File.write(log, "[swift-test-inventory] compiler: #{identity}\n[swift-test-inventory] runtime: #{JSON.generate(runtime)}\n")
    check = {"id" => "runtime-fixture", "testIdentifierInventory" => "fixture.json",
      "runtimeInventory" => inventory, "environment" => {"platform" => "iOS Simulator", "os" => version}}
    check = compiler_check(check, identity, log)
    unavailable = version == "18.5" ? ids : []
    cases = inventory.fetch("expectedTestIdentifiers").map do |id|
      {"nodeType" => "Test Case", "nodeIdentifier" => id,
       "result" => unavailable.include?(id) ? "Skipped" : diagnostics.include?(id) ? "Expected Failure" : "Passed"}
    end
    summary = {"result" => "Passed", "totalTestCount" => cases.length, "passedTests" => cases.length - diagnostics.length - unavailable.length,
      "failedTests" => 0, "skippedTests" => unavailable.length, "expectedFailures" => diagnostics.length,
      "devicesAndConfigurations" => [{"device" => {"platform" => runtime["platform"], "osVersion" => version, "deviceId" => "fixture"}}]}
    payload = {"summary" => summary, "tests" => {"nodes" => cases}}
    File.write(raw, JSON.generate(payload))
    result = validate_xcresult!(check, raw, {})
    abort "availability counters were not separate" unless result["executedTestCount"] == cases.length - unavailable.length && result["unavailableTestCount"] == unavailable.length
    %w[opposite-outcome missing-id diagnostic-pass ordinary-skip unknown-os wrong-device wrong-counter].each do |mode|
      changed = JSON.parse(JSON.generate(payload))
      leaf = changed["tests"]["nodes"].find { |item| item["nodeIdentifier"] == ids.first }
      case mode
      when "opposite-outcome"
        leaf["result"] = version == "18.5" ? "Passed" : "Skipped"
      when "missing-id" then changed["tests"]["nodes"].delete(leaf)
      when "diagnostic-pass" then changed["tests"]["nodes"].find { |item| item["nodeIdentifier"] == diagnostics.first }["result"] = "Passed"
      when "ordinary-skip" then changed["tests"]["nodes"].first["result"] = "Skipped"
      when "unknown-os" then changed["summary"]["devicesAndConfigurations"][0]["device"]["osVersion"] = "28.0"
      when "wrong-device" then changed["summary"]["devicesAndConfigurations"][0]["device"]["deviceId"] = "another"
      when "wrong-counter" then changed["summary"]["skippedTests"] += 1
      end
      File.write(raw, JSON.generate(changed))
      abort "invalid availability evidence accepted: #{version} #{mode}" unless rejects_availability? { validate_xcresult!(check, raw, {}) }
    end
  end
  source_path = File.join(root, "source.json")
  source_inventory = {"tests" => ids.map do |id|
    {"target" => "InnoFlowCoreTests", "identifier" => id, "conditionalContexts" => ["#if compiler(>=6.4)"],
     "availabilityAttributes" => ["@available(macOS 27.0, iOS 27.0, tvOS 27.0, watchOS 27.0, visionOS 27.0, *)"]}
  end + [{"target" => "InnoFlowTests", "identifier" => "EffectTimingBaselineGate/baseline()", "conditionalContexts" => []}]}
  File.write(source_path, JSON.generate(source_inventory))
  %w[swift-6.4-toolchain full-principle].each do |id|
    count = id == "full-principle" ? 9 : 4
    host = {"id" => id, "swiftTestInventory" => "source.json", "sourceInventoryRoot" => root,
      "swiftTestInventorySha256" => sha256_file(source_path), "environment" => {"swift" => "6.4"},
      "minimumTestCount" => count, "maximumTestCount" => count}
    File.write(log, "[swift-test-inventory] compiler: #{identity}\n[swift-test-inventory] host-runtime: {\"platform\":\"macOS\",\"os\":\"27.0\"}\n")
    selected = compiler_check(host, identity, log)
    required = selected.fetch("requiredCapabilityTests")
    abort "host capability execution count lost" unless required.length == 3 && required.all? { |item| item["occurrences"] == (id == "full-principle" ? 2 : 1) }
    %w[26.0 28.0 missing].each do |version|
      File.write(log, "[swift-test-inventory] compiler: #{identity}\n" + (version == "missing" ? "" : "[swift-test-inventory] host-runtime: {\"platform\":\"macOS\",\"os\":\"#{version}\"}\n"))
      abort "unsupported/unknown host accepted" unless rejects_availability? { compiler_check(host, identity, log) }
    end
  end
end
puts "[release-evidence-availability-selftest] Exact unavailable and required execution outcomes passed (synthetic artifacts)"
