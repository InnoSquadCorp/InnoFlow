# Multiplatform 1.0 readiness

Status: **committed, pushed and hosted-verified candidate; public release HOLD** (2026-10-18).
Evidence document status is Draft: no maintainer release approval is recorded.
The implementation is committed/pushed in `codex/multiplatform-flow`, but remains
unpublished. Swift/main is unchanged; no merge or release tag was created.

The historical [post-fix local 63-row ledger](MULTIPLATFORM_FIX_VERIFICATION_2026_10_18.md)
records **58 PASS, 0 FAIL, 3 LIMIT, 2 N/A**. The latest
[hosted follow-up](MULTIPLATFORM_HOSTED_VERIFICATION_2026_10_18.md) closes A06 with
actual API23/35 process restoration and six successful exact-SHA branch jobs.
Its follow-up rollup is **59 PASS, 0 FAIL, 2 LIMIT, 2 N/A**; unchanged local rows
are reused, not all freshly rerun. This is not public 1.0 acceptance.
The [pre-fix ledger](MULTIPLATFORM_VERIFICATION_2026_10_18.md) and its sidecars
remain historical evidence; do not use its old input manifest for this candidate.

## Corrected findings

| Finding | Change | Fresh regression |
| --- | --- | --- |
| F1 constructor parent-Job leak | Validate bounded capacity before creating the owned Job | Rejected 0/negative/MAX capacities preserve parent/sibling; valid stores close cleanly; external Maven probe reports children 0 and completed parent join |
| F2 KSP generic-inner rendering | Rebuild each generic owner/inner boundary | 7 new supported-feature fixtures plus existing visibility/name fixtures compile; plain/function/suspend/manual/inner independent consumers pass; 5 unsupported-feature diagnostics remain |
| F3 packed SSR/browser false positives | Compare exact SSR/DOM values, not substrings | Actual normal gate passes; independent SSR 70 and live UI 80 mutants are rejected on both Node versions |
| API26 restoration probe | Require saved STOPPED state, unchanged numeric PID and exact cmdline; same-UID debug PID fallback only when needed | Standard probe passes on API26 and API34; 16 positive/negative safety controls pass |
| Hosted API23 portability | Fresh owned UI-file fallback; exact ps NAME plus own-UID cmdline instead of the legacy image's all-PID pidof response | 32 safety/UI/PID controls; API23 and35 real process restoration pass; both earlier hosted failures remain archived |
| npm license packaging | Match all three package LICENSE copies byte-for-byte to unchanged root LICENSE; enforce equality in package validation | Original malformed copy is rejected; Node20/22 package and tarball consumers pass |

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

## Hosted evidence

Implementation SHA `a3b1f06cbdd0aa22e883627e4198d8f6c646ea16` passed
[Multiplatform CI](https://github.com/InnoSquadCorp/InnoFlow/actions/runs/39109770382)
on a push to `codex/multiplatform-flow`. All six jobs and five artifact digests
were independently checked. API23 PID `3087 → 3297` and API35 `4581 → 4754`
restore exact `Count: 2` after `am kill`, with saved STOPPED evidence, fresh
screenshots/XML and empty crash buffers. Each API also passes three actual
instrumentation cases. Node20/22 each passes 28 tests and React18/19 consumers.

The JVM unit/consumer reports cover 30 passing cases, but some task results
were restored from Gradle cache; do not describe all 30 as fresh execution.
Device/Node/probe controls were newly executed. Full identity, historical
failures, source manifest, test reports and reproduction instructions are in
[hosted evidence](verification/2026-10-18-hosted/README.md).

## Remaining release gates and exclusions

| Ledger | Not yet proven | Required next evidence |
| --- | --- | --- |
| C06 | Exact-SHA main-push CI | Successful Multiplatform CI on the eventual tagged main SHA, including device/browser jobs |
| C07 | Registry-only installation/publication | Explicit maintainer approval, registry permissions/credentials, publication and fresh remote-only consumers |

Commit/push and branch CI are complete. Main was not merged/pushed; no tag,
Release, npm or GitHub Packages publication occurred, as explicitly requested.
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
