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

The 6.0 development line requires Swift 6.3. `swift-syntax` is constrained to
the single toolchain line `"603.0.0"..<"604.0.0"` so expansion and diagnostic
output cannot drift across toolchain majors, while consumer graphs that carry
other macro packages can still resolve a shared 603.x patch. Maintainer and CI
reproducibility comes from `Package.resolved`, which records the exact
SwiftSyntax version every gate runs against. Upgrade the toolchain and the
SwiftSyntax line together through the policy in
[`RELEASING.md`](../RELEASING.md).

## Output Case Paths

When an `@InnoFlow` feature declares a nested `Output` enum, the macro attaches
an internal output-path macro that synthesizes public canonical case paths for
supported no-payload, single-payload, labeled, and multi-payload cases. Optional
payload extraction preserves `.some(nil)` so a matched nil is not confused with
a case mismatch. Generic feature context is retained in each path.

Generated helpers preserve the case declaration's availability attributes.
Cases nested in conditional compilation are traversed recursively and their
helpers remain inside a mirrored `#if` / `#elseif` / `#else` structure, so a
platform-only payload type never leaks into another platform's compile. The
collision check treats mutually exclusive branches independently while still
diagnosing duplicates that can coexist in one active branch.

An existing canonical static path suppresses synthesis only where that manual
declaration is active. If the declaration is guarded by a user flag, the macro
emits the canonical helper under the complementary condition so both flag-on
and flag-off consumers retain the same API without compiling duplicate active
members. `@InnoFlowCasePathIgnored` remains the explicit opt-out.

Conditional output analysis preserves the Boolean meaning of `!`, `&&`, `||`,
and nested parentheses. Branch overlap and coverage are checked with a bounded
internal expression model rather than leading-character or whole-string
comparison. The model knows that positive `os(...)` and `arch(...)` predicates
name a single active value, and it compares lower/upper intervals for
`swift(...)` and `compiler(...)` predicates, including negated bounds. Other
predicates such as `targetEnvironment(...)` remain opaque atoms because the
compiler may activate them together with an OS or architecture condition.
Expressions that exceed the bounded analysis are handled conservatively so
synthesis never silently introduces a possible collision. External consumer
fixtures compile every non-empty combination of three feature flags in
addition to the no-flag build; compiler-predicate fixtures also exercise active
`arch`, `swift`, and `compiler` helpers. Changes to this model must keep those
matrices and the active-collision diagnostic test green.

Availability is never weakened to make a helper compile. Introduced,
deprecated, and conditional `@available` attributes are preserved on generated
helpers. A case carrying a normal platform `unavailable` restriction cannot
safely participate in a stored initializer on that compiler branch, so the
macro emits its case path only in the complement of those conditions. An
unconditionally unavailable case therefore has no generated path, while a
macOS-unavailable case can still expose one on iOS, tvOS, watchOS, and visionOS.

Application-extension domains are different: for example,
`@available(macOSApplicationExtension, unavailable)` is copied to the generated
helper rather than suppressing it. A normal macOS application therefore keeps
the helper, while a consumer compiled with `-application-extension` receives
the compiler's intended availability error when it tries to use that helper.
The external compile contract tests both sides. The enum and its other paths
still compile, and using any unavailable case where prohibited remains a
compiler error. Apply `@InnoFlowCasePathIgnored` as documentation when authoring
such a case if omission should be explicit at the declaration site.

Only a top-level `unavailable` availability argument suppresses a helper.
Occurrences inside `message:` or `renamed:` strings are documentation, not a
compiler restriction. The classifier reads SwiftSyntax availability argument
nodes structurally—platform/version restrictions, keyword tokens, and labeled
arguments are not inferred by splitting or searching rendered source text.
Conditional `@InnoFlowCasePathIgnored` attributes are
treated as branch-scoped exclusions and are not copied onto generated
properties; conditional `@available` attributes are filtered and preserved
independently.

Duplicate labels or local name collisions produce diagnostics instead of
unstable generated API. Output never receives `CollectionActionPath`;
collection routing remains Action-only. Expansion snapshots and external
compile fixtures, including user-flag on/off builds, are required whenever this
synthesis changes.

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

Swift 6.3 enables prebuilt SwiftSyntax for macros by default. If a toolchain
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
macro cache, then explicitly verify both the default prebuilt path and the
source-built fallback.

Run the repository's fast structural check with:

```bash
./scripts/check-macro-operations.sh
```

Maintainers changing macro code or package topology must also run the macro
tests, `CompileContractTests`, and the full principle gates.
