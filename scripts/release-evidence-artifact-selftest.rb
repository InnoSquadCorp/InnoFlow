#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "tmpdir"

source = File.join(__dir__, "release-evidence-tool.rb")
# Exercise the production manifest functions without invoking the CLI dispatcher.
eval(File.read(source).split(/^command_name = /, 2).first, TOPLEVEL_BINDING, source)

def rejects_artifact?(path)
  child = fork do
    artifact_manifest(path)
  end
  _, status = Process.wait2(child)
  !status.success?
end

def rejects_artifact_unchanged?(path, initial_entries)
  child = fork do
    assert_artifact_unchanged!(path, initial_entries)
  end
  _, status = Process.wait2(child)
  !status.success?
end

Dir.mktmpdir("innoflow-artifact-selftest-") do |root|
  artifact = File.join(root, "artifact")
  outside = File.join(root, "outside")
  FileUtils.mkdir_p([File.join(artifact, "nested"), outside])
  File.write(File.join(artifact, "nested", "normal.txt"), "normal")
  File.write(File.join(outside, "foreign.txt"), "foreign")

  normal = artifact_manifest(artifact)
  abort "ordinary nested artifact was rejected" unless normal.map { |entry| entry.fetch("path") } == ["nested/", "nested/normal.txt"]
  abort "ordinary artifact digest changed" unless artifact_digest(normal) == artifact_digest(artifact_manifest(artifact))
  abort "ordinary file artifact was rejected" unless artifact_manifest(File.join(artifact, "nested", "normal.txt")).length == 1
  hidden = File.join(artifact, "nested", ".hidden")
  File.write(hidden, "hidden")
  abort "hidden artifact file was skipped" unless artifact_manifest(artifact).any? { |entry| entry["path"] == "nested/.hidden" }
  File.unlink(hidden)
  file_path = File.join(artifact, "nested", "normal.txt")
  File.write(file_path, "modmal")
  abort "same-size artifact replacement was accepted" unless rejects_artifact_unchanged?(artifact, normal)
  File.write(file_path, "normal")
  empty = File.join(artifact, "empty")
  Dir.mkdir(empty)
  abort "empty directory addition did not change artifact digest" if
    artifact_digest(normal) == artifact_digest(artifact_manifest(artifact))
  Dir.rmdir(empty)

  fifo = File.join(artifact, "nested", "unsupported-fifo")
  abort "Could not create unsupported FIFO fixture" unless system("mkfifo", fifo)
  abort "unsupported artifact file type was accepted" unless rejects_artifact?(artifact)
  File.unlink(fifo)

  cases = {
    "directory symlink outside" => [outside, File.join(artifact, "linked-directory")],
    "relative directory symlink" => ["nested", File.join(artifact, "relative-directory")],
    "file symlink" => [File.join(outside, "foreign.txt"), File.join(artifact, "linked-file")],
    "broken symlink" => [File.join(outside, "missing"), File.join(artifact, "broken")],
    "cycle symlink" => [".", File.join(artifact, "cycle")],
  }
  cases.each do |name, (target, link)|
    File.symlink(target, link)
    abort "#{name} was accepted" unless rejects_artifact?(artifact)
    File.unlink(link)
  end

  root_link = File.join(root, "artifact-link")
  File.symlink(artifact, root_link)
  abort "root directory symlink was accepted" unless rejects_artifact?(root_link)
  File.unlink(root_link)
  File.symlink(File.join(artifact, "nested", "normal.txt"), root_link)
  abort "root file symlink was accepted" unless rejects_artifact?(root_link)

  puts "[release-evidence-artifact-selftest] Nested files accepted; root/nested links rejected"
end
