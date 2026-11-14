# Macro Operations

`@InnoFlow` is the canonical feature-authoring path. The `InnoFlow` product
reexports `InnoFlowCore`, owns the macro declarations, and connects each
declaration to the isolated `InnoFlowMacros` compiler-plugin target. This is a
macro-first contract, not a macro-only runtime: `InnoFlowCore` remains usable
without compiler plugins for runtime-only domains, recovery builds, and teams
that deliberately hand-author `Reducer` conformances.

## Supported Consumer Graph

- Feature targets using `@InnoFlow` depend on and import `InnoFlow`.
- SwiftUI targets additionally depend on `InnoFlowSwiftUI`.
- Test targets depend on `InnoFlowTesting` and the product that declares the
  feature under test.
- Runtime-only targets may depend on `InnoFlowCore`; that product does not
  expose macro declarations or compile SwiftSyntax products.

The 6.0 development line still requires Swift 6.3. The reviewed SwiftSyntax
range is `"603.0.0"..<"605.0.0"`, admitting only the 603 and 604 lines.
Maintainer, sample and DocC locks now record 604.0.0 together. Existing full
CI runs that resolution on Xcode 26.6 / Swift 6.3; additional mandatory lanes
exercise the 603.0.0 floor on Swift 6.3 and 604.0.0 on Xcode 27 / Swift 6.4.
Macro diagnostics, external compile contracts and warnings-as-errors remain
blocking. Do not widen the range or change the minimum compiler merely to make
an update pass. Follow [`RELEASING.md`](../RELEASING.md).

## Generated Case Paths

`@InnoFlow` attaches an internal path macro to the nested `Action` enum and,
when the feature declares one, to the nested `Output` enum. Both walk their
cases through one shared traversal, so conditional compilation, availability,
manual paths, `@InnoFlowCasePathIgnored`, and name collisions mean the same
thing for both enums. They differ only in which payload shapes they turn into
a helper.

| Case shape | `Action` | `Output` |
| --- | --- | --- |
| `case done` | no helper | `doneCasePath` (`CasePath<Self, Void>`) |
| `case child(Payload)` or `case child(_ name: Payload)` | `childCasePath` | `childCasePath` |
| `case todo(id: ID, action: Payload)` | `todoActionPath` (`CollectionActionPath`) | `todoCasePath` over the labeled tuple |
| `case selected(id: ID)` | warning, no helper | `selectedCasePath` |
| any other multi-payload case | warning, no helper | `CasePath` over a tuple that keeps the labels |

A payload written `_ name: Payload` has no argument label. The local name only
documents the payload, so the case synthesizes exactly like the unlabeled
spelling, as a single payload and inside a multi-payload tuple.
`Output` never receives `CollectionActionPath`; collection routing remains
Action-only. Optional `Output` payload extraction preserves `.some(nil)` so a
matched nil is not confused with a case mismatch; an optional `Action` payload
still synthesizes and warns. Generic feature context is retained in each path.
Duplicate payload labels produce a diagnostic instead of unstable generated
API. Helper names strip exactly one leading underscore from the case name.

### Conditional compilation and name collisions

Cases nested in conditional compilation are traversed recursively and their
helpers remain inside a mirrored `#if` / `#elseif` / `#else` structure, so a
platform-only payload type never leaks into another platform's compile.

Two helpers with the same name are an error when they can exist in one
compiler configuration, for example `case child(A)` next to `case _child(B)`,
or the same two cases under conditions that can hold together. The same check
covers a helper whose name is already taken by a static function, a nested
type, or a case. Mutually exclusive branches are independent.

Cases that redeclare each other are never a collision. The compiler rejects
an enum in which two cases with the same name and the same argument labels are
active together, and it rejects a payload-free case next to any same-named
case. Such cases can therefore sit in separate conditional clauses that the
macro cannot prove exclusive, for instance two unrelated flags, and each
helper is emitted inside its own mirrored clause without a diagnostic.
Same-named cases with different argument labels can coexist, so their helpers
still collide.

### Manual paths

A canonical static variable declared in the enum body is the author's manual
path and takes precedence over synthesis for every shape in both enums:
`static let <name>CasePath` or `static var <name>CasePath`, and
`<name>ActionPath` for the `id:action:` shape of `Action`. The macro compares
the name only. It cannot resolve the member's type, so aliases and
factory-built paths work, and normal type checking still validates every use.

- Where the manual declaration is active, the macro synthesizes nothing for
  that case and reports nothing: no collision, and no unsupported-shape
  warning for a shape it would not have synthesized anyway.
- If the manual declaration sits in a narrower condition than the case, for
  example behind a user flag, the macro emits the canonical helper under the
  complementary condition. Flag-on and flag-off consumers keep the same API
  and no configuration compiles two active members.
- A manual path declared in an extension is invisible to an attached macro.
  Next to a shape the macro synthesizes it redeclares the generated member and
  the compiler reports `invalid redeclaration`. Move the path into the enum
  body, delete it, or mark the case `@InnoFlowCasePathIgnored`.

`@InnoFlowCasePathIgnored` remains the explicit opt-out. It skips synthesis
and every shape diagnostic for the case. A conditional
`@InnoFlowCasePathIgnored` attribute is a branch-scoped exclusion and is never
copied onto a generated property.

### Availability

Availability is never weakened to make a helper compile. A helper carries the
`@available` attributes of its case: introduced versions, deprecation,
messages, platform restrictions, and conditional attributes inside `#if`.
Three adjustments keep the copy valid:

- `renamed:` is dropped. A case-level rename targets an enum constructor, not
  a `CasePath`. An attribute that says nothing but `renamed:` is not copied at
  all.
- The copy is rendered on one line without comments. Trivia belongs to the
  layout of the case declaration; carried into generated source, a line
  comment could swallow the token that follows it.
- Conditional `@available` attributes are filtered and preserved
  independently of other conditional attributes.

A case that is unavailable everywhere, `@available(*, unavailable)`, has no
generated path: nothing may reference it. When that attribute is itself
conditional, the helper is generated only under the complement of its
condition.

A platform- or environment-specific `unavailable` restriction is different.
The attribute is copied verbatim, so the helper exists and is itself
unavailable wherever its case is. The compiler, not a `#if` approximation in
the macro, resolves inheritance and more specific overrides such as an iOS
restriction combined with a Mac Catalyst introduction. For example,
`@available(macOSApplicationExtension, unavailable)` is copied to the helper:
a normal macOS application keeps it, while a consumer compiled with
`-application-extension` receives the compiler's intended availability error
when it uses that helper. The external compile contract tests both sides. The
enum and its other paths still compile, and using an unavailable case where
prohibited remains a compiler error.

Only a top-level `unavailable` availability argument suppresses a helper.
Occurrences inside `message:` or `renamed:` strings are documentation, not a
compiler restriction. The classifier reads SwiftSyntax availability argument
nodes structurally—platform/version restrictions, keyword tokens, and labeled
arguments are not inferred by splitting or searching rendered source text.

`obsoleted:` is the limit of this approach. Whether an `obsoleted:` version
makes a case unavailable depends on the deployment target or language mode,
which a syntax macro cannot evaluate, so the attribute is copied like any
other. A case obsoleted for a Swift language version, such as
`@available(swift, obsoleted: 5.0)`, is then unavailable to its own helper and
the expansion fails with `'<case>' is unavailable`. Mark a case that
`obsoleted:` makes unavailable with `@InnoFlowCasePathIgnored`. With the
pinned Swift 6.3 toolchain a platform obsoletion such as
`@available(macOS, obsoleted: 14.0)` still compiles, because the helper is
obsolete together with its case; do not rely on that for a case nothing can
use any more.

### Conditional analysis model

Conditional analysis preserves the Boolean meaning of `!`, `&&`, `||`, and
nested parentheses. Branch overlap and coverage are checked with a bounded
internal expression model rather than leading-character or whole-string
comparison. The model knows that positive `os(...)`, `arch(...)`, and
`targetEnvironment(...)` predicates each name a single active value, and it
compares lower/upper intervals for `swift(...)` and `compiler(...)`
predicates, including negated bounds. Predicates of different kinds stay
independent of each other, because the compiler may activate a target
environment together with an OS or architecture condition; every other
predicate, including a user flag, is an opaque atom.
Expressions that exceed the bounded analysis are handled conservatively so
synthesis never silently introduces a possible collision. External consumer
fixtures compile every non-empty combination of three feature flags in
addition to the no-flag build; compiler-predicate fixtures also exercise active
`arch`, `swift`, and `compiler` helpers. Changes to this model must keep those
matrices and the active-collision diagnostic test green.

The consumer matrix keeps one fresh package/build tree per test invocation and
changes these fixture-only defines on both consumer targets. SwiftPM can reuse
the unchanged InnoFlow/SwiftSyntax dependency build while recompiling each flag
configuration; all combinations and negative controls still run. The separate
application-extension check retains its global compiler flag and isolated build
tree so extension-safety validation still includes the dependency graph.

Expansion snapshots for both enums, the shared-rule parity tests, and the
compile-level consumer fixtures, including user-flag on/off builds, are
required whenever this synthesis changes.

## Phase Maps Inside a Phase-Managed Body

`@InnoFlow(phaseManaged: true)` wraps `body` in `Self.phaseMap` and rejects a
`body` that already applies a phase map in the feature's own domain. A child
reducer may own a phase of its own, so a `.phaseMap(...)` written in the child
part of a composing call is not the feature's:

- every argument of `Scope`, `IfLet`, `IfCaseLet`, `ForEachReducer`, and
  `ForEachIdentifiedReducer`;
- every argument of `parent.optionalChild(...)`; its receiver stays in the
  feature's domain;
- the arguments of `OptionalChildLifetime(parent:state:action:instanceID:reducer:)`
  other than `parent:`, which is the feature's domain exactly like the
  receiver of `optionalChild`.

The type may be written `Scope(...)`, `Scope<...>(...)`, `Scope.init(...)`, or
with a module qualifier. This is a syntax rule: the macro recognizes the
composing call by the name written at the call site and the child by its
position in that call. It does not follow values or types, so two spellings
are still read as the feature's own phase map and rejected:

- a child reducer hoisted into a local constant inside `body`, such as
  `let child = Child().phaseMap(Child.phaseMap)`;
- a combinator reached through a typealias, such as
  `typealias ChildScope = Scope<State, Action, Child>`.

Write the child's `.phaseMap(...)` inside the combinator's arguments, or build
the child reducer outside `body`, for example in a property or function the
`body` calls.

## What Macro-First Guarantees

The macro-generated path is covered by expansion snapshots, diagnostic tests,
cross-target public/package consumer builds, generated CasePath identity tests,
and Debug/Release package gates. `@InnoFlow` rejects explicit
`reduce(into:action:)` authoring, requires a reducer `body`, synthesizes the
Reducer witness, and generates supported action paths.

Macros operate on syntax, not fully type-checked program semantics. A feature
whose `State` or `Action` is hidden behind a typealias can therefore receive a
note that some structural diagnostics were skipped. The compiler still checks
the expanded Reducer contract. Navigation, transport, dependency-graph
construction, and other app-owned semantics intentionally remain outside the
macro.

## Failure Playbook

Start by recording `swift --version`, `xcodebuild -version`, the selected Xcode
toolchain, and the resolved `swift-syntax` version. Reproduce with the smallest
consumer target before deleting global caches.

### Prebuilt SwiftSyntax mismatch

Swift 6.3 attempts prebuilt SwiftSyntax for macros by default when a matching,
valid signed artifact is available. A successful default build does not prove
that a prebuilt was used. If a toolchain
update or cache produces a malformed macro response, missing host library, or
SwiftSyntax compatibility failure, verify the source-built fallback:

```bash
swift build --disable-experimental-prebuilts --product InnoFlow
swift test --disable-experimental-prebuilts
```

These commands are a diagnostic and recovery path. Do not make the slower
source build the default until its clean-build cost is measured. InnoFlow CI
and the release gate build the `InnoFlow` product through this fallback, and
the compile-contract suite builds an external macro consumer the same way.

### Compiler-plugin trust

Xcode can require interactive trust for compiler plugins on a developer
machine. Review `Package.resolved` and trust the resolved package through the
Xcode prompt. On controlled CI where the dependency graph is already reviewed,
pass `-skipMacroValidation` to `xcodebuild` if non-interactive trust is needed.

Do not substitute `-skipPackagePluginValidation` by default. That flag also
bypasses validation for build-tool plugins and is intentionally broader than
the macro-only exception.

### Sandbox failures

Compiler-plugin sandboxing is the default security boundary. Do not add
`--disable-sandbox` to project or CI defaults. Use it only for a captured,
reproducible sandbox failure, document the exception, and remove it when the
underlying toolchain or plugin issue is fixed.

### Scoped cache recovery

Prefer a package-scoped reset over deleting all Xcode or user caches:

```bash
swift package reset
swift package resolve
swift build
```

If the macro path remains unavailable, temporarily point the affected target
at `InnoFlowCore` and hand-author the existing `Reducer` requirement. This is a
recovery boundary, not a second recommended feature style; return public
feature authoring to `@InnoFlow` after the toolchain issue is resolved.

## CI and Cache Contract

Cache keys for a consumer should include the Swift/Xcode version,
`Package.resolved`, build configuration, and destination platform. Never share
macro build artifacts across incompatible host toolchains. InnoFlow's own
GitHub workflows use fresh hosted runners rather than relying on a cross-job
macro cache, then verify both the default SwiftPM path and the explicit
source-built fallback. Record artifact/log evidence separately before claiming
prebuilt use. The [dependency integration record](DEPENDENCY_INTEGRATION_2026_09_30.md)
documents the 603.0.1/604.0.0 source-build comparison and availability limits.

Run the repository's fast structural check with:

```bash
./scripts/check-macro-operations.sh
```

Maintainers changing macro code or package topology must also run the macro
tests, `CompileContractTests`, and the full principle gates.
