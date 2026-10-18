# Hosted verification evidence — 2026-10-18

Canonical result: [hosted ledger](../../MULTIPLATFORM_HOSTED_VERIFICATION_2026_10_18.md).
Document approval remains Draft. Publication was explicitly forbidden and was
not performed. This directory preserves, rather than overwrites, both older
local evidence directories and both failed hosted candidates.

## Candidate and run identity

| Phase | Source commit | Run | Result |
| --- | --- | --- | --- |
| initial | `f4016461031468a7ebc372a47d256aa8e95bb2e0` | [39108493753](https://github.com/InnoSquadCorp/InnoFlow/actions/runs/39108493753) | FAIL: API23 tty hierarchy absent before process kill; other five jobs passed |
| probe | `d405d71f73c55e8b82690cc10800161275a354f1` | [39109230600](https://github.com/InnoSquadCorp/InnoFlow/actions/runs/39109230600) | FAIL: fresh UI file worked; API23 all-PID pidof response rejected before kill; other five jobs passed |
| pid | `a3b1f06cbdd0aa22e883627e4198d8f6c646ea16` | [39109770382](https://github.com/InnoSquadCorp/InnoFlow/actions/runs/39109770382) | PASS: six jobs, five artifact ZIP digests, actual device/consumer evidence independently checked |

All three are attempt1 push events on `codex/multiplatform-flow`, not main or
release runs. `run-*.json`, `jobs-*.json`, `artifacts-*.json` retain original
GitHub metadata; `verified-*.json` retain independently parsed decisions.
Exact checkout SHAs were also checked in all six job logs for every run.

- `candidate-inputs.sha256`: 130 current runtime/build/contract/CI/shared paths,
  SHA-256 `2890afe7f0826aa0a28563de31089077ac234939d75330b7c7217c81802ff3fe`.
- `candidate-initial.sha256`, `candidate-ui-file.sha256`: the distinct first
  and second source candidates. They are historical manifests, not checksums
  expected to pass against the corrected working tree.
- `evidence.sha256`: this directory's durable evidence bytes, excluding itself.
  Source manifests exclude prose/results/images to avoid self-reference.
- A later evidence-only commit has a different SHA. Its 130 source inputs must
  be identical and its own CI must be checked separately; the run above is
  never presented as a run of that later SHA.

## What is retained

- `android-api23/35.json`, `*-ui.xml`, `*.png`: distinct PIDs, exact restored
  count, method and actual visible UI. API23 is `3087 → 3297`; API35 is
  `4581 → 4754`, both `am-kill`, initial0/restored2.
- `android-api23/35-compose.xml` and `*-sample.xml`: two Compose lifecycle
  cases plus one recreation case per API, zero failure/error/skip. These are
  real instrumentation cases, not merely successful APK assembly.
- `android-api23/35-raw.json`: raw tty/file status, saved STOPPED dumps,
  legacy ps/PID/cmdline records, device fingerprints and empty crash buffers.
  Each original UTF-8 text is encoded as a JSON string with its original byte
  SHA-256; escaping does not discard its whitespace. API23 uses fresh UI-file
  fallback and exact ps NAME + own-UID cmdline. API35 uses tty/modern pidof.
- `unit-*.xml`: eight original reports, 28 module/sample + 2 independent
  JVM/AAR consumer cases, zero failure/error/skip. Hosted unit task results
  were partly `FROM-CACHE`; they are not all fresh JVM execution. Device,
  Node and 32 probe controls ran anew. Previous same-runtime local
  `--rerun-tasks` evidence remains in the historical post-fix directory.
- `node*-raw-logs.json` and React18/19/wrong-browser screenshots: original
  Node 28-test/5-file unit/package logs, four actual tarball SSR/hydration/browser
  consumers, normal controls and specifically rejected SSR70/browser80
  mutants. These are not workspace-alias-only consumers.
- `checks-*.log`: selected job-log lines with ANSI removed and line endings
  trimmed for readability, explicitly not complete raw logs.
- `raw-log-identities.json`: complete downloaded job-log byte sizes/hashes.
  Full raw logs and original artifact ZIPs remain at
  `/tmp/innoflow-hosted-20261018.CTW177i3`; scratch paths are not durable storage.
  Original remote artifact IDs, expiry and SHA-256 digests remain in metadata
  and verified reports, including both failed runs.
- `local-controls.json`: the license-equality RED, focused legacy PID RED
  and 32-control GREEN transcripts. Device success is proven separately.
- `verify-hosted.py`: the independent acceptance verifier used for the three
  remote runs. It does not publish or modify production source.

## Reproduction and checksums

From the repository root:

```bash
shasum -a 256 -c docs/verification/2026-10-18-hosted/candidate-inputs.sha256
shasum -a 256 -c docs/verification/2026-10-18-hosted/evidence.sha256
python3 scripts/check-android-restoration-selftest.py
```

The last command runs 32 device-free controls, not device restoration. To
repeat hosted validation, push an approved candidate on this branch and
inspect its own `Multiplatform CI`; never reuse a different commit's result.
The workflow creates fresh API23/35 x86_64 emulators, asserts actual SDK,
runs instrumentation serially, then runs the standard restoration probe.

For an independent replay of this archive's acceptance, use an isolated
scratch directory. Copy `verify-hosted.py` and the run/jobs/artifacts metadata
there. For each phase (`initial`, `probe`, `pid`), download the full log:

```bash
gh run view RUN_ID --repo InnoSquadCorp/InnoFlow --log > PHASE-all-jobs.log
```

For each artifact listed in that phase's metadata, download its original ZIP
as `artifact-ID.zip`, verify SHA-256 equals GitHub's `digest`, and safely
extract under `artifacts-PHASE/ARTIFACT_NAME/`. Do not accept absolute paths
or parent-directory traversal entries. The original ZIP request is:

```bash
gh api repos/InnoSquadCorp/InnoFlow/actions/artifacts/ID/zip > artifact-ID.zip
```

Run the copied verifier inside that scratch directory:

```bash
python3 verify-hosted.py initial f4016461031468a7ebc372a47d256aa8e95bb2e0 --allow-failed-run
python3 verify-hosted.py probe d405d71f73c55e8b82690cc10800161275a354f1 --allow-failed-run
python3 verify-hosted.py pid a3b1f06cbdd0aa22e883627e4198d8f6c646ea16
```

The first two calls deliberately preserve overall failure; they cannot grant
PASS to missing process-restoration evidence. The last requires all six jobs,
all five correct artifact digests, actual testcase counts, exact consumers,
different PIDs, saved STOPPED state, Count2/no ANR and empty app crash buffers.
It also verifies 32 controls and source identity, not just the overall green.
Remote artifact expiry may prevent a full ZIP replay later; the selected
durable evidence here and original metadata remain explicit about that limit.

## Release and preservation boundary

Implementation/source parity was checked after each push before the specified
XcodeBuildMCP cleanup. Main remains
`0a7e685d3749b3dc28c6d5e56b932c9ad7fc0b11`; Swift source/tests/examples,
manifests/locks/skills/Swift CI match it. The original dirty Swift checkout was
not edited. Existing local evidence directories are unchanged.

Branch-hosted execution is PASS and A06 is closed. C06's separate **main-push
release eligibility** is still LIMIT, as is C07 registry-only publication and
approval. No helper was weakened, no main merge/push, tag, GitHub Release,
npm or GitHub Packages publication was performed. Swift runtime, physical
devices, other browser engines, RN, long soak and deep security remain outside
this bounded validation. A green result does not prove absence of all defects.
