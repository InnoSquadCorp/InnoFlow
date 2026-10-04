# innoflow-migrate

A conservative, standalone SwiftSyntax migration CLI for the InnoFlow 6.0
candidate. It is deliberately **outside the root package graph** and imports
neither the runtime nor its compiler plugin. Requires Swift 6.3+ and pins
SwiftSyntax 604.0.0 by default, matching the reviewed root resolution.

## Run

```sh
swift run --package-path Tools/innoflow-migrate innoflow-migrate Sources/Feature.swift Tests/FeatureTests.swift
swift run --package-path Tools/innoflow-migrate innoflow-migrate --write Sources/Feature.swift Tests/FeatureTests.swift
swift run --package-path Tools/innoflow-migrate innoflow-migrate --check Sources/Feature.swift Tests/FeatureTests.swift
```

The default is a dry-run: stdout is a unified patch, stderr an edit/blocker report.
Use explicit `.swift` file paths; directory recursion is intentionally absent.
`--write` requires **all inputs** to parse and have no blockers. It preserves each
original as `FILE.swift.innoflow-migrate.bak` before applying any source writes.
An existing backup blocks a changed file, and duplicate inputs and symlinks are
rejected. Successful idempotent writes do not touch old backups. Each replacement
is atomic, but a batch is not a filesystem transaction: an I/O error during a
later write can leave an earlier file updated. All originals remain in backups.
Keep the patch/report for review and restore a backup if needed. Move backups
outside SwiftPM source directories before compilation (SPM treats them as
unhandled files).

Exit codes: 0 means a blocker-free plan/write; `--check` returns 1 for pending
edits; 2 means unsupported semantics, malformed syntax, options or filesystem
errors. A dry-run may show safe partial edits **alongside blockers**, but the CLI
never writes such a batch. It does not certify that arbitrary app code compiles.
Review and compile the result with the candidate package.

## Supported syntax

- An `@InnoFlow` struct's body gets the explicit third reducer generic. A direct
  nested `Output` declaration is captured as `Output`; otherwise use `Never`.
  Wrong third arguments are repaired to that actual contract. Self-qualified
  State/Action/Output, `Swift.Never`, module qualification, comments, UTF-8 and
  CRLF are supported. Foreign generic arguments are reported rather than guessed.
- Explicit two-argument `Reduce` / `CombineReducers` in the typed body adopt its
  output. A concrete `EffectTask<Action>` closure return remains Never and is
  explicitly promoted to a nested Output. Local helper declarations are inference
  boundaries; the tool never searches across them for a guessed output type.
- Canonical synchronous `reduce(into state: inout State, action: Action)` becomes
  a body with an explicitly typed Reduce. `EffectTask<Action>` stays Never; a
  typed feature uses `.promoteOutput(to: Output.self)`. Access control and original
  body bytes remain intact, including multiline-string indentation. Unsupported
  modifiers, signature comments, recursion and source-context literals are reported.
- A terminal `assertNoMoreActions(file:line:)` call on an immutable, directly
  initialized local TestStore becomes `finish`. Existing await and source-location
  expressions are retained; await is added only inside an already explicitly async
  function. The call must be that function's final direct statement. This strict
  rule avoids changing an intermediate queue checkpoint into global draining.
- Serial integer literals infer the new UInt without a rewrite. Signed/unknown
  expressions are blockers: no `UInt(...)` trap, clamp or range policy is invented.
- Direct FlowScope construction is reported for an explicit `withFlowScope`
  lifetime decision. Arbitrary statements and escaping storage are never wrapped.
- Recognized `EffectTask` extensions require manual review, including bare,
  `Self`, and explicit `EffectTask<Action>` helper returns. The stable 5.1.1
  nominal struct became a `ReducerEffect<Action, Never>` alias: bare return
  types stop compiling, while `Self` helpers can widen to real Output. Choose
  an explicit `ReducerEffect where Output == Never` extension for output-free
  helpers, or intentionally support generic Output. No extension is rewritten.
- Existing TestStore `file:` calls keep the required-file compatibility overload.
  The tool does not invent a `fileID` from `filePath`; canonical calls already
  default to fileID/filePath/line/column. Alert title expressions are unchanged so
  SwiftUI overload selection keeps their literal/Text/String meaning.

## Deliberate boundaries

This is syntax-only. Unknown assertion receivers, mutable bindings, closures,
nonterminal assertions, conditional Output declarations and noncanonical reducer
signatures need review. Nested helper bodies are not transformed. It does not
resolve custom names that shadow framework names, infer import aliases, propagate
async through call graphs, choose sleeper thresholds, or change application
lifetimes. Review the report and compile against the exact candidate.
The tool accepts both stable 5.1.1 migrations and recognized prerelease 6.0
shapes; scheduler capacity and lexical FlowScope diagnostics concern draft APIs
that were absent from 5.1.1. It does not establish their release history from
syntax. The pinned stable/current compiler controls live in
`scripts/check-migration-consumer.sh`, including EffectTask extension forms.

Every edit is selected by SwiftSyntax nodes and UTF-8 source ranges, not regex
replacement. Unmodified bytes retain trivia and ordering. Both the input and
planned output must parse. Reapplying to supported output produces no edits.

## Verification and CI entry point

```sh
Tools/innoflow-migrate/scripts/check.sh
INNOFLOW_MIGRATE_SWIFT_SYNTAX_VERSION=603.0.0 Tools/innoflow-migrate/scripts/check.sh
```

The script runs focused unit tests and CLI negative/filesystem controls, copies
**the actual** `Tests/Fixtures/MigrationConsumer` V5Consumer and V5Semantics input,
applies only the CLI, checks idempotence, compiles/runs it as an external package,
and runs its three tests against the candidate. A second external consumer checks
typed output, legacy concrete EffectTask promotion and terminal finish. There are
zero manual source edits between copying these inputs and compilation.

`INNOFLOW_MIGRATION_PACKAGE_PATH` explicitly selects a different candidate path.
`INNOFLOW_MIGRATE_TOOL_PACKAGE` explicitly selects a prepared tool validation
mirror; it is never chosen automatically. Set `INNOFLOW_KEEP_CODEMOD_FIXTURE=1`
to preserve the work directory with patches, reports, originals and consumer logs.
The original V5 fixture itself is never modified by this gate.

Source-build checks with SwiftSyntax **603 and 604**, Apple platform compilation,
SwiftUI title-overload behavior and the full release preflight are distinct evidence
boundaries. A Linux validation mirror using toolchain-host SwiftSyntax and an
NSLock shim does not verify either SwiftSyntax source-build line, Apple unfair-lock
semantics, SwiftUI, or release readiness. CI must run the ordinary package gate on
its supported Swift 6.3/6.4 hosted toolchains; focused local evidence is not release
preflight evidence.
