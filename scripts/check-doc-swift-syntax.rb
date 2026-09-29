#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "json"
require "open3"
require "tempfile"

root = File.expand_path("..", __dir__)
exceptions_path = ARGV.shift || File.join(root, "docs/contracts/doc-swift-syntax-exceptions.json")
abort "Usage: check-doc-swift-syntax.rb [exceptions-json]" unless ARGV.empty?
exceptions = JSON.parse(File.read(exceptions_path)).fetch("exceptions")
abort "[doc-swift-syntax] Exception schema mismatch" unless
  JSON.parse(File.read(exceptions_path)).fetch("schema") == "innoflow-doc-swift-syntax-exceptions-v1"
exception_keys = exceptions.map { |entry| [entry.fetch("file"), entry.fetch("sha256")] }
abort "[doc-swift-syntax] Duplicate syntax exception" unless exception_keys.uniq.length == exception_keys.length
inventory, error, status = Open3.capture3(File.join(__dir__, "inventory-doc-swift-blocks.rb"), root)
abort "[doc-swift-syntax] Inventory failed: #{error}" unless status.success?
blocks = JSON.parse(inventory).fetch("blocks")
failed = 0
expected_failures = []
blocks.each do |block|
  relative = block.fetch("file")
  line = block.fetch("line")
  source_lines = File.readlines(File.join(root, relative))
  index = line
  content = []
  while index < source_lines.length && !source_lines[index].match?(/^```\s*$/)
    content << source_lines[index]
    index += 1
  end
  abort "[doc-swift-syntax] Unterminated or changed block: #{relative}:#{line}" if index == source_lines.length
  source = content.join
  abort "[doc-swift-syntax] Inventory digest drift: #{relative}:#{line}" unless
    Digest::SHA256.hexdigest(source) == block.fetch("sha256")

  Tempfile.create(["innoflow-doc-swift-", ".swift"]) do |file|
    file.write(source)
    file.flush
    _output, diagnostic, result = Open3.capture3("swiftc", "-frontend", "-parse", file.path)
    key = [relative, block.fetch("sha256")]
    if result.success?
      abort "[doc-swift-syntax] Stale exception now parses: #{relative}:#{line}" if exception_keys.include?(key)
      next
    end

    detail = diagnostic.lines.find { |entry| entry.include?("error:") }&.strip || diagnostic.lines.first&.strip
    if exception_keys.include?(key)
      expected_failures << key
      next
    end
    failed += 1
    puts "#{relative}:#{line}: #{detail}"
  end
end
abort "[doc-swift-syntax] Missing contextual exceptions" unless expected_failures.sort == exception_keys.sort
puts "[doc-swift-syntax] parsed=#{blocks.length - failed - expected_failures.length} contextual=#{expected_failures.length} unexpected=#{failed} total=#{blocks.length}"
exit(failed.zero? ? 0 : 1)
