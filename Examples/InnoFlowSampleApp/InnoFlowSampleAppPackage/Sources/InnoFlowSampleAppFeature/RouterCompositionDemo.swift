import InnoFlow
import SwiftUI

enum RouterDemoRoute: Hashable, Sendable {
  case dashboard
  case detail(id: String)
}

@InnoFlow
struct RouterLoginFeature {
  struct State: Equatable, Sendable, DefaultInitializable {
    @BindableField var username = "demo@innosquad.com"
    var isSubmitting = false
    var isAuthenticated = false
    var authVersion = 0
    var log: [String] = []
  }

  enum Action: Equatable, Sendable {
    case setUsername(String)
    case submit
    case logout
    case _loginSucceeded
  }

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .setUsername(let username):
        state.username = username
        return .none

      case .submit:
        guard !state.username.trimmingCharacters(in: .whitespaces).isEmpty else {
          return .none
        }
        state.isSubmitting = true
        state.log.append("submit login")
        return .run { send, context in
          do {
            try await context.sleep(for: .milliseconds(150))
            try await context.checkCancellation()
            await send(._loginSucceeded)
          } catch is CancellationError {
            return
          } catch {
            return
          }
        }
        .cancellable("router-login", cancelInFlight: true)

      case ._loginSucceeded:
        state.isSubmitting = false
        state.isAuthenticated = true
        state.authVersion += 1
        state.log.append("login succeeded")
        return .none

      case .logout:
        state.isSubmitting = false
        state.isAuthenticated = false
        state.log.append("logout")
        return .cancel("router-login")
      }
    }
  }
}

@MainActor
@Observable
final class RouterCompositionCoordinator {
  let loginStore = Store(reducer: RouterLoginFeature())
  var path: [RouterDemoRoute] = []

  private let protectedDetailID: String
  private(set) var pendingRoute: RouterDemoRoute?
  private var lastHandledAuthVersion = 0

  init(
    pendingRoute: RouterDemoRoute? = nil,
    protectedDetailID: String = "invoice-42"
  ) {
    self.pendingRoute = pendingRoute
    self.protectedDetailID = protectedDetailID
  }

  func queueProtectedDetail() {
    pendingRoute = .detail(id: protectedDetailID)
  }

  func submitLogin() {
    loginStore.send(.submit)
  }

  func openProtectedDetail() {
    if loginStore.isAuthenticated {
      if path.first != .dashboard {
        path = [.dashboard]
      }
      path.append(.detail(id: protectedDetailID))
    } else {
      queueProtectedDetail()
    }
  }

  func logout() {
    pendingRoute = nil
    lastHandledAuthVersion = 0
    loginStore.send(.logout)
    path = []
  }

  func syncNavigationWithDomainState() {
    guard loginStore.isAuthenticated else { return }
    guard lastHandledAuthVersion != loginStore.authVersion else { return }
    lastHandledAuthVersion = loginStore.authVersion

    var nextPath: [RouterDemoRoute] = [.dashboard]
    if let pendingRoute {
      nextPath.append(pendingRoute)
      self.pendingRoute = nil
    }
    path = nextPath
  }
}

struct RouterCompositionDemoView: View {
  @State private var coordinator: RouterCompositionCoordinator

  init(pendingRoute: RouterDemoRoute? = Self.pendingRouteFromEnvironment()) {
    _coordinator = State(initialValue: RouterCompositionCoordinator(pendingRoute: pendingRoute))
  }

  var body: some View {
    NavigationStack(path: $coordinator.path) {
      RouterLoginRootView(coordinator: coordinator)
        .navigationDestination(for: RouterDemoRoute.self) { route in
          switch route {
          case .dashboard:
            RouterDashboardView(coordinator: coordinator)
          case .detail(let id):
            RouterDetailView(id: id, coordinator: coordinator)
          }
        }
    }
    .onChange(of: coordinator.loginStore.authVersion, initial: false) { _, _ in
      coordinator.syncNavigationWithDomainState()
    }
    .navigationTitle("App-Boundary Navigation")
  }

  private static func pendingRouteFromEnvironment() -> RouterDemoRoute? {
    guard
      let pendingDetailID = ProcessInfo.processInfo.environment["INNOFLOW_ROUTER_PENDING_DETAIL_ID"]
    else {
      return nil
    }
    return .detail(id: pendingDetailID)
  }
}

private struct RouterLoginRootView: View {
  let coordinator: RouterCompositionCoordinator

  var body: some View {
    ScrollView {
      VStack(spacing: 16) {
        DemoCard(
          title: "What this demonstrates",
          summary:
            "`InnoFlow` owns login state and async success. The coordinator reads domain state and mutates a local SwiftUI route stack only at the app boundary."
        )

        VStack(alignment: .leading, spacing: 12) {
          TextField(
            "Email",
            text: coordinator.loginStore.binding(
              \.$username,
              send: RouterLoginFeature.Action.setUsername
            )
          )
          .textFieldStyle(.roundedBorder)
          .accessibilityIdentifier("router.username")
          .accessibilityLabel("Demo email")
          .accessibilityHint("Enter the account used for the app-boundary navigation example")

          Button(coordinator.loginStore.isSubmitting ? "Signing In..." : "Sign In") {
            coordinator.submitLogin()
          }
          .buttonStyle(.borderedProminent)
          .disabled(coordinator.loginStore.isSubmitting)
          .accessibilityIdentifier("router.sign-in")
          .accessibilityLabel(coordinator.loginStore.isSubmitting ? "Signing in" : "Sign in")
          .accessibilityHint(
            "Authenticates the reducer-owned login state before the coordinator replays pending routes"
          )

          Button("Queue Protected Detail While Logged Out") {
            coordinator.queueProtectedDetail()
          }
          .buttonStyle(.bordered)
          .accessibilityIdentifier("router.queue-protected-detail")
          .accessibilityHint(
            "Queues a protected destination that will open after authentication succeeds")

          if let pendingRoute = coordinator.pendingRoute {
            Text("Pending route: \(describe(route: pendingRoute))")
              .font(.footnote)
              .foregroundStyle(.secondary)
              .accessibilityIdentifier("router.pending-route")
          }
        }
        .padding()
        .background(Color.primary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

        LogSection(title: "Login Domain Log", entries: coordinator.loginStore.log)
      }
      .padding()
    }
  }
}

private struct RouterDashboardView: View {
  let coordinator: RouterCompositionCoordinator

  var body: some View {
    VStack(spacing: 16) {
      DemoCard(
        title: "Dashboard",
        summary:
          "The route stack already moved into dashboard. Opening detail now is a pure app-layer navigation concern."
      )

      Button("Open Protected Detail") {
        coordinator.openProtectedDetail()
      }
      .buttonStyle(.borderedProminent)
      .accessibilityIdentifier("router.open-protected-detail")
      .accessibilityHint("Pushes the protected detail route on the local SwiftUI navigation stack")

      Button("Logout") {
        coordinator.logout()
      }
      .buttonStyle(.bordered)
      .accessibilityIdentifier("router.logout")

      LogSection(title: "Login Domain Log", entries: coordinator.loginStore.log)
    }
    .padding()
  }
}

private struct RouterDetailView: View {
  let id: String
  let coordinator: RouterCompositionCoordinator

  var body: some View {
    VStack(spacing: 16) {
      Text("Protected detail for \(id)")
        .font(.headline)
        .accessibilityIdentifier("router.detail-title")

      Button("Back to Dashboard") {
        coordinator.path = [.dashboard]
      }
      .buttonStyle(.bordered)
      .accessibilityIdentifier("router.back-to-dashboard")
      .accessibilityHint("Pops the detail route and returns to the dashboard")
    }
    .padding()
  }
}

private func describe(route: RouterDemoRoute) -> String {
  switch route {
  case .dashboard:
    "dashboard"
  case .detail(let id):
    "detail(\(id))"
  }
}

#Preview("App-Boundary Navigation") {
  NavigationStack {
    RouterCompositionDemoView()
  }
}
