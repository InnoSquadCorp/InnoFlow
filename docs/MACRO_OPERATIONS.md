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

The 5.0 development line requires Swift 6.3. `swift-syntax` is constrained to
the single toolchain line `"603.0.0"..<"604.0.0"` so expansion and diagnostic
output cannot drift across toolchain majors, while consumer graphs that carry
other macro packages can still resolve a shared 603.x patch. Maintainer and CI
reproducibility comes from `Package.resolved`, which records the exact
SwiftSyntax version every gate runs against. Upgrade the toolchain and the
SwiftSyntax line together through the policy in
[`RELEASING.md`](../RELEASING.md).

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
