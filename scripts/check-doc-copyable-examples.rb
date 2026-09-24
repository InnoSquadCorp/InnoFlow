#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "tmpdir"

root = File.realpath(File.expand_path("..", __dir__))
examples = {
  "DocCGettingStarted" => [
    ["Sources/InnoFlow/InnoFlow.docc/GettingStarted.md", "1b62fc406dd87ce9f32e91f92cba368c4548427022a85a9bad2366def7487951"],
  ],
  "ReadmeDependencyInjection" => [
    ["README.md", "d6799f402603bfa90bfa249d399e7821517b7e91a74929bd28d2d98321e8242f"],
  ],
  "PhaseGuideFeature" => [
    ["PHASE_DRIVEN_MODELING.md", "5a1c5fa991819e6afab1e975945498539caf63634d0f610a9219374d1023b85c"],
  ],
  "DocCPhaseFeature" => [
    ["Sources/InnoFlow/InnoFlow.docc/PhaseDrivenModeling.md", "37aef6225e84c59299e8d44290b6ae2c47befee5ddf9457bb0681ddf7fc83552"],
  ],
  "ReadmeEnglish" => [
    ["README.md", "a14d2c9dce587f7877a2a9b58820ffe2f45314e2ae4f35fe1a6a2ff7a5ac2399"],
    ["README.md", "bad2b5cb67df16db6252b825451065a2c0a6d1786ab4cdcef15ad6cffcd09475"],
  ],
  "ReadmeKorean" => [
    ["README.kr.md", "dc7f9a836da4c857e0443ab46b240a9d9ff6ca904f4e7b98a48636044ea12759"],
    ["README.kr.md", "dedbc2f5bfb98fee0406b0224e27c798c6e5b1116cef5a250bc76c1f0a41f706"],
  ],
  "ReadmeJapanese" => [
    ["README.jp.md", "dc7f9a836da4c857e0443ab46b240a9d9ff6ca904f4e7b98a48636044ea12759"],
    ["README.jp.md", "dedbc2f5bfb98fee0406b0224e27c798c6e5b1116cef5a250bc76c1f0a41f706"],
  ],
  "ReadmeChinese" => [
    ["README.cn.md", "dc7f9a836da4c857e0443ab46b240a9d9ff6ca904f4e7b98a48636044ea12759"],
    ["README.cn.md", "dedbc2f5bfb98fee0406b0224e27c798c6e5b1116cef5a250bc76c1f0a41f706"],
  ],
}

def swift_blocks(root, relative)
  lines = File.readlines(File.join(root, relative))
  blocks = []
  index = 0
  while index < lines.length
    unless lines[index].match?(/^```[sS]wift(?:\s.*)?$/)
      index += 1
      next
    end
    index += 1
    content = []
    while index < lines.length && !lines[index].match?(/^```\s*$/)
      content << lines[index]
      index += 1
    end
    abort "[doc-copyable] Unterminated Swift fence in #{relative}" if index == lines.length
    source = content.join
    blocks << [Digest::SHA256.hexdigest(source), source]
    index += 1
  end
  blocks
end

selected = examples.values.flatten(1).map(&:first).uniq.to_h { |relative| [relative, swift_blocks(root, relative)] }
fixture = Dir.mktmpdir("innoflow-doc-copyable-")
begin
  package = <<~SWIFT
    // swift-tools-version: 6.3
    import PackageDescription

    let package = Package(
      name: "InnoFlowDocCopyable",
      platforms: [.macOS(.v15)],
      dependencies: [.package(name: "InnoFlow", path: #{root.inspect})],
      targets: [
  SWIFT
  examples.each do |name, selections|
    sources = selections.map do |relative, digest|
      matches = selected.fetch(relative).select { |sha, _source| sha == digest }
      abort "[doc-copyable] Missing or ambiguous reviewed fence: #{relative} #{digest}" unless matches.one?
      matches.first.last
    end
    case name
    when "PhaseGuideFeature"
      sources.unshift(<<~SWIFT)
        struct UserProfile: Equatable, Sendable {
          static let fixture = Self()
        }
      SWIFT
    when "DocCPhaseFeature"
      sources.unshift(<<~SWIFT)
        import InnoFlow
        struct Item: Equatable, Sendable {}
      SWIFT
    end
    if name.start_with?("Readme") && name != "ReadmeEnglish"
      if name == "ReadmeDependencyInjection"
        sources.unshift(<<~SWIFT)
          protocol APIClientProtocol: Sendable {
            func fetchName() async throws -> String
          }
          struct APIClient: APIClientProtocol {
            static let live = Self()
            func fetchName() async throws -> String { "Ada" }
          }
          protocol LoggerProtocol: Sendable {
            func log(_ message: String)
          }
          struct Logger: LoggerProtocol {
            static let live = Self()
            func log(_ message: String) {}
          }
        SWIFT
      else
        feature, stepper = sources
        sources = [feature, <<~SWIFT]
          import InnoFlowSwiftUI
          import SwiftUI

          struct LocalizedExampleView: View {
            @State private var store = Store(reducer: CounterFeature())

            var body: some View {
          #{stepper.lines.map { |line| "    #{line}" }.join.rstrip}
            }
          }
        SWIFT
      end
    end
    source_directory = File.join(fixture, "Sources", name)
    FileUtils.mkdir_p(source_directory)
    File.write(File.join(source_directory, "Example.swift"), sources.join("\n"))
    package << <<~SWIFT
        .target(name: "#{name}", dependencies: [
          .product(name: "InnoFlow", package: "InnoFlow"),
          .product(name: "InnoFlowSwiftUI", package: "InnoFlow"),
        ]),
    SWIFT
  end
  package << "  ]\n)\n"
  File.write(File.join(fixture, "Package.swift"), package)
  FileUtils.cp(File.join(root, "Package.resolved"), File.join(fixture, "Package.resolved"))
  output, error, status = Open3.capture3("swift", "build", "--package-path", fixture,
    "--disable-automatic-resolution", "--jobs", "1",
    "-Xswiftc", "-warnings-as-errors")
  print output
  warn error unless error.empty?
  abort "[doc-copyable] External package build failed" unless status.success?
  puts "[doc-copyable] Compiled #{examples.length} external targets from #{examples.values.sum(&:length)} exact Swift fences"
ensure
  if ENV["INNOFLOW_KEEP_DOC_FIXTURE"] == "1"
    warn "[doc-copyable] Preserved fixture: #{fixture}"
  else
    FileUtils.remove_entry(fixture)
  end
end
