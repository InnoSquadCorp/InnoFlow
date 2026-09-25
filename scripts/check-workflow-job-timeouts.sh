#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKFLOW_DIR="${1:-$ROOT_DIR/.github/workflows}"

if [[ ! -d "$WORKFLOW_DIR" ]]; then
  echo "[workflow-job-timeouts] Missing workflow directory: $WORKFLOW_DIR" >&2
  exit 2
fi

ruby - "$WORKFLOW_DIR" <<'RUBY'
require "yaml"

workflow_dir = ARGV.fetch(0)
failures = []
Dir.glob(File.join(workflow_dir, "*.{yml,yaml}")).sort.each do |path|
  document = YAML.safe_load(File.read(path), aliases: true) || {}
  jobs = document.fetch("jobs", {})
  jobs.each do |name, job|
    # GitHub forbids timeout-minutes on a reusable-workflow caller. Local
    # callees are scanned independently below and must bound every runner job.
    if job.is_a?(Hash) && job["uses"]
      callee = job["uses"]
      unless callee.is_a?(String) && callee.match?(/\A\.\/\.github\/workflows\/[^\/]+\.ya?ml\z/) &&
          File.file?(File.join(workflow_dir, File.basename(callee))) &&
          !job.key?("runs-on") && !job.key?("steps") && !job.key?("timeout-minutes")
        failures << "#{File.basename(path)} job '#{name}' has an invalid or unbounded reusable workflow"
      end
      next
    end
    timeout = job.is_a?(Hash) ? job["timeout-minutes"] : nil
    unless timeout.is_a?(Integer) && timeout.positive?
      failures << "#{File.basename(path)} job '#{name}' must declare a positive integer timeout-minutes"
    end
  end
end

unless failures.empty?
  failures.each { |failure| warn "[workflow-job-timeouts] #{failure}" }
  exit 1
end
RUBY

echo "[workflow-job-timeouts] Every runner job has a positive timeout; local reusable callees resolve"
