# Validation gates adopted from InnoRouter

Reviewed on 2026-09-17 against InnoRouter commit
`5edd743b66772c724391f1224a674a3c8fb537a2`. InnoRouter remains unchanged.
The implementation borrows its validation contracts, with InnoFlow-specific
modules and candidate evidence. This is not evidence that InnoFlow has shipped.

## Comparison and scope

| InnoRouter gate | InnoFlow treatment |
| --- | --- |
| Validated LCOV, numerical floor, component visibility | Added `run-coverage.sh`, exporter, validator, required-module policy and adversarial controls. All production modules stay visible in one report; no SwiftUI/macro source exclusions were copied. |
| Reusable coverage gate required by release | Both CI and CD call `coverage.yml`; missing, failed, cancelled or skipped release coverage blocks publication. |
| Separate reusable-workflow concurrency namespaces | Enforced by `check-coverage-workflow.rb`, including duplicate namespace negative controls. |
| Validation of the gate scripts themselves | Full local principle gates invoke the existing evidence/workflow selftests plus coverage controls. CI runs the build-free `--static` contract and Debug/Release runtime checks in independent jobs. |
| Independent macro-first consumer | Already covered by InnoFlow's external package compile contracts and Catalyst consumer; do not introduce a second fixture with weaker coverage. |
| TSan/ASan and platform runtime | Existing InnoFlow workflows and evidence policy remain authoritative. Coverage does not replace these gates. |
| DocC and release metadata | Existing DocC pinning, documentation parity, tag policy and release-evidence checks remain in place. |
| Per-product API snapshots and symbol budgets | Not copied. InnoFlow has four products and an unpublished breaking 6.0 surface. Its current compatibility gate is staged until the 6.0 tag exists; an independently reviewed 6.0 API inventory is still useful future work. |
| Compile every annotated documentation code block | Not copied. InnoFlow validates sample/consumer contracts, but does not yet classify and compile every documentation snippet. That needs its own document inventory and explicit partial-example policy. |
| Published 5.x-to-6.x migration consumer comparison | Not copied. The API breakage inventory and current macro compile tests are not the same as an exact published-version behavior comparison. |

## Local execution

```bash
scripts/principle-gates.sh --static
scripts/principle-gates-selftest.sh
scripts/run-coverage.sh
```

The full `scripts/principle-gates.sh` runs its own negative controls before the
existing Debug/Release/sample runtime checks. Coverage is a separate explicit
command and required CI/release job to avoid silently doubling the cost of
every local principle-gate invocation.

Each coverage invocation creates a fresh `.build/coverage/run.*` directory,
retains a PASS/FAIL status, test log, LCOV, per-module summary and before/after
candidate snapshots. A source/policy change during execution fails the run.
The aggregate floor and required executable modules live in
[`coverage-policy.json`](contracts/coverage-policy.json): **85%** overall and
nonzero instrumentation for Core, Macros, SwiftUI and Testing. The `InnoFlow`
facade mainly declares/re-exports APIs; any instrumented lines it emits are
also included, without requiring declaration-only files to report execution.
Empty reports,
duplicate records, invalid or inconsistent counts, non-production paths,
missing modules and below-floor results fail before any publication step.
LLVM's documented-by-output LF/LH macro-region surplus is preserved when it
is internally consistent with DA rows; an empty DA set cannot claim positive
coverage. Numerical coverage describes instrumented source lines, not branch
exhaustiveness, device usability or VoiceOver behavior.

The exporter includes every test binary produced by SwiftPM rather than
assuming one monolithic test bundle. It rejects missing/stale profiles and
does not replace a report when LLVM fails. SwiftUI and compiler bootstrap
lines remain visible, even when unreachable from the host unit tests.

## CI and release behavior

`CI / principle-gates` requires the reusable coverage job. Stale CI runs for
the same pull request or branch are cancelled, ordinary label changes do not
restart the full matrix, and the `run-asan` label is handled by the dedicated
AddressSanitizer workflow. Dependabot groups each ecosystem's updates so one
weekly batch does not create several identical macOS matrices.

Debug tests, Release configuration tests, platform builds, focused runtime
tests and the canonical sample build begin after lint instead of waiting for a
second full principle-gate execution. The CI principle job runs only static
contracts; `check-release-configuration.sh` retains the optimized build, full
Release test suite and isolated timing baseline. The unqualified local
`principle-gates.sh` command remains the complete sequential preflight.

`Release Gate /
release-evidence` requires `release-coverage` and explicitly checks its result
before processing candidate evidence. The reusable job has its own bounded
runtime and namespace; caller jobs deliberately have no `timeout-minutes`
because GitHub does not support it on reusable-workflow calls.

Workflow mutation tests exercise bypass attempts, conditional execution,
ignored failures, missing artifacts and concurrency collisions. Coverage
unit tests exercise malformed reports, module omission, floor changes,
multiple SwiftPM test bundles, stale profiles and failed LLVM exports.
The canonical release-evidence policy also requires the `coverage` command at
local preflight, increasing its required check inventory from 68 to 69.

GitHub execution, release approval and publication still require the existing
release process. Local script and workflow checks do not prove a remote run.

## Initial measurement

On 2026-09-17, local Xcode 27 / Swift 6.4 ran 711 runtime tests and 68 macro
tests with coverage; both suites passed. The two test bundles jointly reported
14,127 / 16,304 lines (**86.65%**) with no production-module exclusions:

| Module | Covered / instrumented lines | Coverage |
| --- | --- | --- |
| InnoFlowCore | 7,666 / 8,581 | 89.34% |
| InnoFlowMacros | 2,584 / 3,101 | 83.33% |
| InnoFlowSwiftUI | 116 / 178 | 65.17% |
| InnoFlowTesting | 3,761 / 4,444 | 84.63% |

The 85% aggregate floor is therefore retained from InnoRouter without copying
its native-UI exclusions. The lower SwiftUI result is visible follow-up work;
an aggregate pass is not a claim that every module exceeds 85%. This initial
measurement validates the current library source, not Swift 6.3 compatibility
or remote CI. Each subsequent runner invocation retains its own candidate
snapshots and results instead of reusing these numbers as release evidence.
