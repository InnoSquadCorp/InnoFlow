# Dependency Patterns

Canonical patterns for wiring dependencies into InnoFlow reducers.

This document is the source-of-truth authoring style for dependency injection
in InnoFlow features. It complements but does **not** replace the rule in
[`ARCHITECTURE_CONTRACT.md`](../ARCHITECTURE_CONTRACT.md) ("Core ownership"):

> Construction-time `Dependencies` bundles enter reducers explicitly. InnoFlow
> does not own the dependency graph.

Follow one of the three patterns below. All four canonical samples in
`Examples/InnoFlowSampleApp` apply them directly — the samples are the
executable companion to this document.

---

## 1. Principle recap

The authoring contract has a single root rule:

**Dependencies enter the reducer explicitly at construction time as an
`init`-parameter bundle. They are stored on the reducer as `let
dependencies: Dependencies`. Reducers never resolve dependencies at runtime.**

Concretely that means:

- No global singleton access (`SomeService.shared`) inside reducers.
- No property-wrapper-driven lookup like `@Dependency(\.apiClient)`.
- No implicit thread-local or task-local registry read.
- No "dependency container" type inside `InnoFlow` itself.

The app, coordinator, or preview code owns the dependency graph and snapshots
it into a `Dependencies` value **once** when the `Store` is built. Every
`.run { send, context in ... }` closure then captures from that frozen bundle.

This is strictly less convenient than a magic-resolver DSL and that is the
point — the dependency flow stays visible at every call site, so scope,
substitution, and cancellation all remain local concerns.

---

## 2. Pattern A — single service

Use when the feature has exactly one collaborator (a service, a repository, a
clock).

```swift
@InnoFlow
struct PhaseDrivenTodoFeature {
  struct Dependencies: Sendable {
    let todoService: any SampleTodoServiceProtocol
  }

  let dependencies: Dependencies

  init(
    dependencies: Dependencies = .init(todoService: SampleTodoService())
  ) {
    self.dependencies = dependencies
  }

  init(todoService: any SampleTodoServiceProtocol) {
    self.init(dependencies: .init(todoService: todoService))
  }

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .loadTodos:
        let todoService = dependencies.todoService
        return .run { send, context in
          try await context.checkCancellation()
          let todos = try await todoService.loadTodos(shouldFail: false)
          await send(._loaded(todos))
        }
      // ...
      }
    }
  }
}
```

Canonical reference:
[`PhaseDrivenFSMDemo.swift`](../Examples/InnoFlowSampleApp/InnoFlowSampleAppPackage/Sources/InnoFlowSampleAppFeature/PhaseDrivenFSMDemo.swift).

Notes:

- `Dependencies: Sendable` is mandatory — the bundle crosses into `.run`
  closures which execute off the main actor.
- The `init(dependencies:)` overload with a `.default` is what production /
  previews call. The convenience `init(service:)` is for tests — it keeps
  `TestStore` call sites from re-declaring the bundle struct.
- `let todoService = dependencies.todoService` outside the `.run` closure
  captures the specific leaf, not the full bundle. This minimises the
  transitive `Sendable` surface crossing into the effect body.

## 3. Pattern B — composite bundle

Use when the feature has two or more collaborators that co-vary (a repository
+ a clock, or a service + a logger + a session). The bundle itself is the
unit of substitution.

```swift
@InnoFlow
struct OfflineFirstFeature {
  struct Dependencies: Sendable {
    let repository: any DraftRepositoryProtocol
    let debounceDuration: Duration
  }

  let dependencies: Dependencies

  init(
    dependencies: Dependencies = .init(
      repository: SampleDraftRepository(),
      debounceDuration: .milliseconds(300)
    )
  ) {
    self.dependencies = dependencies
  }

  init(
    repository: any DraftRepositoryProtocol,
    debounceDuration: Duration = .milliseconds(300)
  ) {
    self.init(dependencies: .init(
      repository: repository,
      debounceDuration: debounceDuration
    ))
  }

  // ...
}
```

Canonical reference:
[`OfflineFirstDemo.swift`](../Examples/InnoFlowSampleApp/InnoFlowSampleAppPackage/Sources/InnoFlowSampleAppFeature/OfflineFirstDemo.swift)
and
[`AuthenticationFlowDemo.swift`](../Examples/InnoFlowSampleApp/InnoFlowSampleAppPackage/Sources/InnoFlowSampleAppFeature/AuthenticationFlowDemo.swift).

Notes:

- Keep **configuration values** (durations, retry counts, feature flags)
  inside the same bundle as their collaborators. Do not mix a "config" struct
  and a "services" struct unless the consumers are actually distinct — two
  bundles mean two init paths and two substitution points.
- If the bundle grows past roughly five members, consider whether the feature
  itself should be split. `Dependencies` bloat is a downstream signal of a
  feature with too many responsibilities.

## 4. Pattern C — framework-provided dependencies

InnoFlow ships a handful of dependencies that reducers can read without
authoring their own protocol.

### `StoreClock` / `EffectContext.sleep`

The store injects a clock at construction time. Reducer `.run` closures read
it through `context.sleep(for:)` — they do **not** declare a clock field in
`Dependencies`.

```swift
case .subscribe:
  state.isSubscribed = true
  return .run { send, context in
    var counter = 0
    while true {
      try await context.sleep(for: dependencies.tickInterval)
      try await context.checkCancellation()
      counter += 1
      await send(._tick(counter))
    }
  }
  .cancellable("realtime-stream", cancelInFlight: true)
```

The *interval* stays in the feature's own `Dependencies` (see
[`RealtimeStreamDemo.swift`](../Examples/InnoFlowSampleApp/InnoFlowSampleAppPackage/Sources/InnoFlowSampleAppFeature/RealtimeStreamDemo.swift)).
The *clock implementation* is swapped at the `Store` / `TestStore` boundary:

- Production and previews: `Store(reducer: ...)` (default `.continuous`) or
  `Store.preview(reducer: ..., clock: .continuous)`.
- Tests: `let clock = ManualTestClock(); TestStore(reducer: ..., clock: clock)`.

### `EffectContext.checkCancellation`

`context.checkCancellation()` is the only cooperative cancellation point
reducers need. It reads the task-local cancel flag set by `.cancel("id")` and
throws `CancellationError` when that flag fires. Reducers should place a
`try await context.checkCancellation()` before any `await send(...)` that
follows a non-trivial `await`.

### `StoreInstrumentation`

Construction-time observer for pipeline events. Injected on the `Store`, not
the reducer — it is not part of any feature's `Dependencies`.

---

## 5. Testing: three substitution scenarios

### Scenario 1 — stub a protocol implementation

```swift
private struct MockAuthService: AuthServiceProtocol {
  func submitCredentials(
    username: String,
    password: String
  ) async throws -> AuthServiceChallenge {
    if username.contains("mfa") {
      return .mfaRequired(challengeID: "challenge-\(username)")
    }
    if password == "wrong" {
      throw AuthServiceError(errorDescription: "Invalid credentials")
    }
    return .authenticated(sessionID: "session-\(password)")
  }

  func submitMFA(code: String) async throws -> AuthServiceResult {
    if code == "000000" {
      throw AuthServiceError(errorDescription: "MFA code rejected")
    }
    return .authenticated(sessionID: "session-mfa-\(code)")
  }
}

@Test
@MainActor
func authenticationFlowSuccess() async {
  let feature = AuthenticationFlowFeature(authService: MockAuthService())
  let store = TestStore(reducer: feature)
  // ...
}
```

Pattern A's convenience init (`init(authService:)`) means test code never has
to reconstruct the `Dependencies` struct by hand.

### Scenario 2 — pin the clock

```swift
let clock = ManualTestClock()
let store = TestStore(
  reducer: RealtimeStreamFeature(tickInterval: .milliseconds(100)),
  clock: clock
)
await store.send(.subscribe)

while await clock.sleeperCount < 1 { await Task.yield() }
await clock.advance(by: .milliseconds(100))

await store.receive(._tick(1))
```

`ManualTestClock.sleeperCount` is the right signal to wait on before
`advance(by:)` — polling it avoids fragile `await Task.yield()` counts. See
[`RealtimeStreamDemo`](../Examples/InnoFlowSampleApp/InnoFlowSampleAppPackage/Sources/InnoFlowSampleAppFeature/RealtimeStreamDemo.swift)
tests.

### Scenario 3 — in-memory repository

```swift
private actor MockDraftRepository: DraftRepositoryProtocol {
  var shouldFail = false
  func save(id: UUID, title: String) async throws {
    if shouldFail {
      shouldFail = false
      throw DraftRepositoryError(errorDescription: "stub")
    }
  }
}
```

Actor-based repositories compose naturally with InnoFlow because the reducer
already assumes all collaborator state crosses actor boundaries. The fake
owns its own invariants; the feature contract does not change.

---

## 6. Previews

Previews follow the same construction-time pattern as production code.

```swift
#Preview("Offline-First") {
  NavigationStack {
    OfflineFirstDemoView()
  }
}
```

For a custom preview with a pinned clock or in-memory repository:

```swift
#Preview("Offline-First · debounce 1s") {
  let store = Store.preview(
    reducer: OfflineFirstFeature(
      repository: PreviewDraftRepository(),
      debounceDuration: .seconds(1)
    ),
    initialState: .init()
  )
  return OfflineFirstDemoView(store: store)
}
```

Teams that have a stable set of preview fixtures can expose a
`Dependencies.preview` static builder on each feature and reference it from
every `#Preview` declaration. That is a convention, not a framework API —
`Store.preview(...)` remains the single entry point.

---

## 7. Anti-patterns

The following are explicitly **not** part of the InnoFlow authoring model.
The project's charter rules them out:

- **Global singletons inside reducers.** `SomeService.shared.call()` pulled
  straight from a reducer body erases the substitution boundary. Test doubles
  become process-global monkey patches.
- **Property-wrapper-driven resolution** (`@Dependency(\.apiClient)`,
  `@DependencyField`, etc.). The charm is real, but the cost is hidden
  control flow: you can no longer read the dependency graph from a single
  `init` signature, and the registry becomes an implicit runtime concern that
  outlives the reducer's own lifetime.
- **Runtime `resolve(type:)` / service locator calls.** Same failure mode as
  the property wrapper. The fix is always "look at the registration file" —
  which is exactly the ambiguity the construction-time bundle removes.
- **Magic `@InnoFlowDependency` macros that synthesize lookup.** InnoFlow
  macros produce CasePaths and collection paths; they never synthesize a
  registry read.
- **Mutable `Dependencies` instances.** The bundle is snapshotted at `init`.
  Do not declare `var` fields or expose a mutation entry point. If the
  feature needs to *act on* a dependency change (e.g. log-out resets an auth
  token), model that as an `Action`, not as a dependency mutation.

References:
[`CLAUDE.md`](../CLAUDE.md) ("Cross-framework ownership"),
[`ARCHITECTURE_CONTRACT.md`](../ARCHITECTURE_CONTRACT.md) ("Core ownership").

---

## 8. Why InnoFlow does not ship a DI container

A framework-level DI container would solve call-site noise at the cost of
the very property that makes InnoFlow reasoning local: every dependency a
reducer relies on is visible at its construction site.

A registry-style DSL — regardless of implementation (property wrapper, macro,
task-local dictionary) — inverts that relationship. The reducer now trusts
that *some* caller registered *some* implementation for a protocol-keyed
slot, and the substitution boundary moves out of the reducer's own init into
a shared ambient table. That shared table is the precise mechanism that
turns "swap this service for a test" into "reconcile the global registry for
this test pass" — which is exactly the flakiness we want tests not to have.

Features that *feel* like they need a container almost always resolve to one
of the three patterns above, optionally with a `Dependencies.preview` static
convenience on each feature. When the answer is "we have 40 features and 15
shared services," the right tool is a `ServiceLocator` owned at the app
boundary that hands out frozen `Dependencies` values to each feature — not
an InnoFlow-level abstraction.

The decision is final: InnoFlow will not ship a DI container or a
`@Dependency`-style macro. Teams that want one can layer it on top without
touching InnoFlow.
