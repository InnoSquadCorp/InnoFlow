# InnoFlow 6.0 local candidate status

Updated 2026-10-03. This is an implementation and verification ledger, not a
release certificate. Both supplied plans are retained in docs/plans. The final
commit, immutable source hashes, raw logs and final non-regression decision are
reported in the separate final verification receipt; do not infer them from an
earlier implementation commit.

| Scope | Local implementation / verification | Remaining boundary |
| --- | --- | --- |
| D1/D2/M1/M2/T1/T2 | Before-fail controls preserved; ownership, error handling, identifiers, output progress and non-consuming dispatch finish repaired | Full Apple/platform suite |
| Optional child / collections | Store and TestStore removal, replacement, reentry, nested and sibling isolation; collection key path/element namespace; final-state ancestor cleanup; stable default IfCaseLet identity and explicit lifetimeID | Apple presentation integration |
| W0 | Runtime probe workflow, Ruby/date controls, target-limited simulator discovery and source-hashed full test inventory prepared; positive/negative fixtures pass | Actual legacy-runtime probe/routing, remote preflight and security approval |
| W1 | Product-only equal-flag 512-process improvement cohort independently verified; initial unequal-flag cohort invalidated; JSON2 converter and source-break controls pass | Final-source separate non-regression receipt; Apple S5/TCA/Instruments/absolute targets |
| W2 | Scheduler stale/latest/pre-cancel/double-start, ring snapshots, anonymous lanes and both OnChange completion orders tested | Platform-only behavior |
| W3/W4 | Canonical TestStoreDispatch with TestFlowTask alias; external positive/negative contracts, source coordinates, real XCTest fallback, scoped output, physical completion ledger and lexical FlowScope | Five-product Apple digester and XCTExpectFailure branches |
| W5 | Actual transition observation without resolver replay, seeded replay/minimization, physical cleanup and diagnostic priority; zero-budget registration race reproduced then fixed, 200 fixed post-fix checks pass | Final-source cumulative verification receipt |
| W6 | Macro Fix-Its and conservative AST codemod; original V5 consumer converted with zero manual edits and semantics controls | Apple application migration coverage |
| W7 | Inspector fifth product, view-owned tasks, title overloads, layered sample and independent consumers; Core/graph/model tests pass | Real SwiftUI compile, UI/accessibility execution |
| W8 | Explicit concurrent operation contracts and mutation-tested unsafe-source gate; downstream upcoming-feature consumer passes | Global upcoming-feature adoption deliberately deferred; platform TSan |
| W9 | Four-language beginner docs, executable tutorial, API/JSON migration, exact test inventories and external consumer gates | Final hosted docs/API/platform runs and 32/32 preflight |

## Recorded VM scope

The latest integrated selected suite passed 311 runtime declarations in 40 suites
plus nine identifier-macro declarations, with two deliberately expected known
issues. Separately, the full macro suite passed 89 declarations in nine suites.
Four current sample model tests passed with warnings-as-errors after explicitly
extracting model declarations from their Apple UI files. This is not a claim
that the complete sample app compiled or ran.

Official Swift 6.3.3 with source-built SwiftSyntax 603.0.0 and 604.0.0 separately
passed 186 selected runtime plus 89 complete macro declarations, four external
consumers and six expected source-break controls, with warnings-as-errors.
The full source inventory is 953 Swift Testing declarations, not the count of
Linux tests executed. Full-platform execution remains required.

## Performance interpretation

The initial 512-process cohort is excluded because candidate testability and
linker flags differed. A fresh admitted product-only pair completed all 512
processes with unchanged binary hashes; independent calculation reproduced all
eight paired medians and bootstrap intervals and the predeclared improvement
gate. That source snapshot preceded the final collection lifetime correction.
The final non-regression capture is separate and never pooled with it.

The metric is ContinuousClock wall elapsed. Each process contributes one average
per operation; the reported value is a median of 30 process averages, not CPU
time, individual-operation latency, p95 latency or SwiftUI frame time. These
combined-patch results do not isolate the contribution of each optimization.

Linux validation uses an NSLock shim for Apple unfair locks and omits Apple
OSLog/signpost and SwiftUI surfaces. Toolchain-host SwiftSyntax validation is
separate from the source-built 603/604 floor runs. No Linux result establishes
Apple lock latency, rendering, TCA comparisons or release readiness.

## Original remote baseline

Remote main 1389926 preflight 37120540957 completed with 21 passed and 11 failed
checks. Four legacy runtime downloads failed, four 27.0 simulator discoveries
incorrectly attempted the host macro test bundle, and three complete host checks
passed tests but exceeded stale count maxima. See
[PREFLIGHT_VALIDATION_REVIEW_2026_10_03.md](PREFLIGHT_VALIDATION_REVIEW_2026_10_03.md)
for verified artifacts, exact test additions and local fixtures. The local
candidate has not been published or run in that remote matrix.

## Publication state

No remote branch, PR, merge, tag, release or repository protection setting was
changed by this task. STABLE_VERSION remains 5.1.1 and 6.0.0 is Unreleased. The
release-date gate intentionally rejects the undated target at tag time.
