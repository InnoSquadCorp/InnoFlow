#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "open3"
require_relative "doc-example-contexts"

require_complete = ARGV.delete("--require-complete")
root = File.expand_path("..", __dir__)
if ARGV.first == "--root" && ARGV.length == 2
  root = File.realpath(ARGV.fetch(1))
  ARGV.clear
end
abort "Usage: report-doc-fence-review.rb [--require-complete] [--root repository]" unless ARGV.empty?

output, error, status = Open3.capture3(File.join(__dir__, "inventory-doc-swift-blocks.rb"), root)
abort "[doc-fence-review] Inventory failed: #{error}" unless status.success?
inventory = JSON.parse(output).fetch("blocks")
path = File.join(root, "docs/contracts/doc-swift-fence-review.tsv")
rows = File.readlines(path, chomp: true).reject { |line| line.empty? || line.start_with?("#") }
review = rows.map do |line|
  columns = line.split("\t", -1)
  abort "[doc-fence-review] Malformed row: #{line}" unless columns.length == 4
  file, digest, classification, evidence = columns
  abort "[doc-fence-review] Invalid digest: #{file}" unless digest.match?(/\A[0-9a-f]{64}\z/)
  unless %w[UNREVIEWED runnable partial expected-compile-failure versioned-historical].include?(classification)
    abort "[doc-fence-review] Invalid classification: #{file} #{classification}"
  end
  { "file" => file, "sha256" => digest, "classification" => classification, "evidence" => evidence }
end
key = ->(entry) { [entry.fetch("file"), entry.fetch("sha256")] }
inventory_keys = inventory.map(&key)
review_keys = review.map(&key)
inventory_by_key = inventory.to_h { |entry| [key.call(entry), entry] }
abort "[doc-fence-review] Duplicate inventory entry" unless inventory_keys.uniq.length == inventory_keys.length
abort "[doc-fence-review] Duplicate review entry" unless review_keys.uniq.length == review_keys.length
unless inventory_keys.sort == review_keys.sort
  missing = inventory_keys - review_keys
  stale = review_keys - inventory_keys
  abort "[doc-fence-review] Inventory drift: missing=#{missing.inspect} stale=#{stale.inspect}"
end

copyable_source = File.read(File.join(root, "scripts/check-doc-copyable-examples.rb"))
copyable_pairs = copyable_source.scan(/\["([^"\n]+\.md)", "([0-9a-f]{64})"\]/)
copyable_pairs += DocExampleContexts::EXAMPLES.values.flatten(1)
copyable_install_digests = %w[
  74ac88232cce73c3c57ce136f6d0a493246a18fc256b3cf3b76723b6bf423065
  56ee87a943747a398098b6f083eb5546084044d59a740f703b6052e2b4586d85
]
review.each do |row|
  file = row.fetch("file")
  digest = row.fetch("sha256")
  case row.fetch("evidence")
  when "doc-copyable-examples"
    abort "[doc-fence-review] Invalid copyable classification: #{file}" unless
      %w[runnable partial].include?(row.fetch("classification"))
    abort "[doc-fence-review] Unbound copyable evidence: #{file} #{digest}" unless
      copyable_pairs.include?([file, digest])
  when "doc-copyable-install-manifest"
    abort "[doc-fence-review] Unbound install evidence: #{file} #{digest}" unless
      %w[README.md README.kr.md README.jp.md README.cn.md].include?(file) &&
        copyable_install_digests.include?(digest) && copyable_source.include?(digest)
  when "sample-concurrency-snippet"
    abort "[doc-fence-review] Invalid sample evidence: #{file}" unless
      file == "Examples/InnoFlowSampleApp/CLAUDE.md" && DocExampleContexts::SAMPLE_FENCES.include?(digest)
  when "versioned-section-noncopyable"
    abort "[doc-fence-review] Invalid historical classification: #{file}" unless
      row.fetch("classification") == "versioned-historical"
    abort "[doc-fence-review] Invalid historical section: #{file}" unless
      %w[MIGRATION.md RELEASE_NOTES.md docs/MIGRATION_3_1.md docs/REMEDIATION_FOURTH_FOLLOWUP_PLAN_6_0.md].include?(file)
    source = File.read(File.join(root, file))
    marker = {
      "MIGRATION.md" => "Historical 5.0 migration guidance follows",
      "RELEASE_NOTES.md" => "Historical archive only",
      "docs/MIGRATION_3_1.md" => "Historical 3.1 guidance only",
      "docs/REMEDIATION_FOURTH_FOLLOWUP_PLAN_6_0.md" => "그대로 복사할 수 있는 예제가 아니다",
    }.fetch(file)
    abort "[doc-fence-review] Missing non-copyable warning: #{file}" unless source.include?(marker)
    if %w[MIGRATION.md RELEASE_NOTES.md].include?(file)
      lines = source.lines
      section = file == "MIGRATION.md" ? "## 5.0.0\n" : "## InnoFlow 1.0.0 Release Notes (Legacy v1 API)\n"
      boundary = lines.index(section)
      block = inventory_by_key.fetch([file, digest])
      abort "[doc-fence-review] Current example misclassified as historical: #{file}:#{block.fetch('line')}" unless
        boundary && block.fetch("line") > boundary + 1
    end
  when "contextual-harness-pending"
    # An explicit incomplete state; --require-complete rejects it below.
  else
    abort "[doc-fence-review] Unknown evidence: #{file} #{row.fetch('evidence')}" unless
      row.fetch("evidence") == "PENDING"
  end
end

counts = review.group_by { |row| row.fetch("classification") }.transform_values(&:length)
pending = review.select do |row|
  row.fetch("classification") == "UNREVIEWED" || row.fetch("evidence").include?("PENDING") ||
    row.fetch("evidence").include?("pending")
end
puts "[doc-fence-review] total=#{review.length} " +
     %w[runnable partial expected-compile-failure versioned-historical UNREVIEWED]
       .map { |name| "#{name}=#{counts.fetch(name, 0)}" }.join(" ") + " pending=#{pending.length}"
pending.each do |row|
  puts "[doc-fence-review] pending #{row.fetch('file')} #{row.fetch('sha256')[0, 12]} " +
       "#{row.fetch('classification')} #{row.fetch('evidence')}"
end
abort "[doc-fence-review] Review incomplete" if require_complete && !pending.empty?
