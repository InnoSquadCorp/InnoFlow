import InnoFlow
import SwiftUI

@InnoFlow
struct ReadinessChildFeature {
  struct State: Equatable, Sendable {
    let name: String
    var isReady = false
    var log: [String] = []
  }

  enum Action: Equatable, Sendable {
    case markReady
    case reset
  }

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .markReady:
        state.isReady = true
        state.log.append("\(state.name) ready")
        return .none

      case .reset:
        state.isReady = false
        state.log = []
        return .none
      }
    }
  }
}

@InnoFlow
struct OrchestrationFeature {
  struct State: Equatable, Sendable, DefaultInitializable {
    var isRefreshing = false
    var isBootstrapping = false
    var isSyncing = false
    var profile = ReadinessChildFeature.State(name: "profile")
    var permissions = ReadinessChildFeature.State(name: "permissions")
    var bootstrapReady: Set<String> = []
    var syncProgress = 0
    var refreshLog: [String] = []
    var bootstrapLog: [String] = []
    var syncLog: [String] = []
  }

  enum Action: Equatable, Sendable {
    case refreshDashboard
    case profile(ReadinessChildFeature.Action)
    case permissions(ReadinessChildFeature.Action)
    case _refreshFinished
    case startBootstrap
    case cancelBootstrap
    case _bootstrapCompleted(String)
    case startSync
    case cancelSync
    case _syncProgress(Int)
    case _syncFinished
  }

  private static let bootstrapSteps: [(name: String, delay: Duration)] = [
    ("profile", .milliseconds(50)),
    ("permissions", .milliseconds(90)),
    ("analytics", .milliseconds(130)),
  ]

  var body: some Reducer<State, Action> {
    CombineReducers {
      Reduce { state, action in
        switch action {
        case .refreshDashboard:
          state.isRefreshing = true
          state.refreshLog = ["refresh requested"]
          return .concatenate(
            .send(.profile(.reset)),
            .send(.permissions(.reset)),
            .send(.profile(.markReady)),
            .send(.permissions(.markReady)),
            .send(._refreshFinished)
          )

        case ._refreshFinished:
          state.isRefreshing = false
          state.refreshLog.append("refresh finished")
          return .none

        case .startBootstrap:
          state.isBootstrapping = true
          state.bootstrapReady = []
          state.bootstrapLog = ["bootstrap started"]
          return .merge(
            Self.bootstrapSteps.map { step in
              bootstrapTask(step.name, delay: step.delay)
            }
          )
          .cancellable("bootstrap", cancelInFlight: true)

        case .cancelBootstrap:
          state.isBootstrapping = false
          state.bootstrapLog.append("bootstrap cancelled")
          return .cancel("bootstrap")

        case ._bootstrapCompleted(let name):
          state.bootstrapReady.insert(name)
          state.bootstrapLog.append("\(name) ready")
          if state.bootstrapReady.count == Self.bootstrapSteps.count {
            state.isBootstrapping = false
            state.bootstrapLog.append("bootstrap finished")
          }
          return .none

        case .startSync:
          state.isSyncing = true
          state.syncProgress = 0
          state.syncLog = ["sync started"]
          return .concatenate(
            .send(._syncProgress(10)),
            progressTask(55, delay: .milliseconds(70)),
            progressTask(100, delay: .milliseconds(140)),
            .send(._syncFinished)
          )
          .cancellable("sync-pipeline", cancelInFlight: true)

        case .cancelSync:
          state.isSyncing = false
          state.syncLog.append("sync cancelled")
          return .cancel("sync-pipeline")

        case ._syncProgress(let progress):
          state.syncProgress = progress
          state.syncLog.append("progress \(progress)%")
          return .none

        case ._syncFinished:
          state.isSyncing = false
          state.syncLog.append("sync finished")
          return .none

        case .profile(.markReady):
          state.refreshLog.append("profile child finished")
          return .none

        case .permissions(.markReady):
          state.refreshLog.append("permissions child finished")
          return .none

        case .profile(.reset), .permissions(.reset):
          return .none
        }
      }

      Scope(
        state: \.profile,
        action: Action.profileCasePath,
        reducer: ReadinessChildFeature()
      )

      Scope(
        state: \.permissions,
        action: Action.permissionsCasePath,
        reducer: ReadinessChildFeature()
      )
    }
  }

  private func bootstrapTask(_ name: String, delay: Duration) -> EffectTask<Action> {
    .run { send, context in
      do {
        try await context.sleep(for: delay)
        try await context.checkCancellation()
        await send(._bootstrapCompleted(name))
      } catch is CancellationError {
        return
      } catch {
        debugPrint("bootstrapTask(\(name)) unexpected error: \(error)")
        return
      }
    }
  }

  private func progressTask(_ progress: Int, delay: Duration) -> EffectTask<Action> {
    .run { send, context in
      do {
        try await context.sleep(for: delay)
        try await context.checkCancellation()
        await send(._syncProgress(progress))
      } catch is CancellationError {
        return
      } catch {
        debugPrint("progressTask(\(progress)) unexpected error: \(error)")
        return
      }
    }
  }
}

struct OrchestrationDemoView: View {
  @State private var store = Store(reducer: OrchestrationFeature())

  var body: some View {
    ScrollView {
      VStack(spacing: 16) {
        DemoCard(
          title: "What this demonstrates",
          summary:
            "Parent-child orchestration, cancellation fan-out for merged work, and a long-running progress pipeline composed with `concatenate`."
        )

        VStack(alignment: .leading, spacing: 12) {
          Text("Parent-Child Refresh")
            .font(.headline)
          Button(store.isRefreshing ? "Refreshing..." : "Refresh Dashboard") {
            store.send(.refreshDashboard)
          }
          .buttonStyle(.borderedProminent)
          .disabled(store.isRefreshing)
          .accessibilityLabel(store.isRefreshing ? "Refreshing dashboard" : "Refresh dashboard")
          .accessibilityHint("Resets both child features and queues their ready actions")

          HStack {
            Label(
              store.profile.isReady ? "Profile ready" : "Profile pending",
              systemImage: "person.crop.circle")
            Spacer()
            Label(
              store.permissions.isReady ? "Permissions ready" : "Permissions pending",
              systemImage: "lock.shield"
            )
          }
          .font(.footnote)

          LogSection(title: "Refresh Log", entries: store.refreshLog)
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        VStack(alignment: .leading, spacing: 12) {
          Text("Cancellation Fan-Out")
            .font(.headline)
          HStack {
            Button(store.isBootstrapping ? "Restart Bootstrap" : "Start Bootstrap") {
              store.send(.startBootstrap)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel(store.isBootstrapping ? "Restart bootstrap" : "Start bootstrap")
            .accessibilityHint("Begins the merged bootstrap tasks for the orchestration demo")

            Button("Cancel") {
              store.send(.cancelBootstrap)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Cancel bootstrap")
            .accessibilityHint("Stops the merged bootstrap tasks before every dependency is ready")
          }

          Text("Completed: \(store.bootstrapReady.sorted().joined(separator: ", "))")
            .font(.footnote)
            .foregroundStyle(.secondary)

          LogSection(title: "Bootstrap Log", entries: store.bootstrapLog)
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        VStack(alignment: .leading, spacing: 12) {
          Text("Long-Running Progress Pipeline")
            .font(.headline)

          ProgressView(value: Double(store.syncProgress), total: 100)
            .accessibilityLabel("Sync progress")
            .accessibilityValue("\(store.syncProgress) percent")
          Text("\(store.syncProgress)%")
            .font(.footnote.monospacedDigit())
            .foregroundStyle(.secondary)

          HStack {
            Button(store.isSyncing ? "Restart Sync" : "Start Sync") {
              store.send(.startSync)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel(store.isSyncing ? "Restart sync" : "Start sync")
            .accessibilityHint("Begins the long-running progress pipeline")

            Button("Cancel") {
              store.send(.cancelSync)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Cancel sync")
            .accessibilityHint("Stops the long-running progress pipeline")
          }

          LogSection(title: "Sync Log", entries: store.syncLog)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding()
    }
    .navigationTitle("Orchestration")
  }
}

#Preview("Orchestration") {
  NavigationStack {
    OrchestrationDemoView()
  }
}
