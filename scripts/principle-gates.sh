#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$SCRIPT_DIR/check-ruby-version.sh"
source "$SCRIPT_DIR/principle-gates-lib.sh"

run_principle_gates "$@"
