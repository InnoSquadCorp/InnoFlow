# InnoFlow 6.0 review guide

Review the behavior contracts and their executable controls before generated
inventories. A generated inventory is an expectation of which tests must run,
not proof that those tests passed. This guide does not certify release readiness.

## Current functional integration boundary

The functional candidate keeps every product file under `Sources/` byte-identical
to `e15dfac8e0c97edb4706ac35595f22fc2cff5c1d`. S/I2/D2 remain unadopted in the
preserved trial `9008e338d9c2dca6c30e876b476c299000bf651b`. The 25 additional
regression declarations and compiler/runtime evidence checks are retained; two
mixed dense-index tests are extracted as explicitly named semantic regressions.
Their original operation-count assertions remain unchanged in the preserved trial.
See [the integration record](reviews/FUNCTIONAL-CI-INTEGRATION-2026-10-04.md) for
the exact mapping and verification boundaries.

The A-only collection completed 3,312 samples: 3 of 69 comparisons established
equivalence and 66 did not establish it; none had an interval disjoint from the
equivalence region. Candidate timing remains unexecuted. CPU8 steal counters
increased, so host noninterference is not established. No automatic sample
expansion follows from this diagnostic.

## Suggested review order

| Concern | Product and contract | Executable boundary |
| --- | --- | --- |
| Synchronous owned effects | `Store.swift`, `EffectWalker.swift`, `ARCHITECTURE_CONTRACT.md`, `OPTIONAL_CHILD_LIFETIME.md` | `OwnedSynchronousEffectConsistencyTests`: direct sends/outputs, immediate close/replace/reentry, sibling/parent isolation and physical completion |
| Stable migration | `MIGRATION.md`, `Tools/innoflow-migrate` | `Tests/Fixtures/MigrationConsumer/EffectTaskExtensions`, `check-migration-effect-extensions.py`, codemod compiler/CLI controls |
| Public API decisions | `PUBLIC_API_FREEZE_6_0.md`, `API_BREAKAGE_6_0.md` | `Tests/Fixtures/TestFlowTaskConsumer` preserves its historical directory name while testing canonical `TestStoreDispatch`; intended negative spellings are compiled and checked for the expected reason |
| Lifetime and observation | `OptionalChildLifetime.swift`, `ReducerComposition.swift`, `Store.swift`, `ProjectionObserverRegistry.swift` | Collection/optional lifetime, observation and registration tests; normal and animated paths; late registration and cancellation-ignoring work |
| TestStore dispatch ownership | `TestStoreDispatch.swift`, the TestStore effect ledger and receive/finish implementation | Dispatch-specific assertions, selected cancellation, pending action/output preservation and actual task termination |
| Diagnostics | `StoreDiagnostics.swift`, `DispatchContext.swift` | Exact event contents, bounded history, active-dispatch ordering/limits and retained snapshot value semantics |
| CI evidence interpretation | `release-evidence-tool.rb`, `validate-focused-runtime-result.py`, focused runtime runner | Positive receipts and rejected wrong-target, missing/extra/skipped test, unintended failure, compiler mismatch and altered-source controls |

Source files above are under `Sources/InnoFlowCore` or `Sources/InnoFlowTesting`,
tests under `Tests/InnoFlowTests`, and scripts under `scripts`. Follow each
specific test into its wrong-implementation control where one is supplied.

## Generated files and maintenance

- `docs/contracts/swift-test-inventory.json` records SwiftSyntax declarations,
  source hashes and conditional compilation contexts. Regenerate from reviewed
  source with `scripts/report-swift-test-inventory.sh`; do not manually raise
  the test-count ceiling to match a failing run
- `swift-test-inventory-review.json` explains the source declaration delta.
  `runtime-test-inventory.json` identifies the focused runtime suites and exact
  intentional diagnostic identities. Selection must match the actual compiler
- `release-evidence-policy.json` binds each check to its command, source-derived
  inventory and environment. Selftests exercise rejection as well as acceptance
- Public API, migration and documentation fixtures are maintained source. They
  should be reviewed as consumer examples, not dismissed as generated data
- VM performance capture, compiler caches and large raw logs are separate from
  the product checkout. Product claims must identify the tested source/binary;
  an older report or successful adapter does not certify a newer Apple build

There is no justified deletion target based only on a file count or percentage.
Remove a duplicated mechanism only after identifying its contract and replacing
its positive and negative coverage. Keep sample/UI and native platform checks
even when a Linux adapter cannot execute them.

## Size checkpoint, not a final-head claim

For exact local functional source `e15dfac8e0c97edb4706ac35595f22fc2cff5c1d`
against main `138992674025cb6faa69d224c30580e0fce63e85`, Git reports 265 changed
files, 30,749 added lines and 1,582 removed lines. `Sources/` accounts for 69
files and 5,243 added lines, `Tests/` for 70 files and 7,018 added lines, and
`scripts/` for 53 files and 2,225 added lines. The last figure is 7.24% of added
lines for that definition; it does not reproduce or refute an unspecified
“scripts 91%” metric. The two largest declaration/review JSON inventories alone
account for 10,235 added lines.

These figures come from `git diff --numstat <main-sha> <source-sha>` and include
all tracked changes in that comparison. Recompute them at a later head rather
than relabeling this checkpoint as current.

## Evidence limits that remain explicit

The supplied report did not identify raw measurements or exact sources for its
latency numbers, TestStore 2.2x ratio or five flaky tests. Named fixed stress
controls provide evidence for the tests actually executed; they do not establish
that five unspecified failures were repaired. Existing delayed TestStore release,
debounce, trailing-throttle, awaited-composite and post-fire nested-effect tests
remain useful controls and must keep their original assertions.

The v8 Core and Testing performance candidates failed their predeclared adoption
requirements and remain unadopted. The subsequent source hypotheses and their
unresolved large-State copy goal are described in
`plans/CORE-COMPONENT-FOLLOWUP-2026-10-04.md`. No threshold is relaxed here.

Apple API/runtime, SwiftUI/sample UI and the main-only 32-check Release Preflight
are separate evidence. A Ready pull request, source inventory or Linux result
does not establish their completion. Merge, tag and release are separate actions.
