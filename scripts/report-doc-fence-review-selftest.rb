#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "tmpdir"

root = File.realpath(File.expand_path("..", __dir__))
reporter = File.join(root, "scripts/report-doc-fence-review.rb")
inventory, error, status = Open3.capture3(File.join(root, "scripts/inventory-doc-swift-blocks.rb"), root)
abort error unless status.success?
files = JSON.parse(inventory).fetch("blocks").map { |block| block.fetch("file") }.uniq
files += %w[docs/contracts/doc-swift-fence-review.tsv scripts/check-doc-copyable-examples.rb]
review_path = "docs/contracts/doc-swift-fence-review.tsv"
original_review = File.read(File.join(root, review_path))

def run_reporter(reporter, fixture)
  Open3.capture3("ruby", reporter, "--root", fixture, "--require-complete")
end

Dir.mktmpdir("innoflow-doc-review-selftest-") do |fixture|
  files.each do |relative|
    target = File.join(fixture, relative)
    FileUtils.mkdir_p(File.dirname(target))
    FileUtils.cp(File.join(root, relative), target)
  end
  output, error, status = run_reporter(reporter, fixture)
  abort "[doc-fence-review-selftest] Positive control failed: #{error}" unless
    status.success? && output.include?("pending=0")

  controls = {
    "missing-row" => ->(source) { source.lines.reject { |line| line.start_with?("CLAUDE.md\t") }.join },
    "duplicate-row" => ->(source) { source + source.lines.find { |line| line.start_with?("CLAUDE.md\t") } },
    "stale-digest" => ->(source) { source.sub(/(?<=\t)[0-9a-f]{64}(?=\t)/, "0" * 64) },
    "pending-context" => ->(source) { source.sub("\trunnable\tdoc-copyable-examples", "\tpartial\tcontextual-harness-pending") },
    "unknown-classification" => ->(source) { source.sub("\trunnable\t", "\tapproved\t") },
    "unknown-evidence" => ->(source) { source.sub("\tdoc-copyable-examples", "\tgreen-suite") },
    "historical-current-mixup" => ->(source) {
      source.sub("\trunnable\tdoc-copyable-examples", "\tversioned-historical\tversioned-section-noncopyable")
    },
    "copyable-pair-substitution" => ->(source) {
      source.sub("\tpartial\tdoc-copyable-install-manifest", "\tpartial\tdoc-copyable-examples")
    },
    "sample-proof-substitution" => ->(source) {
      source.sub("\trunnable\tdoc-copyable-examples", "\trunnable\tsample-concurrency-snippet")
    },
  }
  controls.each do |name, mutate|
    changed = mutate.call(original_review)
    abort "[doc-fence-review-selftest] Inert control: #{name}" if changed == original_review
    File.write(File.join(fixture, review_path), changed)
    _output, _error, result = run_reporter(reporter, fixture)
    abort "[doc-fence-review-selftest] Invalid review passed: #{name}" if result.success?
  end
  File.write(File.join(fixture, review_path), original_review)
  File.open(File.join(fixture, "README.md"), "a") { |file| file.puts("\n```swift\nlet unreviewed = 1\n```") }
  _output, _error, result = run_reporter(reporter, fixture)
  abort "[doc-fence-review-selftest] New unreviewed fence passed" if result.success?
end
puts "[doc-fence-review-selftest] Positive control and ten negative controls passed"
