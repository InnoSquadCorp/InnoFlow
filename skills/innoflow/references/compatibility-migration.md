# Version, toolchain, and migration

The [support record](support.json) separates stable **6.0.x** support (`>=6.0.0, <6.1.0`) from the exact **6.0.2** tagged baseline at `1176de1e4783b638c03a9334f43cc49378957148`. The exact tag and GitHub Release published on 2026-10-08 were verified. Immutable tag metadata retains its prepublication stable marker; it does not describe current publication status.

## Compatibility

The 6.0.2 manifest requires Swift tools **6.3**, Swift 6 language mode, and SwiftSyntax **`>=603.0.0, <605.0.0`**. The exact consumer lock uses SwiftSyntax **604.0.0** at `050f1a346fbbac0ca2cfb15a95274f7bd1cf0ccf`, with Xcode 27 / Swift 6.4 validation. This one host does not qualify all declared toolchains.

Deployment floors are iOS 18, macOS 15, tvOS 18, watchOS 11, and visionOS 2. Do not lower application floors blindly or claim older-platform support from older InnoFlow versions. Linux, alternate SwiftSyntax resolution, and other Apple runtimes are outside the fixture's validation.

Compare the actual manifests of every macro dependency. Unlike older InnoFlow 5.x manifests, this tagged 6.0.2 range admits SwiftSyntax 604. That range overlaps the DI 7.0.0 / Network 6.1.0 exact-604 constraint, but overlap alone is not a tested combined consumer. Verify the current resolved graph, not a historical compatibility table, and do not fix a real solver conflict with an unrequested downgrade or local source override.

Macro authoring uses `InnoFlow`. For a compiler-plugin failure, distinguish trust/toolchain/version mismatch from source diagnostics. Use the exact [macro operations guide](https://github.com/InnoSquadCorp/InnoFlow/blob/1176de1e4783b638c03a9334f43cc49378957148/docs/MACRO_OPERATIONS.md); do not disable global validation or security settings as a routine repair. `InnoFlowCore` is an intentional plugin-free recovery choice, not an automatic rewrite.

## 5.x to 6.0 migration

Review [the exact migration guide](https://github.com/InnoSquadCorp/InnoFlow/blob/1176de1e4783b638c03a9334f43cc49378957148/MIGRATION.md) before editing. Separate stable 5.1.1 changes from corrections to unreleased 6.0 drafts.

1. Add the third reducer generic (`Never` or nested `Output`) to each feature body and explicit composition type. Prefer macro Fix-Its while preserving behavior.
2. Map real child outputs explicitly; `EffectTask<Action>` remains the alias for `ReducerEffect<Action, Never>`. Use `promoteOutput(to:)` only for `Never`.
3. Statement-style sends can ignore the new return handle. Stored `Void`-returning method values and protocol adapters need closures that discard it explicitly. Runtime sends return `FlowTask`; testing sends return `TestStoreDispatch`.
4. Replace terminal `assertNoMoreActions()` with `await store.finish()`. Use `assertNoBufferedActions()` only for an intermediate queue assertion, and consume pending output separately.
5. Preserve Sendable markers on hoisted composition/PhaseMap key paths; do not erase/cast away the compiler proof.
6. Keep existing `IfLet` behavior unless state-owned cancellation is requested. Optional-child lifetime, run admission, scopes, outputs, and diagnostics are opt-in 6.0 capabilities.

For draft adopters, use `withFlowScope` instead of direct construction, `TestStoreDispatch` instead of `TestFlowTask`, `reducer:` for optional-child construction, and explicit `onceSleepersReach` for scenario time. Do not impose these draft-only migrations on a stable 5.1.1 consumer that never used them.

The bundled example validates authoring on 6.0.2; it is not a completed migration of an existing application. Preserve unrelated work and run that application's own tests after any migration.

Exact sources: [Package.swift](https://github.com/InnoSquadCorp/InnoFlow/blob/1176de1e4783b638c03a9334f43cc49378957148/Package.swift), [API breakage](https://github.com/InnoSquadCorp/InnoFlow/blob/1176de1e4783b638c03a9334f43cc49378957148/docs/API_BREAKAGE_6_0.md). For another stable patch, inspect its manifest and relevant fixes without changing the consumer to the fixture's baseline.
