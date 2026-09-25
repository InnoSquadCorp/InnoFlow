#!/usr/bin/env ruby
# frozen_string_literal: true

require "open3"

root = File.expand_path("..", __dir__)
document = File.read(File.join(root, "Examples/InnoFlowSampleApp/CLAUDE.md"))
blocks = document.scan(/^```swift\n(.*?)\n```$/m).flatten
block = blocks.find { |candidate| candidate.include?("final class UserModel: Sendable") }
abort "[sample-concurrency] UserModel guidance is missing" unless block
abort "[sample-concurrency] UserModel must be explicitly main-actor isolated" unless
  block.match?(/@MainActor\s+@Observable\s+final class UserModel: Sendable/)

source = block.split("// Mutable observable UI state", 2).last
abort "[sample-concurrency] UserModel source boundary changed" if source == block
source = "// Mutable observable UI state" + source.split("// Using @unchecked", 2).first
abort "[sample-concurrency] UserModel source boundary changed" unless source.include?("final class UserModel: Sendable")
source = "import Observation\n" + source

def typecheck(source)
  Open3.capture3("swiftc", "-swift-version", "6", "-warnings-as-errors", "-typecheck", "-",
                 stdin_data: source)
end

_stdout, stderr, status = typecheck(source)
abort "[sample-concurrency] Document snippet failed strict typecheck: #{stderr}" unless status.success?
# The selected command-line Swift toolchain may be paired with an older CLT
# macOS SDK while the iOS Simulator SDK belongs to Xcode. Compile complete
# UI/document fences with Xcode's matching compiler and SDK; retain the
# selected-toolchain isolation positive/negative control above.
_stdout, stderr, status = Open3.capture3(
  "xcrun", "--toolchain", "XcodeDefault", "swiftc", "-swift-version", "6",
  "-warnings-as-errors", "-typecheck", "-", stdin_data: block
)
abort "[sample-concurrency] Complete Sendable fence failed strict typecheck: #{stderr}" unless status.success?

negative = source.sub("@MainActor\n", "")
abort "[sample-concurrency] Negative control did not remove isolation" if negative == source
_stdout, stderr, status = typecheck(negative)
abort "[sample-concurrency] Unsafe mutable Sendable control unexpectedly compiled" if status.success?
abort "[sample-concurrency] Negative control failed for another reason: #{stderr}" unless
  stderr.include?("stored property '_name'") && stderr.include?("mutable")

puts "[sample-concurrency] Document snippet and negative control passed"

sdk, error, status = Open3.capture3("xcrun", "--sdk", "iphonesimulator", "--show-sdk-path")
abort "[sample-concurrency] iOS Simulator SDK unavailable: #{error}" unless status.success?

{
  "ModernButton" => "struct ModernButton: View",
  "UserSettings" => "class UserSettings",
  "DataModel" => "class DataModel",
}.each do |label, marker|
  selections = blocks.select { |candidate| candidate.include?(marker) }
  abort "[sample-concurrency] Expected exactly one #{label} fence" unless selections.one?
  %w[18.5 26.0].each do |deployment|
    _output, diagnostic, result = Open3.capture3(
      "xcrun", "--toolchain", "XcodeDefault", "swiftc", "-swift-version", "6",
      "-warnings-as-errors", "-typecheck",
      "-target", "arm64-apple-ios#{deployment}-simulator", "-sdk", sdk.strip, "-",
      stdin_data: selections.first
    )
    abort "[sample-concurrency] #{label} failed iOS #{deployment} typecheck: #{diagnostic}" unless result.success?
  end
end
puts "[sample-concurrency] Three exact SwiftUI fences passed iOS 18.5/26.0 strict typecheck"
