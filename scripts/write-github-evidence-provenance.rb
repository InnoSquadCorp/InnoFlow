#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "time"

begin
  run_path, artifacts_path, artifact_name, expected_repository, expected_sha, expected_ref, output = ARGV
  abort "Usage: write-github-evidence-provenance.rb <run-json> <artifacts-json> <artifact-name> <repository> <head-sha> <ref> <output>" if ARGV.length != 7
  run = JSON.parse(File.read(run_path))
  artifacts = JSON.parse(File.read(artifacts_path)).fetch("artifacts")
  named_artifacts = artifacts.select { |item| item["name"] == artifact_name }
  abort "Trusted evidence artifact name must resolve exactly once" unless named_artifacts.one?
  artifact = named_artifacts.first
  abort "Trusted evidence artifact is expired" unless artifact["expired"] == false
  abort "Trusted evidence repository mismatch" unless run.dig("repository", "full_name") == expected_repository
  abort "Trusted evidence head SHA mismatch" unless run["head_sha"] == expected_sha
  abort "Trusted evidence workflow is not complete" unless run["status"] == "completed"
  abort "Trusted evidence workflow did not succeed" unless run["conclusion"] == "success"
  abort "Trusted evidence event must be workflow_dispatch" unless run["event"] == "workflow_dispatch"
  workflow_path, workflow_ref = run.fetch("path").split("@", 2)
  abort "Unapproved evidence producer workflow: #{workflow_path}" unless workflow_path == ".github/workflows/release-evidence.yml"
  abort "Trusted evidence ref is invalid" unless expected_ref.match?(%r{\Arefs/(?:heads|tags)/[^[:space:]]+\z})
  abort "Trusted evidence workflow ref mismatch" if workflow_ref && workflow_ref != expected_ref
  expected_head_branch = expected_ref.sub(%r{\Arefs/(?:heads|tags)/}, "")
  if expected_ref.start_with?("refs/heads/")
    abort "Trusted evidence head branch mismatch" unless run.fetch("head_branch") == expected_head_branch
  end
  digest = artifact["digest"]
  abort "Trusted evidence artifact digest is unavailable" unless digest.to_s.match?(/\Asha256:[0-9a-f]{64}\z/)
  artifact_id = artifact["id"]
  abort "Trusted evidence artifact ID is invalid" unless artifact_id.to_s.match?(/\A[1-9][0-9]*\z/)
  created_at = artifact["created_at"]
  expires_at = artifact["expires_at"]
  abort "Trusted evidence artifact timestamps are unavailable" if created_at.to_s.empty? || expires_at.to_s.empty?
  abort "Trusted evidence artifact expiration is invalid" unless Time.iso8601(expires_at) > Time.iso8601(created_at)
  body = {
    "schema" => "inno-flow-github-actions-producer-v1",
    "repository" => expected_repository,
    "workflowPath" => workflow_path,
    "ref" => expected_ref,
    "headSha" => run.fetch("head_sha"),
    "runId" => run.fetch("id").to_s,
    "runAttempt" => run.fetch("run_attempt").to_s,
    "candidateComponentLabel" => "innoflow",
    "conclusion" => run.fetch("conclusion"),
    "event" => run.fetch("event"),
    "artifactName" => artifact.fetch("name"),
    "artifactId" => artifact_id.to_s,
    "artifactDigest" => digest,
    "artifactExpired" => artifact.fetch("expired"),
    "artifactCreatedAt" => created_at,
    "artifactExpiresAt" => expires_at,
  }
  temporary = "#{output}.tmp.#{$$}"
  File.write(temporary, JSON.pretty_generate(body) + "\n")
  File.rename(temporary, output)
  puts "[write-github-evidence-provenance] OK run=#{body.fetch("runId")}"
rescue JSON::ParserError, KeyError, Errno::ENOENT, ArgumentError => error
  abort "Trusted evidence provenance is invalid: #{error.message}"
end
