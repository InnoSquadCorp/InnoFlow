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

  File.write(File.join(root, "README.md"), "# Fixture\n```swift\nlet value = 1\n```\n")
  File.write(File.join(root, "GUIDE.md"), "```swift\nlet value = 2\n```\n")
  File.write(File.join(root, ".gitignore"), ".build/\n")
  FileUtils.mkdir_p(File.join(root, ".build"))
  File.write(File.join(root, ".build", "ignored.md"), "```swift\nlet ignored = 3\n```\n")
  _output, error, status = Open3.capture3("git", "-C", root, "init", "-q")
  abort error unless status.success?
  _output, error, status = Open3.capture3("git", "-C", root, "add", "README.md", ".gitignore")
  abort error unless status.success?
  output, error, status = Open3.capture3(File.join(__dir__, "inventory-doc-swift-blocks.rb"), root)
  abort error unless status.success?
  result = JSON.parse(output)
  abort "Git inventory omitted untracked docs or included ignored build output" unless
    result.fetch("blockCount") == 2 && result.fetch("fileCount") == 2 &&
    result.fetch("blocks").map { |block| block.fetch("file") } == ["GUIDE.md", "README.md"]

  puts "[doc-swift-block-inventory-selftest] standalone, Git, ignore, and unterminated-fence controls passed"
end
