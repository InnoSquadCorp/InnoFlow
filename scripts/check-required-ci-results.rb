#!/usr/bin/env ruby
# frozen_string_literal: true

REQUIRED_JOBS = %w[
  coverage
  lint
  tests
  release-tests
  api-compatibility
  thread-sanitizer
  sample-tests
  package-builds
  focused-runtime-tests
  principle-gates
  sample-package-builds
  sample-build
  address-sanitizer
  sample-ui-tests
].freeze
VALID_RESULTS = %w[success failure cancelled skipped].freeze

event = ARGV.shift.to_s
abort "Usage: check-required-ci-results.rb <push|pull_request> job=result ..." unless %w[push pull_request].include?(event)

results = {}
ARGV.each do |argument|
  name, value = argument.split("=", 2)
  abort "[ci-required] Invalid result argument: #{argument}" if name.to_s.empty? || value.to_s.empty?
  abort "[ci-required] Duplicate result: #{name}" if results.key?(name)
  abort "[ci-required] Unknown result value for #{name}: #{value}" unless VALID_RESULTS.include?(value)
  results[name] = value
end

missing = REQUIRED_JOBS - results.keys
unknown = results.keys - REQUIRED_JOBS
abort "[ci-required] Missing results: #{missing.join(", ")}" unless missing.empty?
abort "[ci-required] Unknown jobs: #{unknown.join(", ")}" unless unknown.empty?

failures = REQUIRED_JOBS.filter_map do |name|
  value = results.fetch(name)
  next if value == "success"
  next if event == "pull_request" && name == "address-sanitizer" && value == "skipped"
  "#{name}=#{value}"
end
abort "[ci-required] Required jobs did not succeed: #{failures.join(", ")}" unless failures.empty?

puts "[ci-required] All required #{event} jobs satisfied the final gate"
