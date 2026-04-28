# Cross-Framework Boundaries

Canonical boundary guide for attaching `InnoFlow` to navigation, transport,
and dependency-graph libraries without collapsing ownership.

Use this document when the team asks one of these questions:

- "We already use a router. Where does InnoFlow stop?"
- "Can a reducer own reconnect or websocket lifecycle?"
- "How do I pass services from InnoDI, Factory, Resolver, or my own container?"

`InnoFlow` owns business and domain transitions only. The app or coordinator
layer owns route stacks, transport/session lifecycle, and dependency graph
construction.

If you need the reducer-side dependency rules in detail, continue with
[`DEPENDENCY_PATTERNS.md`](./DEPENDENCY_PATTERNS.md).

## Boundary Matrix

| Axis | Owned by InnoFlow | Owned outside InnoFlow | Canonical reference |
| --- | --- | --- | --- |
| Navigation | business intent, route requests, feature-local state | `NavigationStack`, router stores, scene/window coordination | `RouterCompositionDemo`, `ARCHITECTURE_CONTRACT.md` |
| Transport | domain events emitted from adapter callbacks | socket lifecycle, reconnect policy, protocol/session management | `BidirectionalWebSocketDemo`, `EffectTimingBaseline.md` |
| Dependency injection | explicit `Dependencies` bundle consumed by reducer | container setup, app graph construction, preview/test substitution roots | `DEPENDENCY_PATTERNS.md`, `AuthenticationFlowDemo`, `OfflineFirstDemo` |

## 1. Navigation Boundary

Navigation state belongs to the app boundary. A reducer may emit business
intent such as "user tapped checkout" or "authentication finished", but it
should not become the source of truth for concrete route stacks.

Attach InnoFlow to a navigation library like this:

- SwiftUI `NavigationStack`: the view or app shell mutates `NavigationPath`
  when the store emits a route intent.
- `InnoRouter`: app-layer router state owns the stack; reducers send
  feature-domain actions that the coordinator translates into route changes.
- UIKit coordinators / MVVM-C: coordinators subscribe to reducer output and
  push or dismiss view controllers.
- `visionOS`: immersive-space open/close orchestration remains in the app
  layer even when the business phase lives in the reducer.

### Example

```swift
import InnoFlow
import SwiftUI

@InnoFlow
struct CheckoutFeature {
  struct State: Equatable, Sendable, DefaultInitializable {
    var cartTotal: Decimal = 0
    var isSubmitting = false
  }

  enum Action: Equatable, Sendable {
    case checkoutTapped
    case _submissionFinished
  }

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .checkoutTapped:
        state.isSubmitting = true
        return .none
      case ._submissionFinished:
        state.isSubmitting = false
        return .none
      }
    }
  }
}

struct CheckoutScreen: View {
  @State private var store = Store(reducer: CheckoutFeature())
  @State private var path = NavigationPath()

  var body: some View {
    CheckoutView(store: store, onCheckoutFinished: {
      path.append(Route.receipt)
    })
    .navigationDestination(for: Route.self) { route in
      ReceiptView(route: route)
    }
  }
}
```

### Anti-patterns

- Do not duplicate `NavigationPath`, route stacks, or router-owned session
  state inside reducer state.
- Do not mirror route pushes and pops as `PhaseMap` transitions.
- Do not make a feature reducer import a router package just to mutate a
  concrete stack.

See also:

- [`ARCHITECTURE_CONTRACT.md`](../ARCHITECTURE_CONTRACT.md)
- [`PHASE_DRIVEN_MODELING.md`](../PHASE_DRIVEN_MODELING.md)
- [`RouterCompositionDemo.swift`](../Examples/InnoFlowSampleApp/InnoFlowSampleAppPackage/Sources/InnoFlowSampleAppFeature/RouterCompositionDemo.swift)

## 2. Transport Boundary

Transport libraries own socket/session lifecycle, reconnect windows,
back-pressure, protocol details, and connection health. `InnoFlow` reducers
own the business reaction to already-translated domain events.

Attach InnoFlow to a transport library like this:

- `URLSession`: an injected service or adapter performs requests and emits
  reducer actions with parsed domain results.
- `InnoNetworkWebSocket`: a sample-only adapter owns the socket task, event
  stream, retryable peer-close classification, reconnect trigger, retry budget,
  and `send(_:)`; the reducer only sees domain actions such as `.connectTapped`,
  `._messageReceived`, or `._connectionLost`.
- SSE / gRPC / MQTT: the coordinator or adapter bridges protocol events into
  reducer actions; reducers never become the transport state machine.

### Example

```swift
import InnoFlow

protocol ChatTransport: Sendable {
  func connect() async
  func disconnect() async
  func send(text: String) async throws
  func events() -> AsyncStream<ChatTransportEvent>
}

enum ChatTransportEvent: Equatable, Sendable {
  case connected
  case disconnected
  case message(String)
}

@InnoFlow
struct ChatFeature {
  struct State: Equatable, Sendable {
    var isConnected = false
    var messages: [String] = []
  }

  struct Dependencies: Sendable {
    let transport: any ChatTransport
  }

  let dependencies: Dependencies

  enum Action: Equatable, Sendable {
    case connectTapped
    case disconnectTapped
    case sendTapped(String)
    case _transportEvent(ChatTransportEvent)
  }

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .connectTapped:
        let transport = dependencies.transport
        return .run { send, _ in
          await transport.connect()
          for await event in transport.events() {
            await send(._transportEvent(event))
          }
        }
      case .disconnectTapped:
        return .run { _, _ in await dependencies.transport.disconnect() }
      case .sendTapped(let text):
        return .run { _, _ in try await dependencies.transport.send(text: text) }
      case ._transportEvent:
        return .none
      }
    }
  }
}
```

### Anti-patterns

- Do not put raw websocket task state, ping/pong management, or reconnect
  counters into the reducer unless they are true business state.
- Do not classify retryable peer closes inside the reducer; keep that policy in
  the adapter boundary and emit a business-facing reconnecting event only when
  the adapter still has reconnect budget remaining.
- Do not let `PhaseMap` become a transport/session lifecycle graph.
- Do not spread protocol error decoding across multiple reducers; keep it in
  the adapter boundary and send domain actions inward.

See also:

- [`ARCHITECTURE_CONTRACT.md`](../ARCHITECTURE_CONTRACT.md)
- [`BidirectionalWebSocketDemo.swift`](../Examples/InnoFlowSampleApp/InnoFlowSampleAppPackage/Sources/InnoFlowSampleAppFeature/BidirectionalWebSocketDemo.swift)
- [Effect Timing Baseline DocC](https://github.com/InnoSquadCorp/InnoFlow/blob/main/Sources/InnoFlow/InnoFlow.docc/EffectTimingBaseline.md)

## 3. Dependency Injection Boundary

Dependency graphs stay outside `InnoFlow`. Reducers receive explicit bundles at
construction time and store them as `let dependencies`.

Attach InnoFlow to a DI library like this:

- `InnoDI`: resolve services in the app or coordinator, then build the
  feature's `Dependencies` bundle explicitly.
- Factory / Resolver / Needle / custom containers: resolve outside the reducer,
  freeze values into a bundle, and pass that bundle into the `Store`.
- Plain Swift composition roots: construct services directly without a
  container and still pass them explicitly.

### Example

```swift
import InnoFlow

@InnoFlow
struct AuthenticationFeature {
  struct Dependencies: Sendable {
    let authService: any AuthServiceProtocol
    let debounceDuration: Duration
  }

  let dependencies: Dependencies

  init(
    dependencies: Dependencies = .init(
      authService: LiveAuthService(),
      debounceDuration: .milliseconds(300)
    )
  ) {
    self.dependencies = dependencies
  }

  init(
    authService: any AuthServiceProtocol,
    debounceDuration: Duration = .milliseconds(300)
  ) {
    self.init(dependencies: .init(
      authService: authService,
      debounceDuration: debounceDuration
    ))
  }
}
```

### Anti-patterns

- Do not resolve services from singletons or property-wrapper lookup inside a
  reducer body.
- Do not add an `InnoFlow`-owned service locator to hide app composition.
- Do not split "services" and "config" into multiple bundles unless the
  substitution boundaries are genuinely different.

See also:

- [`DEPENDENCY_PATTERNS.md`](./DEPENDENCY_PATTERNS.md)
- [`AuthenticationFlowDemo.swift`](../Examples/InnoFlowSampleApp/InnoFlowSampleAppPackage/Sources/InnoFlowSampleAppFeature/AuthenticationFlowDemo.swift)
- [`OfflineFirstDemo.swift`](../Examples/InnoFlowSampleApp/InnoFlowSampleAppPackage/Sources/InnoFlowSampleAppFeature/OfflineFirstDemo.swift)

## Choosing the Boundary

Use this rule of thumb:

- If the state answers a business question, it can live in the reducer.
- If the state answers a routing/runtime/transport/container question, keep it
  outside and inject the translated result.

Typical translations:

- router callback -> reducer action
- transport event -> reducer action
- DI container resolution -> `Dependencies` bundle

That separation keeps reducers deterministic, samples readable, and framework
contracts stable across SwiftUI, UIKit, `InnoRouter`, `InnoNetwork`, and custom
app infrastructure.
