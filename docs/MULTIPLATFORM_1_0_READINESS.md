# Multiplatform 1.0 readiness

Status: **local corrected candidate; public release HOLD** (2026-10-18).
Evidence document status is Draft: no maintainer release approval is recorded.
The implementation is intentionally uncommitted/unpublished in
`codex/multiplatform-flow`.

The authoritative [post-fix 63-row ledger](MULTIPLATFORM_FIX_VERIFICATION_2026_10_18.md)
records **58 PASS, 0 FAIL, 3 LIMIT, 2 N/A**. This closes the agreed local
verification scope, not every possible defect or public 1.0 acceptance.
The [pre-fix ledger](MULTIPLATFORM_VERIFICATION_2026_10_18.md) and its sidecars
remain historical evidence; do not use its old input manifest for this candidate.

## Corrected findings

| Finding | Change | Fresh regression |
| --- | --- | --- |
| F1 constructor parent-Job leak | Validate bounded capacity before creating the owned Job | Rejected 0/negative/MAX capacities preserve parent/sibling; valid stores close cleanly; external Maven probe reports children 0 and completed parent join |
| F2 KSP generic-inner rendering | Rebuild each generic owner/inner boundary | 7 new supported-feature fixtures plus existing visibility/name fixtures compile; plain/function/suspend/manual/inner independent consumers pass; 5 unsupported-feature diagnostics remain |
| F3 packed SSR/browser false positives | Compare exact SSR/DOM values, not substrings | Actual normal gate passes; independent SSR 70 and live UI 80 mutants are rejected on both Node versions |
| API26 restoration probe | Require saved STOPPED state, unchanged numeric PID and exact cmdline; same-UID debug PID fallback only when needed | Standard probe passes on API26 and API34; 16 positive/negative safety controls pass |

No Kotlin public ABI baseline changed. Swift source/tests/examples/manifests,
locks, skills and Swift CI still match `origin/main` at
`0a7e685d3749b3dc28c6d5e56b932c9ad7fc0b11`; a fresh remote main read
returned the same SHA. No Swift runtime/release suite was rerun.

## Local evidence

- Final `scripts/test-multiplatform.sh` passed under scoped Node 22.23.3 /
  npm 11.19.0. It includes producer builds, lint, all five ABI gates, local
  Maven publication, independent JVM/AAR consumers, KSP diagnostics,
  AAR wrong-golden controls, exact-SHA evidence negatives, restoration safety
  controls, npm audit, package validation and packed consumer value controls.
- Kotlin unit tests: **28 module/sample tests + 2 independent consumer tests**,
  0 failures/errors/skips. Unit/consumer tests and all five ABI checks also
  passed with `--rerun-tasks`; the broad script can reuse unchanged build outputs.
- TypeScript: **28 tests / 5 files on each of Node 20.19.0 and 22.23.3** after
  clean installs. Seven additional independent probe groups pass on each Node.
- All four Node 20/22 × React 18.2.0/19.2.8 tarball consumers typecheck, build,
  render SSR and exercise hydrated Chromium. Independent exact browser checks
  confirm SSR `7`, live `8 → 9 → 8`, no hydration/page/console errors.
- Android: **3 instrumentation tests on each API26 and API34**. The standard
  restoration probe confirms API34 PID `7446 → 7747` (`am-kill`) and API26
  PID `4158 → 4362` (`same-uid-pid-kill`), exact visible `Count: 2`,
  saved-state evidence, screenshots/XML and empty crash buffers. Only owned
  emulators were used and both were closed after completion.
- Workflows: pinned actionlint 1.7.12 checks all 18 definitions; action pins,
  timeouts, trust boundaries and exact-SHA checker (normal + 10 negatives) pass.
- Dependency-advisory scope: npm audit 0 known issues; 38 resolved Maven
  runtime coordinates across the 5 published modules have 0 OSV matches.
  A known-vulnerable query-only control returns 6 advisories. This is not a
  build/test/plugin dependency scan or repository-wide security audit.

Raw evidence: `/tmp/innoflow-fixes-20261018.evgcyvL1`.
Durable input identities, result JSON and reproduction instructions:
[post-fix evidence](verification/2026-10-18-fixes/README.md).

## Remaining release gates and exclusions

| Ledger | Not yet proven | Required next evidence |
| --- | --- | --- |
| A06 | Hosted API23/35 runtime | Actual device jobs for the final committed candidate; local API26/34 is not a substitute |
| C06 | Exact-SHA main-push CI | Successful Multiplatform CI on the eventual tagged main SHA, including device/browser jobs |
| C07 | Registry-only installation/publication | Explicit maintainer approval, registry permissions/credentials, publication and fresh remote-only consumers |

No commit, push, tag, Release, npm or GitHub Packages publication occurred.
Registry availability and production operations have not been demonstrated.

Swift runtime validation is explicitly N/A under the CI-only/main-preservation
boundary, not a pass inferred from unchanged files. Physical devices, other
browser engines, React Native runtime validation, arbitrary compiler versions,
automatic persistence, global effect caps, forced termination of uncooperative
I/O, long soak and deep security audit remain excluded.
Optional pre-existing timeout-domain documentation, FlowFeature-supertype alias
support and wrapper refresh proposals remain separate from these four fixes.

The release-evidence structure separates implementation/test/build from
publication/approval/operation; a green local matrix does not grant release
approval. Use [RELEASING_MULTIPLATFORM.md](RELEASING_MULTIPLATFORM.md) for the
next gates. No absence-of-defects claim is made.
