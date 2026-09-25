#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "tmpdir"

Dir.mktmpdir("innoflow-api-inventory-") do |root|
  before = File.join(root, "before")
  after = File.join(root, "after")
  FileUtils.mkdir_p([before, after])
  modules = %w[InnoFlow InnoFlowCore InnoFlowSwiftUI InnoFlowTesting]
  modules.each do |module_name|
    make_symbol = lambda do |precise, name, spelling|
      { "identifier" => { "precise" => precise }, "pathComponents" => [name],
        "names" => { "title" => name }, "kind" => { "identifier" => "swift.func" },
        "accessLevel" => "public", "declarationFragments" => [{ "spelling" => spelling }],
        "location" => { "uri" => "file:///tmp/Sources/#{module_name}/Fixture.swift" } }
    end
    old_symbols = [make_symbol.call("#{module_name}-same", "same", "func same()")]
    new_symbols = [make_symbol.call("#{module_name}-same", "same", "func same()")]
    if module_name == "InnoFlowCore"
      old_symbols << make_symbol.call("removed", "removed", "func removed()")
      new_symbols << make_symbol.call("added", "added", "func added()")
      new_symbols[0]["declarationFragments"] = [{ "spelling" => "func same() async" }]
    end
    File.write(File.join(before, "#{module_name}.symbols.json"), JSON.generate({ "symbols" => old_symbols }))
    File.write(File.join(after, "#{module_name}.symbols.json"), JSON.generate({ "symbols" => new_symbols }))
  end
  output, error, status = Open3.capture3(File.join(__dir__, "report-public-api-inventory.rb"),
    "--baseline-dir", before, "--candidate-dir", after)
  abort error unless status.success?
  core = JSON.parse(output).fetch("modules").fetch("InnoFlowCore")
  abort "Inventory diff lost a public declaration" unless
    core.fetch("added").map { |entry| entry.fetch("precise") } == ["added"] &&
    core.fetch("removed").map { |entry| entry.fetch("precise") } == ["removed"] &&
    core.fetch("changed").length == 1
  puts "[public-api-inventory-selftest] added, removed, changed controls passed"
end
