# Public API decisions for 6.0

This record distinguishes compatibility with published **5.1.1**
(`00a73ed2d2cb94114b0be5c9fbd59c187a4b67c7`) from names introduced only in
the unreleased 6.0 development branch. Compiler fixtures accompany each change;
this document alone is not API validation or a release receipt.

## One testing dispatch handle

`TestStoreDispatch` is the canonical return type of root, scoped and phase-helper
testing sends. Its name describes verification of one dispatch, including its
descendants and unverified actions/outputs. The proposed `TestFlowTask` spelling
was never part of 5.1.1 and will not ship as a second public alias. Draft users
replace that type spelling with `TestStoreDispatch`; ownership and finish behavior
do not change. Statement sends remain discardable. A function value returning
`Void` requires an explicit adapter, as documented in the stable migration guide.

## Source-location compatibility follows the published surface

Existing 5.1.1 testing functions retain their explicit `file:line:` overloads.
Calls that omit a location use the canonical `fileID:filePath:line:column:`
defaults at the call site. The legacy overload requires `file:` to avoid overload
ambiguity and maps its one file value to both file coordinates with column 1.

New 6.0 APIs use only the complete coordinate form: dispatch finish, root/scoped
receiveOutput, invariant construction/registration, and scenario steps. They had
no published legacy overload to preserve. Removing their draft-only `file:` forms
reduces the new surface while keeping every published location spelling. Helpers
should forward all four coordinates, rather than adding new legacy overloads.

## Consistent composition labels

`OptionalChildLifetime` and `Reducer.optionalChild` take `reducer:` for the child
reducer, consistent with Scope, IfLet, IfCaseLet and the ForEach reducers. The
draft-only `child:` argument label is replaced before publication. State fields
named `child`, internal effect metadata and user-defined APIs keep their names.
The child still reduces before the parent; parent effects outside the child
wrapper remain independent of child lifetime cancellation.

## Public enum evolution

Consumers may exhaustively switch over the framework's public enums. Adding,
removing or changing a public case after 6.0.0 is a source compatibility change
and requires a major release under this package's policy. A public enum without
`@frozen` is not a promise that a SwiftPM consumer can accept new cases in a minor
release; compiler resilience and package source compatibility are separate.

The 6.0 admission enum includes started, queued, rejected, cancelledBeforeStart
and superseded. Consumer fixtures and the sample handle all five explicitly.
An unknown/default branch can be appropriate for a consumer's own forward
compatibility policy, but the framework does not require one to excuse additions
within the current major line. Macro-generated paths honor the consumer enum's
availability and conditional declarations; they do not invent future cases.

## Validation boundary

Positive consumers compile canonical spellings and preserved 5.1.1 location
calls. Negative controls reject removed draft names/labels and draft-only legacy
location forms for the intended diagnostic. Source-derived API/test inventories,
documentation examples and migration checks are updated in the same branch.
The staged post-6.0 API digester becomes a strict baseline only after the real
6.0.0 tag exists; the absence of that tag is not a compatibility PASS.
