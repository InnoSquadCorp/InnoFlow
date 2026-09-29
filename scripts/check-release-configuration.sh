#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/principle-gates-lib.sh"

# CI already runs the Debug suite in its own job. Keep the Release-only
# contracts independent so both configurations can execute concurrently.
run_with_principle_gate_cleanup run_release_configuration_checks "$@"
