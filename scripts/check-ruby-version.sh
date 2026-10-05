#!/usr/bin/env bash
set -euo pipefail
if ! command -v ruby >/dev/null 2>&1; then
  echo '[ruby] Ruby >= 2.7 is required for InnoFlow validation. Install a current Ruby and put it on PATH.' >&2
  exit 1
fi
if ! ruby -e 'parts = RUBY_VERSION.split(".").map(&:to_i); exit((parts <=> [2, 7, 0]) >= 0 ? 0 : 1)'; then
  echo "[ruby] Ruby >= 2.7 is required; found $(ruby --version). Put a supported Ruby on PATH before running principle gates." >&2
  exit 1
fi
