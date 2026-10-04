#!/usr/bin/env ruby
# frozen_string_literal: true

require "tmpdir"
source = File.join(__dir__, "release-evidence-tool.rb")
eval(File.read(source).split(/^command_name = /, 2).first, TOPLEVEL_BINDING, source)

def rejects_selection?(&block)
  child = fork do
    $stderr.reopen(File::NULL, "w")
    block.call
  end
  _, status = Process.wait2(child)
  !status.success?
end

Dir.mktmpdir("innoflow-compiler-inventory-") do |root|
  log = File.join(root, "output.log")
  inventory = {
    "expectedTestIdentifiers" => ["A/common()", "A/didSet()"],
    "expectedFailureTestIdentifiers" => [],
    "conditionalContextsByIdentifier" => {"A/didSet()" => ["#if compiler(>=6.4)"]},
  }
  check = {"id" => "runtime-fixture", "runtimeInventory" => inventory}
  %w[6.3 6.4].each do |version|
    identity = "Apple Swift version #{version}.0 (swiftlang-fixture)"
    File.write(log, "[swift-test-inventory] compiler: #{identity}\n")
    selected = compiler_check(check, identity, log)
    expected = version == "6.3" ? ["A/common()"] : inventory.fetch("expectedTestIdentifiers")
    abort "wrong conditional identifiers for #{version}" unless selected["expectedTestIdentifiers"] == expected
    abort "conditional counts were widened" unless
      selected["minimumTestCount"] == expected.length && selected["maximumTestCount"] == expected.length
    other = version == "6.3" ? "6.4" : "6.3"
    abort "mismatched receipt compiler was accepted" unless rejects_selection? { compiler_check(check, "Swift version #{other}", log) }
    abort "compiler build mismatch was accepted" unless rejects_selection? { compiler_check(check, identity.sub("swiftlang-fixture", "other-build"), log) }
    abort "missing receipt compiler was accepted" unless rejects_selection? { compiler_check(check, "Xcode 27", log) }
  end
  ["", "Swift version 6.4\n", "[swift-test-inventory] compiler: Swift version 6.5\n",
   "[swift-test-inventory] compiler: Swift version 6.3\n[swift-test-inventory] compiler: Swift version 6.4\n"].each do |output|
    File.write(log, output)
    abort "missing/unknown/conflicting execution compiler was accepted" unless rejects_selection? { compiler_check(check, "Swift version 6.4", log) }
  end
  %w[swift-6.3-toolchain swift-6.4-toolchain full-principle].each do |id|
    version = id == "swift-6.3-toolchain" ? "6.3" : "6.4"
    source_path = File.join(root, "source.json")
    File.write(source_path, JSON.generate({"tests" => [{"target" => "InnoFlowTests",
      "identifier" => "EffectTimingBaselineGate/baseline()", "conditionalContexts" => []}]}))
    count = id == "full-principle" ? 3 : 1
    host = {"id" => id, "swiftTestInventory" => "source.json", "environment" => {"swift" => version},
      "sourceInventoryRoot" => root, "swiftTestInventorySha256" => sha256_file(source_path),
      "minimumTestCount" => count, "maximumTestCount" => count}
    File.write(log, "[swift-test-inventory] compiler: Swift version #{version}\n")
    abort "correct host compiler rejected" unless compiler_check(host, "Swift version #{version}", log) == host
    other = version == "6.3" ? "6.4" : "6.3"
    File.write(log, "[swift-test-inventory] compiler: Swift version #{other}\n")
    abort "wrong full/host compiler was accepted" unless rejects_selection? { compiler_check(host, "Swift version #{other}", log) }
  end
end
puts "[release-evidence-conditions-selftest] All checks passed"
