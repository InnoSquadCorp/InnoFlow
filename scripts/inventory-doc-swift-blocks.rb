#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "json"
require "open3"

root = ARGV.shift || File.expand_path("..", __dir__)
abort "Usage: inventory-doc-swift-blocks.rb [repository-root]" unless ARGV.empty?
files = if File.exist?(File.join(root, ".git"))
          output, error, status = Open3.capture3(
            "git", "-C", root, "ls-files", "-z", "--cached", "--others",
            "--exclude-standard", "--", "*.md", "*.mdx"
          )
          abort "Markdown inventory failed: #{error}" unless status.success?
          output.split("\0")
        else
          # Standalone fixture roots have no Git index. The production inventory
          # uses Git so ignored build artifacts never enter the release corpus.
          Dir.glob("**/*.{md,mdx}", base: root)
        end
blocks = []
files.uniq.sort.each do |relative|
  next unless File.file?(File.join(root, relative))
  lines = File.readlines(File.join(root, relative))
  index = 0
  while index < lines.length
    unless lines[index].match?(/^```[sS]wift(?:\s.*)?$/)
      index += 1
      next
    end
    start = index + 1
    index += 1
    content = []
    while index < lines.length && !lines[index].match?(/^```\s*$/)
      content << lines[index]
      index += 1
    end
    abort "Unterminated Swift fence: #{relative}:#{start}" if index == lines.length
    source = content.join
    blocks << {
      "file" => relative,
      "line" => start,
      "sha256" => Digest::SHA256.hexdigest(source),
      "firstLine" => content.find { |line| !line.strip.empty? }&.strip,
      "classification" => "unreviewed",
    }
    index += 1
  end
end
puts JSON.pretty_generate({
  "schema" => "innoflow-doc-swift-block-inventory-v1",
  "reviewStatus" => "unreviewed",
  "blockCount" => blocks.length,
  "fileCount" => blocks.map { |block| block.fetch("file") }.uniq.length,
  "blocks" => blocks,
})
