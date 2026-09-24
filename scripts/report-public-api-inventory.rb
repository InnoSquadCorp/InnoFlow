#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"

MODULES = %w[InnoFlow InnoFlowCore InnoFlowSwiftUI InnoFlowTesting].freeze

def fail_inventory(message)
  abort "[public-api-inventory] #{message}"
end

def symbols(directory, module_name)
  path = File.join(directory, "#{module_name}.symbols.json")
  graph = JSON.parse(File.read(path))
  prefix = "/Sources/#{module_name}/"
  result = graph.fetch("symbols").filter_map do |symbol|
    source = symbol.dig("location", "uri").to_s
    next unless source.include?(prefix)
    next unless %w[public open].include?(symbol["accessLevel"])

    precise = symbol.dig("identifier", "precise")
    fail_inventory("Symbol without precise identifier in #{path}") if precise.to_s.empty?
    {
      "precise" => precise,
      "path" => symbol.fetch("pathComponents"),
      "title" => symbol.fetch("names").fetch("title"),
      "kind" => symbol.fetch("kind").fetch("identifier"),
      "access" => symbol.fetch("accessLevel"),
      "declaration" => Array(symbol["declarationFragments"]).map { |part| part.fetch("spelling") }.join,
      "generics" => symbol["swiftGenerics"],
      "functionSignature" => symbol["functionSignature"],
      "availability" => symbol["availability"],
      "source" => source.split(prefix, 2).last,
    }
  end
  fail_inventory("Duplicate precise identifiers in #{module_name}") unless
    result.map { |entry| entry.fetch("precise") }.uniq.length == result.length
  result.to_h { |entry| [entry.fetch("precise"), entry] }
rescue Errno::ENOENT, JSON::ParserError, KeyError, TypeError => error
  fail_inventory("Cannot read #{module_name} graph: #{error.message}")
end

options = {}
OptionParser.new do |parser|
  parser.on("--baseline-dir DIR") { |value| options[:baseline] = value }
  parser.on("--candidate-dir DIR") { |value| options[:candidate] = value }
end.parse!(ARGV)
fail_inventory("Usage: report-public-api-inventory.rb --baseline-dir DIR --candidate-dir DIR") unless
  ARGV.empty? && options.values_at(:baseline, :candidate).all?

report = { "schema" => "innoflow-public-api-inventory-v1", "comparison" => "5.1.1-to-6.0.0", "reviewStatus" => "unreviewed", "modules" => {} }
MODULES.each do |module_name|
  before = symbols(options.fetch(:baseline), module_name)
  after = symbols(options.fetch(:candidate), module_name)
  common = before.keys & after.keys
  changed = common.filter_map do |key|
    old_entry = before.fetch(key)
    new_entry = after.fetch(key)
    old_contract = old_entry.reject { |field, _| field == "source" }
    new_contract = new_entry.reject { |field, _| field == "source" }
    next if old_contract == new_contract
    { "before" => old_entry, "after" => new_entry }
  end
  report.fetch("modules")[module_name] = {
    "baselineCount" => before.length,
    "candidateCount" => after.length,
    "added" => (after.keys - before.keys).sort.map { |key| after.fetch(key) },
    "removed" => (before.keys - after.keys).sort.map { |key| before.fetch(key) },
    "changed" => changed.sort_by { |entry| entry.dig("after", "precise") },
  }
end
puts JSON.pretty_generate(report)
