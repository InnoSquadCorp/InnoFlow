# InnoFlow 3.0.0 Framework Evaluation (Clean-Slate v6.1)

English | [한국어](./FRAMEWORK_EVALUATION.kr.md) | [日本語](./FRAMEWORK_EVALUATION.jp.md) | [简体中文](./FRAMEWORK_EVALUATION.cn.md)

> **Evaluation date:** 2026-03-18 (code sync: 2026-03-18)  
> **Target version:** InnoFlow 3.0.0 (`PhaseMap` + totality validation)  
> **Scoring axes:** Programming (40%) · CS theory (25%) · SwiftUI philosophy (35%)  
> **Evidence base:** canonical sample, README + 5 DocC articles, 177+14 core `@Test`, 7 CI jobs (5-platform matrix), principle gates, and 3 ADRs reviewed directly

---

## Table of Contents

1. [Programming (40%)](#i-programming-weight-40)
2. [CS Theory (25%)](#ii-cs-theory-weight-25)
3. [SwiftUI Philosophy (35%)](#iii-swiftui-philosophy-weight-35)
4. [Overall Score](#iv-overall-score)
5. [What Changed Since the Previous Evaluation](#v-what-changed-since-the-previous-evaluation)
6. [Remaining Work](#vi-remaining-work)
7. [Cumulative Improvement Log](#vii-cumulative-improvement-log)

---

## I. Programming (Weight 40%)

### 1. Architecture Design — 9.7 / 10

| Item | Evaluation |
|------|------------|
| **Single protocol contract** | `Reducer<State, Action>` with one `reduce(into:action:)` entry point; all composition builds on top of it |
| **Strategy + Interpreter** | `EffectWalker<D>` + `EffectDriver` cleanly separate `Store` and `TestStore` behavior |
| **Three-layer runtime** | `Store -> StoreEffectBridge -> EffectRuntime(actor)` with explicit `MainActor/MainActor/Actor` boundaries |
| **Projection model** | `ScopedStore` + `SelectedStore` with cached snapshots and dependency-bucket refresh |
| **Macro-enforced surface** | `@InnoFlow` validation, synthesized `CasePath` / `CollectionActionPath`, and targeted Fix-Its |
| **Declarative FSM** | `PhaseMap` + `PhaseMappedReducer` separate phase ownership as a post-reduce decorator and restore illegal direct mutations |
| **Contract documentation** | `ARCHITECTURE_CONTRACT.md` + 3 ADRs, with principle gates enforcing both presence and wording in CI |

**Deduction (-0.3):** `PhaseMap` remains opt-in by design.

---

### 2. API Design — 9.2 / 10

| Item | Evaluation |
|------|------------|
| **`PhaseMap` DSL** | `From` / `On` result builders mirror the SwiftUI `body` authoring style |
| **Six `On` overloads** | Equatable action / `CasePath` / predicate × fixed target / guard, with progressive disclosure |
| **Payload-aware guards** | `CasePath`-based `On` closures receive associated values in a type-safe way |
| **Post-reduce decorator** | `.phaseMap(...)` mirrors the SwiftUI view-modifier pattern |
| **`derivedGraph` reuse** | `PhaseMap` automatically derives `PhaseTransitionGraph`, reusing existing validation and testing APIs |
| **Totality validation** | Phase-specific expected triggers are validated through a structured report |
| **Three-tier selection API** | Dedicated 1/2/3 dependency overloads plus opaque closure fallback |
| **Binding contract** | Projected key-path bindings stay type-safe and explicit |
| **Preview ergonomics** | `Store.preview()` includes clock and instrumentation defaults for SwiftUI previews |

**Deduction (-0.8):** (1) `SelectedStore` still keeps overload duplication. (2) There is no shorter dedicated sugar for leaf payload cases beyond canonical `CasePath` authoring.

---

### 3. Code Quality — 9.2 / 10

| Item | Evaluation |
|------|------------|
| **File distribution** | Responsibilities are split by concern; `PhaseMap` itself is separated into spec, wrapper, testing helper, and validation report |
| **`ActionMatcher`** | Strong core abstraction with a single `match(_:) -> Payload?` contract |
| **Naming clarity** | `PhaseMappedReducer`, `AnyPhaseTransition`, `PhaseRuleBuilder`, `PhaseMapExpectedTrigger` all communicate role clearly |
| **`package` access control** | Internal transition types stay scoped to the package surface |
| **`@unchecked Sendable`** | Principle gates enforce zero uses in shipped source |
| **Principle gates** | CI enforces contract docs, ADR presence, `PhaseMap` docs, accessibility docs, underscore-stripped action path naming, visionOS docs, and ownership boundaries |

**Deduction (-0.8):** `StoreSupport.swift` still contains six independent support types, which is an organizational improvement opportunity rather than a functional problem.

---

### 4. Error Handling — 9.2 / 10

| Item | Evaluation |
|------|------------|
| **Triple cancellation checks** | `Task.isCancelled` + emission decision + `lifetime.isReleased` |
| **Zombie-effect prevention** | `StoreLifetimeToken` + `weak self` + emission gating |
| **Stale projection contract** | `preconditionFailure` plus subprocess crash tests |
| **Phase ownership violation detection** | `PhaseMappedReducer` catches direct base reducer phase mutation, asserts, and restores `previousPhase` |
| **Guard target violation** | Returning a phase outside `declaredTargets` asserts and cancels the phase update |
| **Four drop reasons** | `ActionDropReason` integrates with instrumentation |

**Deduction (-0.8):** There is still no explicit `UInt64` wraparound assertion. This remains a practical non-issue.

---

### 5. Performance — 8.6 / 10

| Item | Evaluation |
|------|------------|
| **`EffectID` hashing** | Cached `normalizedValue` keeps hashing O(1) |
| **Collection offset cache** | `CollectionScopeOffsetBox` + revision tracking keep lookup O(1) |
| **Dependency-bucket refresh** | `hasChanged` predicates avoid unnecessary refresh work |
| **`PhaseMap` rule lookup** | Linear traversal is acceptable because most features keep phase rules under 10 |
| **Lazy-map flattening** | `eagerMap` uses a loop rather than recursive wrapper growth |
| **Auto-compaction** | Threshold + periodic compaction keep observer registries bounded |

**Deduction (-1.4):** (1) 4+ dependency selection memoization remains a trigger-based backlog item. (2) `PhaseMap` lookup is O(rules × transitions), although a hash-indexed source-phase table is only justified if feature scale grows materially.

---

### 6. Testing — 9.8 / 10

| Item | Evaluation |
|------|------------|
| **177+14 `@Test`** | 177 core + 14 macro tests; 200 total when sample-package tests are included |
| **`PhaseMap` coverage** | Covers basic/payload transitions, unmatched action/phase, guard logic with post-reduce state, ordering, direct-mutation crashes, undeclared-target diagnostics, release-like restore, `On(where:)`, and totality validation reports |
| **Deterministic time** | `ManualTestClock` integrated with `EffectContext.sleep` |
| **Algebraic laws** | Functor identity/composition and Monoid identity/associativity are tested |
| **Compile-time contracts** | `swiftc -typecheck` subprocess tests lock macro contracts |
| **Crash contracts** | `preconditionFailure` paths are exercised in subprocess tests |
| **`PhaseMap+Testing`** | `send/receive(through:)` delegates to `derivedGraph` automatically |
| **UI smoke tests** | CI validates the canonical sample through accessibility identifiers |
| **visionOS build** | CI verifies the sample package’s visionOS target |

**Deduction (-0.2):** There is still room for narrower edge-case stress coverage, such as more multi-phase chains and guard-returns-`nil` compositions.

---

### Programming Subtotal

| Item | Score |
|------|-------|
| Architecture Design | 9.7 |
| API Design | 9.2 |
| Code Quality | 9.2 |
| Error Handling | 9.2 |
| Performance | 8.6 |
| Testing | 9.8 |
| **Subtotal (equal weight)** | **9.28** |

---

## II. CS Theory (Weight 25%)

### 1. Type Theory — 9.1 / 10

| Item | Evaluation |
|------|------------|
| **Phantom types** | `CasePath<Root, Value>` and `CollectionActionPath<Root, ID, ChildAction>` |
| **Associated-type contract** | `Reducer` requires `State: Sendable` and `Action: Sendable` |
| **Existential avoidance** | The macro rejects `any Reducer` and enforces `some Reducer<State, Action>` |
| **`ActionMatcher<Action, Payload>`** | Two-parameter abstraction keeps payload typing intact and infers `CasePath` values naturally |
| **`PhaseMap` generics** | `PhaseMap<State, Action, Phase>` statically tracks phase/state/action relationships |
| **`PhaseMapExpectedTrigger<Action>`** | `.action()`, `.casePath()`, and `.predicate()` factories keep trigger declarations typed |

**Deduction (-0.9):** `Reducer` itself is intentionally not `Sendable`, and `AnyPhaseTransition` type-erases payloads internally. Neither is a practical issue for the public API.

---

### 2. Category Theory / FP — 9.1 / 10

| Item | Evaluation |
|------|------------|
| **Free Monad** | `EffectTask.Operation` is an indirect enum and therefore a pure data structure |
| **Functor laws** | `map(id) == id` and `map(f).map(g) == map(f∘g)` are tested |
| **Monoid laws** | `.none` identity and `concatenate` associativity are tested |
| **Natural transformation** | `EffectTask.map` composes lazily through `lazyMap` |
| **Post-reduce decorator** | `PhaseMappedReducer` behaves as a reducer-to-reducer endofunctor |

**Deduction (-0.9):** `lazyMap` still guarantees behavioral equivalence rather than full structural equivalence.

---

### 3. Automata / FSM — 8.7 / 10

| Item | Evaluation |
|------|------------|
| **`PhaseTransitionGraph`** | O(1) adjacency lookup, BFS reachability, and 5 structured validation issues |
| **`PhaseMap` DSL** | `From` / `On` builders model declarative transition functions cleanly |
| **Guard conditions** | `resolve` closures make transitions state-dependent in a Mealy-like way |
| **Payload-aware matching** | `ActionMatcher<Action, Payload>` structurally decomposes the input alphabet |
| **`derivedGraph`** | Analysis artifacts are derived directly from the declaration |
| **Post-reduce semantics** | Phase is decided after the base reducer runs, aligning with state-dependent transition logic |
| **Totality validation** | Phase-specific expected triggers are validated through a structured report, while ADRs document partial-by-default semantics |

**Improvement vs. v5 (+0.2):** The previous “no totality support” deduction is now partially resolved through opt-in test-time validation. It is not compile-time exhaustive, but it does catch missing expected triggers.

**Deduction (-1.3):** (1) NFA / epsilon-transition modeling is out of scope. (2) Compile-time totality enforcement is still intentionally unsupported.

---

### 4. Concurrency Theory — 9.0 / 10

| Item | Evaluation |
|------|------------|
| **Lamport-style sequencing** | Monotonic `UInt64` tokens gate cancellation boundaries |
| **Two-actor model** | `MainActor Store` + `EffectRuntime` actor |
| **Barrier synchronization** | `RunStartGate` coordinates task start order |
| **Triple cancellation** | `Task.isCancelled` + emission decision + lifetime check |
| **Lock-backed lifetime token** | `StoreLifetimeToken` uses `OSAllocatedUnfairLock` |

No score change.

---

### 5. Data Structures & Algorithms — 8.7 / 10

| Item | Evaluation |
|------|------------|
| **Bidirectional maps** | `tokensByID ↔ idByToken` stay O(1) |
| **Adjacency map** | `PhaseTransitionGraph` stores `[Phase: Set<Phase>]` |
| **Offset cache** | `CollectionScopeOffsetBox` + revision tracking |
| **`PhaseMap` rule resolution** | Linear, deterministic, and first-match-wins |
| **`derivedGraph` construction** | O(rules × transitions), calculated once and reusable |

**Deduction (-1.3):** (1) Source-phase lookup could become O(1) with a hash-indexed table if rule counts ever grow materially. (2) `Mirror`-based diffing is still O(n·depth), although it is test-only infrastructure.

---

### CS Theory Subtotal

| Item | Score |
|------|-------|
| Type Theory | 9.1 |
| Category Theory / FP | 9.1 |
| Automata / FSM | 8.7 |
| Concurrency Theory | 9.0 |
| Data Structures & Algorithms | 8.7 |
| **Subtotal (equal weight)** | **8.92** |

---

## III. SwiftUI Philosophy (Weight 35%)

### 1. Declarative Paradigm — 9.7 / 10

| Item | Evaluation |
|------|------------|
| **Result builders** | `ReducerBuilder`, `PhaseRuleBuilder`, and `PhaseTransitionRuleBuilder` are all first-class |
| **`body` symmetry** | `var body: some Reducer<State, Action>` matches the SwiftUI mental model directly |
| **`PhaseMap` DSL** | `From` / `On` authoring stays declarative and compositional |
| **Modifier chain** | `.phaseMap(...)` behaves like a view modifier for reducers |
| **Effect DSL** | `.run`, `.cancellable()`, `.debounce()`, and friends stay chainable and explicit |

**Deduction (-0.3):** `ForEachReducer` still contains imperative offset bookkeeping internally.

---

### 2. Reactive Data Flow — 9.2 / 10

| Item | Evaluation |
|------|------------|
| **`@Observable`** | `Store`, `ScopedStore`, and `SelectedStore` all participate in observation |
| **Unidirectional flow** | `Action -> Reducer -> State -> View` remains crisp |
| **Phase ownership** | `PhaseMap` owns the phase key path and restores illegal direct writes |
| **Dependency-based refresh** | Only changed buckets are reevaluated |
| **Binding contract** | Projected key paths keep SwiftUI-style explicit bindings |

**Deduction (-0.8):** `.alwaysRefresh` fallback still exists for opaque closure selectors.

---

### 3. Composition Model — 9.4 / 10

| Item | Evaluation |
|------|------------|
| **Six core composition primitives** | `Reduce`, `CombineReducers`, `Scope`, `IfLet`, `IfCaseLet`, `ForEachReducer` |
| **`PhaseMap` decorator** | Adds a new composition axis without changing base reducer semantics |
| **`CasePath` integration** | `IfCaseLet` and `Scope` use `CasePath`-based public initializers |
| **`ActionMatcher` reuse** | `PhaseMap` reuses the same structural routing ideas already present in the framework |
| **Effect lifting** | `Effect.map` preserves cancellation / debounce / throttle semantics across child reducers |

**Deduction (-0.6):** `CollectionActionPath` and `CasePath` remain separate types, and `PhaseMap` still applies only at the top-level reducer boundary.

---

### 4. State Management — 9.2 / 10

| Item | Evaluation |
|------|------------|
| **`@BindableField`** | Property wrapper + projected value stay explicit and typed |
| **`ScopedStore`** | Read-only scoped projection |
| **`SelectedStore`** | Derived selection optimized for 1–3 explicit dependencies |
| **`PhaseMap` ownership** | Introduces state-field ownership as a first-class concept |
| **Callsite caching** | `SelectionCache` and `CollectionScopeCache` keep projections efficient |

**Deduction (-0.8):** 4+ dependency optimization remains intentionally backlog-driven.

---

### 5. Platform Integration — 9.0 / 10

| Item | Evaluation |
|------|------------|
| **Five platforms** | iOS 18, macOS 15, tvOS 18, watchOS 11, visionOS 2 are all covered in CI |
| **Animation bridge** | `EffectAnimation -> withAnimation` stays explicit |
| **Preview ergonomics** | `Store.preview()` improves SwiftUI preview callsites |
| **Instrumentation surface** | `.osLog()`, `.sink()`, `.combined()` offer practical extension points |
| **Accessibility** | Canonical sample includes labels/hints and principle gates enforce documentation |
| **visionOS** | `VisionOSIntegration.md` plus CI visionOS build coverage and sample package support |
| **UI automation** | Canonical sample UI smoke tests run through accessibility identifiers |

**Deduction (-1.0):** There is still no official `swift-metrics` adapter package, and there is no dedicated immersive/spatial sample beyond documentation guidance.

---

### SwiftUI Philosophy Subtotal

| Item | Score |
|------|-------|
| Declarative Paradigm | 9.7 |
| Reactive Data Flow | 9.2 |
| Composition Model | 9.4 |
| State Management | 9.2 |
| Platform Integration | 9.0 |
| **Subtotal (equal weight)** | **9.30** |

---

## IV. Overall Score

| Axis | Score | Weight | Weighted Score |
|------|-------|--------|----------------|
| Programming | 9.28 | 40% | 3.712 |
| CS Theory | 8.92 | 25% | 2.230 |
| SwiftUI Philosophy | 9.30 | 35% | 3.255 |
| **Total** | | **100%** | **9.20 / 10** |

### Grade: Production Ready+ (92.0 / 100)

---

## V. What Changed Since the Previous Evaluation

| Item | v5 (9.14) | v6.1 (9.20) | Delta | Reason |
|------|-----------|-------------|-------|--------|
| Code Quality | 9.1 | 9.2 | +0.1 | Principle gates, `ARCHITECTURE_CONTRACT`, and 3 ADRs are now CI-enforced |
| Testing | 9.6 | 9.8 | +0.2 | `PhaseMap` edge-case coverage, UI smoke tests, and visionOS build checks |
| Composition Model | 9.2 | 9.4 | +0.2 | Previous `IfCaseLet` deduction was factually incorrect; public API is `CasePath`-based |
| **Automata / FSM** | **8.5** | **8.7** | **+0.2** | **`PhaseMap` totality validation + `ADR-phase-map-totality-validation`** |
| **Platform Integration** | **8.8** | **9.0** | **+0.2** | **visionOS CI, `VisionOSIntegration.md`, UI smoke tests, and `Store.preview()`** |

**Nature of this update:** v6.1 mainly improves evaluation accuracy. Some previous deductions overstated testing gaps or described an outdated public surface.

---

## VI. Remaining Work

### P2 — Conditional Backlog

| Item | Trigger Condition |
|------|-------------------|
| `SelectedStore` 4+ dependency / opaque selector optimization | repeated real-world usage + profiling evidence |
| `StoreSupport.swift` file split | contributor onboarding friction |

**Evaluation note:** These are not current defects. They are intentionally deferred backlog items that should open only when actual usage justifies them.

### P3 — Lower Priority

| Item | Note |
|------|------|
| Official `swift-metrics` adapter | `.sink()` already enables lightweight integration |
| Dedicated immersive/spatial sample | `VisionOSIntegration.md` documents ownership boundaries, but there is no dedicated sample yet |
| `PhaseMap` authoring polish | helper ideas remain optional until real repetition appears |

---

## VII. Cumulative Improvement Log

### v1 -> v2 (8.07 -> 8.19)

- Physical `Store` file split
- Three-tier binding contract
- Animation surface separation
- Stronger principle gates

### v2 -> v3 (8.19 -> 8.48)

- `@InnoFlow` macro synthesis for `CasePath` / `CollectionActionPath`
- Built-in `IfLet` / `IfCaseLet`
- `StoreInstrumentation` with 5 hooks and 4 drop reasons
- `ManualTestClock`
- O(1) collection offset cache
- Functor / Monoid law tests
- Multi-platform CI (macOS, iOS, tvOS, watchOS)

### v3 -> v4 (8.48 -> 8.93)

- `SelectedStore` three-tier selection API
- `ProjectionObserverRegistry` dependency-based refresh
- `SelectionCache` / `CollectionScopeCache` callsite validation
- `EffectRuntime` actor split
- `Store + EffectDriver` separation

### v4 -> v5 (8.93 -> 9.14)

- **`PhaseMap<State, Action, Phase>`** for declarative phase ownership
- **`ActionMatcher<Action, Payload>`** for payload-aware action matching
- **`PhaseMappedReducer`** as a post-reduce decorator with mutation restore
- **`PhaseMap` DSL** with `From` / `On` builders and six `On` overloads
- **`derivedGraph`** automatic derivation
- **`PhaseMap+Testing`** conveniences
- Canonical sample migration to `PhaseMap`

### v5 -> v6.1 (9.14 -> 9.20)

- **`PhaseMap` totality validation** via `validationReport`, `PhaseMapExpectedTrigger`, and `PhaseMapValidationReport`
- **Two new ADRs**: declarative `PhaseMap` and `PhaseMap` totality validation
- **`ARCHITECTURE_CONTRACT.md`** enforced in CI
- **`VisionOSIntegration.md`** for visionOS ownership guidance
- **Expanded CI** with visionOS package builds and canonical sample UI smoke tests
- **Expanded principle gates** for accessibility, visionOS, `PhaseMap` docs, and underscore-stripped action-path naming
- **`Store.preview()`** ergonomics for previews
- **`PhaseMap` edge-case tests** for direct mutation crashes, undeclared targets, ordering, and `On(where:)`
- 177+14 core tests reached
- **v6.1 evaluation correction:** removed outdated deductions around `PhaseMap` testing and `IfCaseLet` API shape

---

### Conclusion

InnoFlow 3.0.0 remains **Production Ready+ at 9.20 / 10 (92.0 / 100)**. The latest iteration primarily tightened contracts, expanded platform/documentation coverage, and corrected prior evaluation drift rather than reopening core architecture. The remaining work is mostly conditional backlog and ecosystem polish, not structural framework repair.
