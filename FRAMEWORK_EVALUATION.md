# InnoFlow 4.0.0 Framework Evaluation (Release-Readiness v7.0)

English | [한국어](./FRAMEWORK_EVALUATION.kr.md) | [日本語](./FRAMEWORK_EVALUATION.jp.md) | [简体中文](./FRAMEWORK_EVALUATION.cn.md)

> **Evaluation date:** 2026-04-29
> **Target version:** InnoFlow 4.0.0 contract surface
> **Repository snapshot:** `3.0.3-8-g3b77300` on `main`
> **Scoring axes:** Programming (40%) · CS theory (25%) · SwiftUI philosophy (35%)
> **Evidence base:** README + localized README, DocC articles, `ARCHITECTURE_CONTRACT.md`, `CHANGELOG.md`, `RELEASE_NOTES.md`, 279 core `@Test` declarations, 37 sample-package `@Test` declarations, 10 canonical sample demos, release build validation, release-sync checks, and principle-gate policy reviewed directly

---

## Table of Contents

1. [Programming (40%)](#i-programming-weight-40)
2. [CS Theory (25%)](#ii-cs-theory-weight-25)
3. [SwiftUI Philosophy (35%)](#iii-swiftui-philosophy-weight-35)
4. [Overall Score](#iv-overall-score)
5. [Known Limitations](#v-known-limitations)
6. [What Changed Since v6.1](#vi-what-changed-since-v61)
7. [Remaining Work](#vii-remaining-work)
8. [Cumulative Improvement Log](#viii-cumulative-improvement-log)

---

## I. Programming (Weight 40%)

### 1. Architecture Design — 9.8 / 10

| Item | Evaluation |
|------|------------|
| **Single protocol contract** | `Reducer<State, Action>` remains the one runtime contract; official authoring is `var body: some Reducer<State, Action>` |
| **Strategy + interpreter** | `EffectWalker<D>` + `EffectDriver` keep runtime and test-store interpretation separated |
| **Three-layer runtime** | `Store -> StoreEffectBridge -> EffectRuntime(actor)` keeps UI mutation, store-local bookkeeping, and cancellable task state distinct |
| **Projection model** | `ScopedStore` + `SelectedStore` use cached snapshots, dependency buckets, and explicit lifecycle accessors |
| **Lifecycle contract** | Released-parent and inactive-projection races now return cached reads / no-op writes in release builds while debug builds assert |
| **Macro-enforced surface** | `@InnoFlow` validates body-based authoring, synthesizes case paths, diagnoses `@BindableField` setter drift, and supports `phaseManaged: true` |
| **Contract documentation** | `ARCHITECTURE_CONTRACT.md`, ADRs, release notes, and principle gates now describe the stable 4.0.0 boundary set |

**Deduction (-0.2):** 4.0.0 is a contract and documentation rebaseline, but the local repository snapshot is still ahead of the latest checked tag. The implementation is release-ready; final publication still depends on the actual `4.0.0` tag and release workflow.

---

### 2. API Design — 9.4 / 10

| Item | Evaluation |
|------|------------|
| **Composition surface** | `Reduce`, `CombineReducers`, `Scope`, `IfLet`, `IfCaseLet`, and `ForEachReducer` form the documented public composition set |
| **`PhaseMap` DSL** | `From` / `On` builders mirror SwiftUI-style declaration while keeping phase ownership explicit |
| **Phase-managed macro** | `@InnoFlow(phaseManaged: true)` removes the need to remember a manual `.phaseMap(Self.phaseMap)` wrapper |
| **Action routing** | Generated `CasePath` / `CollectionActionPath` values keep scoping public APIs typed and closure-free |
| **Selection API** | Fixed-arity `select(dependingOn:)` covers one through six explicit slices, `select(dependingOnAll:)` covers larger explicit dependency sets, and plain `select { ... }` remains the always-refresh fallback |
| **Scoped selection parity** | `ScopedStore.select(dependingOnAll:)` now mirrors the root-store API for large child read models |
| **Binding contract** | `@BindableField` + projected key paths keep bindings explicit; `binding(_:to:)` improves enum-case callsites without breaking `send:` |
| **Instrumentation factories** | `.sink`, `.osLog`, `.signpost`, and `.combined` are all official extension points |

**Deduction (-0.6):** The common 1-through-6 `SelectedStore` overloads still create some API and implementation duplication, and payload-case sugar beyond canonical `CasePath` authoring remains intentionally minimal.

---

### 3. Code Quality — 9.4 / 10

| Item | Evaluation |
|------|------------|
| **File distribution** | Core store, effect bridge, runtime, caches, composition, phase modeling, instrumentation, and macros are split by concern |
| **Builder implementation** | `ReducerBuilder` preserves concrete composition types for optimizer visibility while principle gates keep internal wrapper types out of docs and samples |
| **Macro maintainability** | Bindable-field and phase-totality diagnostics are split out of the macro entry file and guarded by file-size / leakage checks |
| **`ActionMatcher`** | A compact `match(_:) -> Payload?` abstraction underpins payload-aware `PhaseMap` transitions |
| **Sendability discipline** | Principle gates enforce zero `@unchecked Sendable` in shipped source, tests, and sample package source |
| **Release workaround isolation** | The Swift 6.3 release-optimizer workaround is localized to isolated `deinit` paths and documented as a toolchain workaround |

**Deduction (-0.6):** The localized `@_optimize(none)` workaround is acceptable for release readiness, but it should be retested and removed when the relevant Swift optimizer crash is fixed.

---

### 4. Error Handling & Lifecycle — 9.4 / 10

| Item | Evaluation |
|------|------------|
| **Triple cancellation checks** | `Task.isCancelled`, runtime emission decisions, and store lifetime checks all gate effect emissions |
| **Zombie-effect prevention** | `StoreLifetimeToken`, weak store captures, and explicit drop reasons prevent late effects from mutating released stores |
| **Projection lifecycle contract** | `ScopedStore.state`, `ScopedStore.send`, collection-scoped projections, and `SelectedStore.value` have release-mode coverage for cached-read / no-op semantics |
| **Debug visibility** | Release-tolerant lifecycle races still surface through debug assertions so they do not become silent development mistakes |
| **Crash contracts** | Programmer errors such as invalid initial scopes, wrong collection identity, direct `PhaseMap` phase mutation, and undeclared phase targets are exercised through subprocess tests |
| **Instrumentation** | Action emissions, drops, cancellations, and run lifecycle events are visible through sink/log/signpost APIs |

**Deduction (-0.6):** Cancellation remains cooperative by design. Uncooperative effects are contained at emission boundaries, but the framework cannot stop arbitrary external work without caller cooperation.

---

### 5. Performance — 8.9 / 10

| Item | Evaluation |
|------|------------|
| **Reducer composition** | Concrete builder chains avoid the older nested-closure collapse and improve construction benchmarks |
| **`EffectID` hashing** | Typed `Hashable & Sendable` IDs are erased once at runtime while preserving raw-value equality domains |
| **Collection offset cache** | `CollectionScopeOffsetBox` + revision tracking keep common collection-scoped lookup paths O(1) |
| **Dependency-bucket refresh** | Key-path dependency buckets avoid re-evaluating unrelated `SelectedStore` projections |
| **`dependingOnAll:`** | Parameter-pack selection keeps large explicit read models selective instead of falling back to always-refresh recomputation |
| **`PhaseMap` lookup** | Per-action resolution uses O(1) source-phase lookup plus a linear walk over only that source phase's transitions |
| **Effect timing baseline** | Principle gates include a dedicated release-only effect timing baseline check to catch catastrophic scheduling regressions |

**Deduction (-1.1):** Opaque closure selector memoization remains intentionally unsupported because general closures do not expose a typed read set. A per-phase transition index still needs real workload evidence before adding `Action: Hashable` pressure or extra API shape.

---

### 6. Testing & Validation — 9.9 / 10

| Item | Evaluation |
|------|------------|
| **Core tests** | 279 core `@Test` declarations across runtime, projection, phase, macro, instrumentation, performance, and subprocess contract suites |
| **Sample tests** | 37 sample-package `@Test` declarations exercise the canonical demos through `TestStore` and real sample features |
| **Canonical sample count** | 10 documented demos: basics, orchestration, phase-driven FSM, app-boundary navigation, authentication, pagination, offline-first, realtime stream, form validation, and bidirectional websocket |
| **Release build** | `swift build -c release` is a required principle-gate step and was validated for the current snapshot |
| **Release tests** | Principle gates include full release-mode tests plus an isolated release timing baseline gate |
| **Compile contracts** | `swiftc -typecheck` subprocess tests lock binding, effect ID, scoping, and macro contract failures |
| **Crash / release subprocesses** | Debug crash contracts and release-like tolerant lifecycle contracts are both covered |
| **CI surface** | Lint, core tests, sample tests, five-platform package builds, principle gates, sample visionOS build, sample app build, and UI smoke tests are all represented in workflow policy |

**Deduction (-0.1):** The full principle gate remains intentionally heavy. That is the right release bar, but day-to-day local validation still relies on narrower test slices.

---

### Programming Subtotal

| Item | Score |
|------|-------|
| Architecture Design | 9.8 |
| API Design | 9.4 |
| Code Quality | 9.4 |
| Error Handling & Lifecycle | 9.4 |
| Performance | 8.9 |
| Testing & Validation | 9.9 |
| **Subtotal (equal weight)** | **9.47** |

---

## II. CS Theory (Weight 25%)

### 1. Type Theory — 9.2 / 10

| Item | Evaluation |
|------|------------|
| **Associated-type contract** | `Reducer` statically binds `State` and `Action`, both `Sendable` |
| **Opaque reducer authoring** | The macro rejects `any Reducer` and requires `some Reducer<State, Action>` for feature bodies |
| **Typed action paths** | `CasePath<Root, Value>` and `CollectionActionPath<Root, ID, ChildAction>` preserve payload and identity typing |
| **Parameter-pack selection** | `select(dependingOnAll:)` uses Swift parameter packs to express arbitrary explicit dependency sets without erasing dependency value types |
| **`ActionMatcher<Action, Payload>`** | Payload-aware phase matching keeps the input alphabet structurally typed |
| **`PhaseMap` generics** | `PhaseMap<State, Action, Phase>` statically tracks the owned phase field, reducer action, and phase domain |

**Deduction (-0.8):** `Reducer` itself is intentionally not `Sendable`, and some phase internals type-erase payloads after the public typed boundary. This is pragmatic, but not theoretically perfect.

---

### 2. Category Theory / FP — 9.2 / 10

| Item | Evaluation |
|------|------------|
| **Free effect model** | `EffectTask.Operation` is a pure indirect enum interpreted later by a driver |
| **Functor laws** | `EffectTask.map` identity and composition behavior is tested |
| **Monoid laws** | `.none` identity and `concatenate` associativity are tested |
| **Reducer composition** | Concrete builder output preserves declaration order and grouping semantics |
| **Post-reduce decorator** | `PhaseMappedReducer` remains a reducer-to-reducer transformation that owns one state field |

**Deduction (-0.8):** `lazyMap` and release-oriented effect scheduling guarantee behavioral equivalence rather than structural equivalence of every intermediate representation.

---

### 3. Automata / FSM — 9.0 / 10

| Item | Evaluation |
|------|------------|
| **`PhaseTransitionGraph`** | O(1) adjacency lookup, reachability checks, terminal validation, and structured reports |
| **`PhaseMap` DSL** | `From` / `On` builders model a declarative transition function over source phase and action matcher |
| **Post-reduce semantics** | Phase resolution sees the reducer's updated state, which fits state-dependent transitions |
| **Guard conditions** | Dynamic target resolution is constrained by declared target sets and tested for nil / same-phase behavior |
| **`derivedGraph`** | Static topology checks are derived from the same declaration used at runtime |
| **Totality validation** | Runtime remains partial by default, while `validationReport` and `assertPhaseMapCovers` support opt-in expected-trigger coverage |
| **Macro totality diagnostic** | `@InnoFlow(phaseManaged: true)` warns about phase cases that never appear in `phaseMap` declarations |

**Deduction (-1.0):** Totality is still author-declared and opt-in. The framework does not attempt full compile-time graph reachability or NFA / epsilon-transition modeling.

---

### 4. Concurrency Theory — 9.2 / 10

| Item | Evaluation |
|------|------------|
| **Actor split** | `MainActor Store` and `EffectRuntime` actor keep UI state and task bookkeeping in separate isolation domains |
| **Sequencing** | Monotonic `UInt64` sequences gate cancellation and emission boundaries |
| **Barrier synchronization** | `RunStartGate` coordinates task registration before operation bodies begin |
| **Manual clock** | `ManualTestClock.sleeperCount` lets tests wait for actual suspension points instead of fixed yield counts |
| **Release scheduling contract** | `Store.send(_:)` now documents that effects are scheduled, not necessarily started, after synchronous state draining |
| **Timing regression gate** | A release-only effect timing baseline catches the class of scheduler regressions that debug-only tests can miss |

**Deduction (-0.8):** The runtime intentionally uses unstructured tasks for effect bodies. The contract is well documented and tested, but it remains a trade-off versus fully structured task ownership.

---

### 5. Data Structures & Algorithms — 8.9 / 10

| Item | Evaluation |
|------|------------|
| **Token maps** | `tokensByID` and `idByToken` maintain bidirectional cancellable-run lookup |
| **Projection registries** | Dependency-bucket refresh and periodic compaction keep observer work bounded |
| **Selection cache** | Callsite and value-type keyed selected-store caching preserves identity across repeated calls |
| **Collection scope cache** | Stable IDs, offset boxes, and revision tracking optimize common row-projection paths |
| **Phase indexing** | `rulesBySourcePhase` avoids scanning unrelated source phases |
| **Diffing** | TestStore diff rendering is intentionally test-only and line-limited for diagnostics |

**Deduction (-1.1):** Some hot-path improvements remain evidence-gated: opaque selector memoization, a phase transition index, and deeper diff optimization should wait for workload data.

---

### CS Theory Subtotal

| Item | Score |
|------|-------|
| Type Theory | 9.2 |
| Category Theory / FP | 9.2 |
| Automata / FSM | 9.0 |
| Concurrency Theory | 9.2 |
| Data Structures & Algorithms | 8.9 |
| **Subtotal (equal weight)** | **9.10** |

---

## III. SwiftUI Philosophy (Weight 35%)

### 1. Declarative Paradigm — 9.8 / 10

| Item | Evaluation |
|------|------------|
| **Body-based authoring** | Official feature authoring mirrors SwiftUI's `body` shape |
| **Result builders** | Reducer and phase builders keep feature declarations readable and composable |
| **Phase-managed macro** | `@InnoFlow(phaseManaged: true)` keeps phase ownership declarative at the feature boundary |
| **Modifier-style semantics** | `.phaseMap(...)`, `.cancellable`, `.debounce`, `.throttle`, and `.animation` remain chainable and explicit |
| **Dependency bundles** | Construction-time dependencies stay plain Swift values instead of hidden service locators |

**Deduction (-0.2):** Some internals, especially collection scoping, still require imperative offset/cache bookkeeping to make the declarative surface efficient.

---

### 2. Reactive Data Flow — 9.4 / 10

| Item | Evaluation |
|------|------------|
| **`@Observable`** | `Store`, `ScopedStore`, and `SelectedStore` participate directly in Swift Observation |
| **Unidirectional flow** | `Action -> Reducer -> State -> View` stays explicit |
| **Phase ownership** | `PhaseMap` owns one phase key path and prevents direct reducer mutation from escaping |
| **Projection lifecycle** | SwiftUI observer races are now bounded to cached snapshots in release builds instead of process aborts |
| **Selective invalidation** | Key-path and parameter-pack dependencies avoid unnecessary view refreshes |
| **Binding surface** | Projected key paths make bindable fields visible in state definitions and action routing |

**Deduction (-0.6):** Closure-only selectors still always refresh because arbitrary closures cannot advertise their read set.

---

### 3. Composition Model — 9.5 / 10

| Item | Evaluation |
|------|------------|
| **Six composition primitives** | The documented set is small enough to learn and broad enough for optional, enum, and collection child features |
| **Generated routing** | Macro-generated action paths reduce boilerplate without introducing runtime reflection |
| **Effect lifting** | `EffectTask.map` preserves cancellation, debounce, throttle, and run semantics across child reducers |
| **Scoped test projection** | Parent `TestStore` projections keep child tests tied to real parent reducer behavior |
| **Cross-framework boundary** | Navigation, transport, and dependency graph ownership stay outside InnoFlow by contract |

**Deduction (-0.5):** `CollectionActionPath` and `CasePath` remain separate public concepts, and phase decoration still belongs at explicit reducer boundaries.

---

### 4. State Management — 9.4 / 10

| Item | Evaluation |
|------|------------|
| **`@BindableField`** | Field-level binding is explicit and diagnostic-backed |
| **`ScopedStore`** | Child views receive read-only projected state plus typed action forwarding |
| **`SelectedStore`** | Expensive derived read models are cached, equatable, and dependency-aware |
| **`dependingOnAll:`** | Larger read models no longer have to choose between six-field arity limits and always-refresh fallback |
| **Lifecycle accessors** | `isAlive`, `optionalState`, and `optionalValue` let callers branch on projection liveness without triggering debug assertions |
| **Preview stores** | `Store.preview(...)` standardizes preview-only clock and instrumentation defaults |

**Deduction (-0.6):** Mutable child flows still require `ScopedStore`; `SelectedStore` intentionally stays read-only and does not attempt a writable derived-state model.

---

### 5. Platform Integration — 9.3 / 10

| Item | Evaluation |
|------|------------|
| **Five platforms** | Package policy covers iOS, macOS, tvOS, watchOS, and visionOS |
| **Release build** | Release build and release-mode tests are now part of the principle-gate contract |
| **Animation bridge** | `EffectAnimation` keeps SwiftUI animation handoff explicit |
| **Instrumentation** | `.signpost` integrates with Instruments timelines, `.osLog` covers Console, `.sink` supports custom adapters, and `.combined` fans out events |
| **Accessibility** | Canonical sample docs and UI smoke tests use stable accessibility identifiers |
| **visionOS boundary** | `VisionOSIntegration.md` documents that spatial runtime and immersive orchestration stay in the app layer |
| **Canonical sample** | Ten demos cover common product flows without pulling navigation, network, or DI ownership into the core framework |

**Deduction (-0.7):** There is still no official `swift-metrics` adapter package and no dedicated immersive/spatial sample beyond boundary documentation.

---

### SwiftUI Philosophy Subtotal

| Item | Score |
|------|-------|
| Declarative Paradigm | 9.8 |
| Reactive Data Flow | 9.4 |
| Composition Model | 9.5 |
| State Management | 9.4 |
| Platform Integration | 9.3 |
| **Subtotal (equal weight)** | **9.48** |

---

## IV. Overall Score

| Axis | Score | Weight | Weighted Score |
|------|-------|--------|----------------|
| Programming | 9.47 | 40% | 3.788 |
| CS Theory | 9.10 | 25% | 2.275 |
| SwiftUI Philosophy | 9.48 | 35% | 3.318 |
| **Total** | | **100%** | **9.38 / 10** |

### Grade: Production Ready+ (93.8 / 100)

This score evaluates the implementation and documentation contract in the current repository snapshot. It does not assert that the public `4.0.0` tag already exists; tag publication remains a release-process gate.

---

## V. Known Limitations

| Area | Current Policy |
|------|----------------|
| **Effect identifiers** | `EffectID<RawValue>` now supports dynamic identifiers, but only for `RawValue: Hashable & Sendable`. This keeps runtime cancellation maps safe while leaving reducer types themselves non-`Sendable` by policy. See `docs/adr/ADR-reducer-sendable-policy.md`. |
| **Dependency graph construction** | InnoFlow intentionally does not ship a DI container. Reducers receive explicit construction-time dependency bundles; richer graph behavior belongs in the app layer or a DI library. See `docs/adr/ADR-no-builtin-di-container.md` and `docs/DEPENDENCY_PATTERNS.md`. |
| **Navigation ownership** | Concrete route stacks, `NavigationPath`, tabs, windows, and immersive-space orchestration remain outside InnoFlow. Reducers may emit business intent, but the app boundary owns navigation state. See `docs/CROSS_FRAMEWORK.md`. |
| **Transport/session lifecycle** | Long-lived sockets, reachability monitors, retry policies, and session ownership stay in transport clients. InnoFlow consumes their domain events as effects but does not become the transport runtime. See `docs/CROSS_FRAMEWORK.md`. |

---

## VI. What Changed Since v6.1

| Item | v6.1 | v7.0 | Delta | Reason |
|------|------|------|-------|--------|
| Architecture Design | 9.7 | 9.8 | +0.1 | Projection lifecycle contract and release-mode tolerant semantics are now documented and tested |
| API Design | 9.2 | 9.4 | +0.2 | `Store` and `ScopedStore` now expose `select(dependingOnAll:)`; `binding(_:to:)` and signpost instrumentation are documented |
| Code Quality | 9.2 | 9.4 | +0.2 | Macro diagnostics are split, builder internals are gated, and release-workaround scope is explicit |
| Error Handling & Lifecycle | 9.2 | 9.4 | +0.2 | Cached-read / no-op write lifecycle behavior has release-like subprocess coverage |
| Performance | 8.6 | 8.9 | +0.3 | Reducer builder specialization, `dependingOnAll:`, and release timing baseline policy improve practical performance confidence |
| Testing & Validation | 9.8 | 9.9 | +0.1 | Current evidence is 279 core tests, 37 sample tests, release build, release tests, and sample validation policy |
| Automata / FSM | 8.7 | 9.0 | +0.3 | Phase-managed macro diagnostics complement opt-in runtime totality validation |
| Platform Integration | 9.0 | 9.3 | +0.3 | Signpost instrumentation, ten-demo canonical sample, and release build/test gates improve Apple-platform readiness |

**Nature of this update:** v7.0 is a current-state refresh, not a theoretical redesign. Most gains come from release-readiness hardening, documentation-contract alignment, sample breadth, and validation coverage.

---

## VII. Remaining Work

### P1 — Release Publication Gate

| Item | Trigger Condition |
|------|-------------------|
| Publish or retarget the `4.0.0` install surface | The README and localized README now point to `from: "4.0.0"` while the checked local tag list still ends at `3.0.3`; either publish the tag before public consumption or keep install snippets on the latest published tag until release |
| Harden release-sync semantics | `scripts/check-release-sync.sh` should distinguish "release notes prepared" from "tag published" unless a deliberate pre-release override is set |

### P2 — Conditional Backlog

| Item | Trigger Condition |
|------|-------------------|
| Opaque selector memoization | repeated real-world usage plus profiling evidence that always-refresh closure selectors are too expensive |
| Per-phase transition index | actual phase-heavy workloads show the per-source linear `On` walk on a hot path |
| Official metrics adapter package | enough users need first-party `swift-metrics`, Datadog, or Prometheus bindings beyond `.sink` |
| Dedicated immersive/spatial sample | a real product flow needs runnable visionOS orchestration examples beyond ownership-boundary docs |

### P3 — Polish

| Item | Note |
|------|------|
| Release workaround retirement | Retest the localized `@_optimize(none)` workaround on Swift toolchain bumps |
| Framework comparison refresh cadence | Keep `docs/FRAMEWORK_COMPARISON.md` aligned with the 4.0.0 evaluation and current ecosystem positioning |
| Localized evaluation docs | This English file is canonical; localized evaluation companions should be refreshed after the 4.0.0 scorecard stabilizes |

---

## VIII. Cumulative Improvement Log

### v1 -> v2 (8.07 -> 8.19)

- Physical `Store` file split
- Three-tier binding contract
- Animation surface separation
- Stronger principle gates

### v2 -> v3 (8.19 -> 8.48)

- `@InnoFlow` macro synthesis for `CasePath` / `CollectionActionPath`
- Built-in `IfLet` / `IfCaseLet`
- `StoreInstrumentation` with lifecycle hooks and action drop reasons
- `ManualTestClock`
- O(1) collection offset cache
- Functor / Monoid law tests
- Multi-platform CI

### v3 -> v4 (8.48 -> 8.93)

- `SelectedStore` three-tier selection API
- `ProjectionObserverRegistry` dependency-based refresh
- `SelectionCache` / `CollectionScopeCache` callsite validation
- `EffectRuntime` actor split
- `Store + EffectDriver` separation

### v4 -> v5 (8.93 -> 9.14)

- `PhaseMap<State, Action, Phase>` for declarative phase ownership
- `ActionMatcher<Action, Payload>` for payload-aware action matching
- `PhaseMappedReducer` as a post-reduce decorator with mutation restore
- `PhaseMap` DSL with `From` / `On` builders
- `derivedGraph` automatic derivation
- `PhaseMap+Testing` conveniences
- Canonical sample migration to `PhaseMap`

### v5 -> v6.1 (9.14 -> 9.20)

- `PhaseMap` totality validation through `validationReport`, `PhaseMapExpectedTrigger`, and `PhaseMapValidationReport`
- ADRs for declarative `PhaseMap` and phase totality validation
- `ARCHITECTURE_CONTRACT.md` enforced in CI
- `VisionOSIntegration.md` for visionOS ownership guidance
- Expanded CI with visionOS package builds and canonical sample UI smoke tests
- Expanded principle gates for accessibility, visionOS, `PhaseMap` docs, and underscore-stripped action-path naming
- `Store.preview()` ergonomics for previews
- `PhaseMap` edge-case tests for direct mutation crashes, undeclared targets, ordering, and `On(where:)`

### v6.1 -> v7.0 / 4.0.0 (9.20 -> 9.38)

- 4.0.0 contract and documentation rebaseline
- 279 core tests and 37 sample-package tests reflected in the scorecard
- Ten-demo canonical sample catalog reflected in the evaluation evidence
- Release build, release-mode test, and isolated release timing baseline policy added to validation evidence
- `Store.select(dependingOnAll:)` and `ScopedStore.select(dependingOnAll:)` for larger explicit read-model dependency sets
- Projection lifecycle contract for `ScopedStore` and `SelectedStore`, including `isAlive`, `optionalState`, and `optionalValue`
- Release-mode subprocess coverage for projection cached-read / no-op-write behavior
- `StoreInstrumentation.signpost(...)` plus `.combined(...)` as official Instruments-friendly instrumentation
- `@InnoFlow(phaseManaged: true)` and phase totality diagnostics reflected in API and theory scoring
- Reducer-builder specialization and associated performance policy reflected in performance scoring

---

### Conclusion

InnoFlow 4.0.0 is **Production Ready+ at 9.38 / 10 (93.8 / 100)** for the implementation and contract surface currently on `main`. The major remaining work is release-process alignment: the install snippets and release notes now describe `4.0.0`, so the public tag and release-sync semantics must match before users are pointed at that version.
