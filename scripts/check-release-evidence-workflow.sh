#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd_workflow="${1:-$script_dir/../.github/workflows/cd.yml}"
producer_workflow="${2:-$script_dir/../.github/workflows/release-evidence.yml}"
"$script_dir/check-release-evidence-workflow.rb" "$cd_workflow" "$producer_workflow"
