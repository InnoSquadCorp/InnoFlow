#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 --check-id <id> --candidate-hash <sha256> --candidate-snapshot <json> --repository <label=path>... --component-label <label> --evidence-root <dir> --manifest <relative-tsv-path> --artifact <relative-log-path> --receipt <relative-json-path> --toolchain <description> [--attempt-id <id>] [--attempt-index <relative-tsv-path>] [--raw-artifact <relative-xcresult-path>] [--environment-json <json>] [--producer-json <json>] [--policy <json>] -- <command> [args...]"
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
policy="$script_dir/../docs/contracts/release-evidence-policy.json"
check_id=""; candidate_hash=""; candidate_snapshot=""; evidence_root=""
artifact_relative=""; receipt_relative=""; raw_artifact=""; toolchain=""; environment_json="{}"; producer_json=""
component_label=""; manifest_relative=""
attempt_id=""; attempt_index_relative="attempts.tsv"
repositories=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check-id) check_id="${2:-}"; shift 2 ;;
    --candidate-hash) candidate_hash="${2:-}"; shift 2 ;;
    --candidate-snapshot) candidate_snapshot="${2:-}"; shift 2 ;;
    --repository) repositories+=("${2:-}"); shift 2 ;;
    --component-label) component_label="${2:-}"; shift 2 ;;
    --evidence-root) evidence_root="${2:-}"; shift 2 ;;
    --manifest) manifest_relative="${2:-}"; shift 2 ;;
    --attempt-id) attempt_id="${2:-}"; shift 2 ;;
    --attempt-index) attempt_index_relative="${2:-}"; shift 2 ;;
    --artifact) artifact_relative="${2:-}"; shift 2 ;;
    --receipt) receipt_relative="${2:-}"; shift 2 ;;
    --raw-artifact) raw_artifact="${2:-}"; shift 2 ;;
    --toolchain) toolchain="${2:-}"; shift 2 ;;
    --environment-json) environment_json="${2:-}"; shift 2 ;;
    --producer-json) producer_json="${2:-}"; shift 2 ;;
    --policy) policy="${2:-}"; shift 2 ;;
    --) shift; break ;;
    *) usage; exit 64 ;;
  esac
done
if [[ -z "$check_id" || -z "$candidate_hash" || -z "$candidate_snapshot" || ${#repositories[@]} -eq 0 || -z "$component_label" || -z "$evidence_root" || -z "$manifest_relative" || -z "$artifact_relative" || -z "$receipt_relative" || -z "$toolchain" || $# -eq 0 ]]; then
  usage
  exit 64
fi

component_path=""
snapshot_arguments=(--policy "$policy")
for repository in "${repositories[@]}"; do
  if [[ "$repository" != *=* || -z "${repository%%=*}" || -z "${repository#*=}" ]]; then
    echo "Repository must use label=path: $repository" >&2
    exit 64
  fi
  snapshot_arguments+=(--repository "$repository")
  if [[ "${repository%%=*}" == "$component_label" ]]; then
    component_path="${repository#*=}"
  fi
done
if [[ -z "$component_path" ]]; then
  echo "Component label is not present in --repository values: $component_label" >&2
  exit 64
fi
component_path="$(cd "$component_path" && pwd -P)"
working_directory="$(pwd -P)"
if [[ "$working_directory" != "$component_path" ]]; then
  echo "Evidence command must run from component root $component_path (current: $working_directory)" >&2
  exit 64
fi

safe_relative() {
  case "$1" in ""|/*|..|../*|*/../*|*/..) return 1 ;; esac
}
safe_relative "$artifact_relative" || { echo "Artifact path must remain inside the evidence root" >&2; exit 64; }
safe_relative "$receipt_relative" || { echo "Receipt path must remain inside the evidence root" >&2; exit 64; }
safe_relative "$attempt_index_relative" || { echo "Attempt index path must remain inside the evidence root" >&2; exit 64; }
mkdir -p "$evidence_root"
attempt_id="${attempt_id:-${check_id}-$(date -u +%Y%m%dT%H%M%SZ)-$$-${RANDOM}}"
case "$attempt_id" in *[!A-Za-z0-9._-]*|"") echo "Attempt ID is invalid" >&2; exit 64 ;; esac
evidence_command=("$@")
started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

record_attempt() {
  local status="$1" exit_value="$2" detail_json="$3"
  local finished_value
  finished_value="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local attempt_arguments=(
    record-attempt --policy "$policy" --check-id "$check_id"
    --candidate "$candidate_hash" --attempt-id "$attempt_id" --status "$status"
    --evidence-root "$evidence_root" --attempt-index "$attempt_index_relative"
    --component-label "$component_label" --working-directory "$working_directory"
    --started-at "$started_at" --finished-at "$finished_value" --detail-json "$detail_json"
  )
  [[ -z "$exit_value" ]] || attempt_arguments+=(--exit-code "$exit_value")
  [[ ! -e "$evidence_root/$artifact_relative" ]] || attempt_arguments+=(--artifact "$artifact_relative")
  [[ ! -e "$evidence_root/$receipt_relative" ]] || attempt_arguments+=(--receipt "$receipt_relative")
  "$script_dir/release-evidence-tool.rb" "${attempt_arguments[@]}" -- "${evidence_command[@]}" >/dev/null
}

blocked() {
  local message="$1" exit_value="${2:-1}"
  echo "$message" >&2
  record_attempt BLOCKED "$exit_value" '{}' || echo "Failed to preserve BLOCKED attempt $attempt_id" >&2
  exit "$exit_value"
}

current_candidate() {
  "$script_dir/release-candidate-snapshot.rb" "${snapshot_arguments[@]}" --digest-only
}

set +e
before_candidate="$(current_candidate)"
snapshot_exit=$?
set -e
[[ $snapshot_exit -eq 0 ]] || blocked "Candidate snapshot computation failed before evidence execution" "$snapshot_exit"
if [[ "$before_candidate" != "$candidate_hash" ]]; then
  blocked "Candidate changed before evidence execution: expected $candidate_hash, got $before_candidate"
fi

set +e
"$script_dir/release-evidence-tool.rb" validate-command --policy "$policy" --check-id "$check_id" \
  --candidate "$candidate_hash" --candidate-snapshot "$candidate_snapshot" \
  --component-label "$component_label" -- "$@" >/dev/null
validation_exit=$?
set -e
[[ $validation_exit -eq 0 ]] || blocked "Evidence command validation failed" "$validation_exit"

if [[ -n "$raw_artifact" ]]; then
  safe_relative "$raw_artifact" || blocked "Raw artifact path must remain inside the evidence root" 64
  raw_absolute="$(ruby -e 'puts File.expand_path(ARGV.fetch(0), ARGV.fetch(1))' "$raw_artifact" "$evidence_root")"
  if [[ -e "$raw_absolute" || -L "$raw_absolute" ]]; then
    blocked "Raw result must not predate this evidence attempt: $raw_artifact"
  fi
  result_bundle_values=()
  command_arguments=("$@")
  for ((index = 0; index < ${#command_arguments[@]}; index += 1)); do
    argument="${command_arguments[$index]}"
    if [[ "$argument" == "-resultBundlePath" || "$argument" == "--result-bundle-path" || "$argument" == "--result-bundle" ]]; then
      ((index + 1 < ${#command_arguments[@]})) || blocked "-resultBundlePath is missing its value" 64
      result_bundle_values+=("${command_arguments[$((index + 1))]}")
      index=$((index + 1))
    elif [[ "$argument" == -resultBundlePath=* ]]; then
      result_bundle_values+=("${argument#-resultBundlePath=}")
    elif [[ "$argument" == --result-bundle-path=* ]]; then
      result_bundle_values+=("${argument#--result-bundle-path=}")
    elif [[ "$argument" == --result-bundle=* ]]; then
      result_bundle_values+=("${argument#--result-bundle=}")
    fi
  done
  if [[ ${#result_bundle_values[@]} -ne 1 ]]; then
    blocked "xcresult evidence commands must provide exactly one -resultBundlePath" 64
  fi
  command_raw_absolute="$(ruby -e 'puts File.expand_path(ARGV.fetch(0), ARGV.fetch(1))' "${result_bundle_values[0]}" "$working_directory")"
  if [[ "$command_raw_absolute" != "$raw_absolute" ]]; then
    blocked "Raw artifact does not match the command result bundle path" 64
  fi
  mkdir -p "$(dirname "$raw_absolute")"
fi

mkdir -p "$evidence_root/$(dirname "$artifact_relative")"
artifact="$evidence_root/$artifact_relative"
if [[ -e "$artifact" || -L "$artifact" || -e "$evidence_root/$receipt_relative" || -L "$evidence_root/$receipt_relative" ]]; then
  blocked "Evidence artifact or receipt already exists for this attempt"
fi
interrupted() {
  local signal="$1" code="$2"
  trap - INT TERM HUP
  record_attempt INTERRUPTED "$code" "{\"signal\":\"$signal\"}" || echo "Failed to preserve INTERRUPTED attempt $attempt_id" >&2
  exit "$code"
}
trap 'interrupted INT 130' INT
trap 'interrupted TERM 143' TERM
trap 'interrupted HUP 129' HUP
set +e
"$@" >"$artifact" 2>&1
exit_code=$?
set -e
finished_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
trap - INT TERM HUP
if [[ $exit_code -ne 0 ]]; then
  record_attempt FAIL "$exit_code" '{}'
  exit "$exit_code"
fi

after_candidate="$(current_candidate)"
if [[ "$after_candidate" != "$candidate_hash" ]]; then
  blocked "Candidate changed during evidence execution: expected $candidate_hash, got $after_candidate"
fi

arguments=(
  record-automated --policy "$policy" --check-id "$check_id"
  --candidate "$candidate_hash" --candidate-snapshot "$candidate_snapshot"
  --evidence-root "$evidence_root" --artifact "$artifact_relative"
  --receipt "$receipt_relative" --exit-code "$exit_code" --toolchain "$toolchain"
  --environment-json "$environment_json"
  --component-label "$component_label" --working-directory "$working_directory"
  --started-at "$started_at" --finished-at "$finished_at"
  --attempt-id "$attempt_id"
)
if [[ -n "$raw_artifact" ]]; then
  arguments+=(--raw-artifact "$raw_artifact")
fi
if [[ -n "$producer_json" ]]; then
  arguments+=(--producer-json "$producer_json")
fi
set +e
"$script_dir/release-evidence-tool.rb" "${arguments[@]}" -- "$@" >/dev/null
record_exit=$?
set -e
if [[ $record_exit -ne 0 ]]; then
  record_attempt FAIL "$record_exit" '{"phase":"receipt-validation"}'
  exit "$record_exit"
fi
set +e
manifest_row="$("$script_dir/release-evidence-tool.rb" upsert-manifest --policy "$policy" \
  --check-id "$check_id" --candidate "$candidate_hash" \
  --candidate-snapshot "$candidate_snapshot" --evidence-root "$evidence_root" \
  --manifest "$manifest_relative" --receipt "$receipt_relative")"
manifest_exit=$?
set -e
if [[ $manifest_exit -ne 0 ]]; then
  record_attempt FAIL "$manifest_exit" '{"phase":"manifest-update"}'
  exit "$manifest_exit"
fi
record_attempt PASS 0 '{}'
printf '%s\n' "$manifest_row"
