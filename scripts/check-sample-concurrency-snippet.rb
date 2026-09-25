#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "open3"
require "tmpdir"
require_relative "release-evidence-output-parser"

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

swift_data = blocks.select { |candidate| candidate.include?("@Model\nfinal class Task") }
abort "[sample-concurrency] Expected exactly one SwiftData fence" unless swift_data.one?
swift_data_source = <<~SWIFT + swift_data.first
  import Foundation
  import SwiftUI
  struct ContentView: View { var body: some View { TaskListView() } }
SWIFT
%w[18.5 26.0].each do |deployment|
  _output, diagnostic, result = Open3.capture3(
    "xcrun", "--toolchain", "XcodeDefault", "swiftc", "-swift-version", "6",
    "-warnings-as-errors", "-parse-as-library", "-typecheck",
    "-target", "arm64-apple-ios#{deployment}-simulator", "-sdk", sdk.strip, "-",
    stdin_data: swift_data_source
  )
  abort "[sample-concurrency] SwiftData fence failed iOS #{deployment} typecheck: #{diagnostic}" unless result.success?
end
puts "[sample-concurrency] Contextual SwiftData fence passed iOS 18.5/26.0 strict typecheck"

testing = blocks.select { |candidate| candidate.include?("@Test func userCanLogin()") }
abort "[sample-concurrency] Expected exactly one Swift Testing fence" unless testing.one?
Dir.mktmpdir("innoflow-sample-guide-tests-") do |fixture|
  FileUtils.mkdir_p(File.join(fixture, "Tests", "GuideTests"))
  File.write(File.join(fixture, "Package.swift"), <<~SWIFT)
    // swift-tools-version: 6.3
    import PackageDescription
    let package = Package(name: "SampleGuideTests", platforms: [.macOS(.v15)],
                          targets: [.testTarget(name: "GuideTests")])
  SWIFT
  File.write(File.join(fixture, "Tests", "GuideTests", "GuideTests.swift"), <<~SWIFT + testing.first)
    struct User: Sendable { let name: String }
    struct LoginResult: Sendable { let isSuccess: Bool; let user: User }
    enum AuthError: Error { case invalidCredentials }
    struct AuthService: Sendable {
      func login(username: String, password: String) async throws -> LoginResult {
        guard !username.isEmpty, !password.isEmpty else { throw AuthError.invalidCredentials }
        return LoginResult(isSuccess: true, user: User(name: "Test User"))
      }
    }
  SWIFT
  output, error, status = Open3.capture3(
    { "TOOLCHAINS" => "XcodeDefault" }, "xcrun", "--toolchain", "XcodeDefault", "swift",
    "test", "--package-path", fixture, "--disable-automatic-resolution",
    "--jobs", "1", "--no-parallel", "-Xswiftc", "-warnings-as-errors"
  )
  abort "[sample-concurrency] Swift Testing fence failed: #{output}\n#{error}" unless status.success?
  parsed = ReleaseEvidenceOutputParser.parse({
    "minimumTestCount" => 2,
    "maximumTestCount" => 2,
    "expectedTestNames" => ["userCanLogin()", "User sees error with invalid credentials"],
  }, output + error)
  abort "[sample-concurrency] Swift Testing fence evidence invalid: #{parsed.fetch("failures").join(", ")}" unless
    parsed.fetch("failures").empty?
end
puts "[sample-concurrency] Contextual Swift Testing fence executed two tests"
