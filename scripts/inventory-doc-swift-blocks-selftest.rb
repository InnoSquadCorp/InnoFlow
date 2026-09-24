#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "tmpdir"

Dir.mktmpdir("innoflow-doc-swift-") do |root|
  File.write(File.join(root, "README.md"), "# Fixture\n```swift\nlet value = 1\n```\n")
  File.write(File.join(root, "NOT_SWIFT.md"), "```bash\necho ignored\n```\n")
  output, error, status = Open3.capture3(File.join(__dir__, "inventory-doc-swift-blocks.rb"), root)
  abort error unless status.success?
  result = JSON.parse(output)
  abort "Swift block inventory is wrong" unless
    result.fetch("blockCount") == 1 && result.fetch("fileCount") == 1 &&
    result.fetch("blocks").first.values_at("file", "line", "firstLine", "classification") ==
      ["README.md", 2, "let value = 1", "unreviewed"]
  File.write(File.join(root, "README.md"), "```swift\nlet value = 1\n")
  _output, _error, status = Open3.capture3(File.join(__dir__, "inventory-doc-swift-blocks.rb"), root)
  abort "Unterminated fence was accepted" if status.success?
  puts "[doc-swift-block-inventory-selftest] discovery and unterminated-fence controls passed"
end
