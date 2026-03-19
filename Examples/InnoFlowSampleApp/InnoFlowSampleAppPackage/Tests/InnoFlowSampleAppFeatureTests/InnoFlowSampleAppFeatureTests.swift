import Foundation
import InnoFlow
import InnoFlowTesting
import Testing

@testable import InnoFlowSampleAppFeature

@Suite("InnoFlowSampleAppFeature tests")
struct InnoFlowSampleAppFeatureTests {
  @MainActor
  private func waitForAuthVersion(
    _ target: Int,
    in coordinator: RouterCompositionCoordinator,
    timeout: Duration = .seconds(2)
  ) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      if coordinator.loginStore.authVersion == target {
        return
      }
      await Task.yield()
      try? await Task.sleep(for: .milliseconds(20))
    }

    Issue.record("Expected authVersion to reach \(target) before timing out")
  }

  @Test("Basics demo records queued follow-up increment")
  @MainActor
  func basicsQueuedFollowUp() async {
    let store = TestStore(reducer: BasicsFeature())

    await store.send(.queueIncrement) {
      $0.eventLog = ["queue increment requested"]
    }

    await store.receive(._applyQueuedIncrement) {
      $0.count = 1
      $0.eventLog = ["queue increment requested", "queued follow-up applied -> count 1"]
    }

    await store.assertNoMoreActions()
  }

  @Test("Orchestration demo models parent-child refresh in order")
  @MainActor
  func orchestrationRefreshOrder() async {
    let store = TestStore(reducer: OrchestrationFeature())

    await store.send(.refreshDashboard) {
      $0.isRefreshing = true
      $0.refreshLog = ["refresh requested"]
    }
    await store.receive(.profile(.reset)) {
      $0.profile.isReady = false
      $0.profile.log = []
    }
    await store.receive(.permissions(.reset)) {
      $0.permissions.isReady = false
      $0.permissions.log = []
    }
    await store.receive(.profile(.markReady)) {
      $0.profile.isReady = true
      $0.profile.log = ["profile ready"]
      $0.refreshLog = ["refresh requested", "profile child finished"]
    }
    await store.receive(.permissions(.markReady)) {
      $0.permissions.isReady = true
      $0.permissions.log = ["permissions ready"]
      $0.refreshLog = ["refresh requested", "profile child finished", "permissions child finished"]
    }
    await store.receive(._refreshFinished) {
      $0.isRefreshing = false
      $0.refreshLog = [
        "refresh requested",
        "profile child finished",
        "permissions child finished",
        "refresh finished",
      ]
    }

    await store.assertNoMoreActions()
  }

  @Test("Orchestration demo long-running sync reaches completion")
  @MainActor
  func orchestrationSyncPipeline() async {
    let store = TestStore(reducer: OrchestrationFeature())

    await store.send(.startSync) {
      $0.isSyncing = true
      $0.syncLog = ["sync started"]
    }
    await store.receive(._syncProgress(10)) {
      $0.syncProgress = 10
      $0.syncLog = ["sync started", "progress 10%"]
    }
    await store.receive(._syncProgress(55)) {
      $0.syncProgress = 55
      $0.syncLog = ["sync started", "progress 10%", "progress 55%"]
    }
    await store.receive(._syncProgress(100)) {
      $0.syncProgress = 100
      $0.syncLog = ["sync started", "progress 10%", "progress 55%", "progress 100%"]
    }
    await store.receive(._syncFinished) {
      $0.isSyncing = false
      $0.syncLog = [
        "sync started", "progress 10%", "progress 55%", "progress 100%", "sync finished",
      ]
    }

    await store.assertNoMoreActions()
  }

  @Test("Phase-driven sample follows the documented graph on success")
  @MainActor
  func phaseDrivenSuccess() async {
    let map:
      PhaseMap<
        PhaseDrivenTodoFeature.State, PhaseDrivenTodoFeature.Action,
        PhaseDrivenTodoFeature.State.Phase
      > = PhaseDrivenTodoFeature.phaseMap
    assertValidGraph(
      PhaseDrivenTodoFeature.phaseGraph,
      allPhases: [.idle, .loading, .loaded, .failed],
      root: .idle
    )

    let store = TestStore(
      reducer: PhaseDrivenTodoFeature(
        todoService: MockTodoService()
      )
    )

    await store.send(.loadTodos, through: map) {
      $0.phase = .loading
      $0.errorMessage = nil
    }

    await store.receive(._loaded(MockTodoService.fixtures), through: map) {
      $0.phase = .loaded
      $0.todos = MockTodoService.fixtures
      $0.errorMessage = nil
    }

    await store.assertNoMoreActions()
  }

  @Test("Phase-driven sample fails and recovers to idle when dismissing the error")
  @MainActor
  func phaseDrivenFailureRecovery() async {
    let map:
      PhaseMap<
        PhaseDrivenTodoFeature.State, PhaseDrivenTodoFeature.Action,
        PhaseDrivenTodoFeature.State.Phase
      > = PhaseDrivenTodoFeature.phaseMap
    let store = TestStore(
      reducer: PhaseDrivenTodoFeature(
        todoService: MockTodoService(shouldAlwaysFail: true)
      )
    )

    await store.send(.loadTodos, through: map) {
      $0.phase = .loading
      $0.errorMessage = nil
    }

    await store.receive(._failed("Sample network request failed"), through: map) {
      $0.phase = .failed
      $0.errorMessage = "Sample network request failed"
    }

    await store.send(.dismissError) {
      $0.phase = .idle
      $0.errorMessage = nil
    }

    await store.assertNoMoreActions()
  }

  @Test("Phase-driven sample routes todo child actions by id")
  @MainActor
  func phaseDrivenTodoChildAction() async {
    let store = TestStore(
      reducer: PhaseDrivenTodoFeature(
        todoService: MockTodoService()
      ),
      initialState: .init(
        phase: .loaded,
        todos: MockTodoService.fixtures,
        errorMessage: nil,
        shouldFail: false
      )
    )

    let targetID = MockTodoService.fixtures[1].id
    await store.send(PhaseDrivenTodoFeature.Action.todo(id: targetID, action: .setDone(true))) {
      if let index = $0.todos.firstIndex(where: { $0.id == targetID }) {
        $0.todos[index].isDone = true
      }
    }

    await store.assertNoMoreActions()
  }

  @Test("Orchestration demo child scope can be asserted through ScopedTestStore")
  @MainActor
  func orchestrationScopedChildTesting() async {
    let store = TestStore(reducer: OrchestrationFeature())
    let profile = store.scope(state: \.profile, action: OrchestrationFeature.Action.profileCasePath)

    await profile.send(.markReady) {
      $0.isReady = true
      $0.log = ["profile ready"]
    }

    #expect(store.state.refreshLog == ["profile child finished"])
    await store.assertNoMoreActions()
  }

  @Test("Phase-driven sample collection scope can target a single todo by id")
  @MainActor
  func phaseDrivenScopedTodoTesting() async {
    let store = TestStore(
      reducer: PhaseDrivenTodoFeature(
        todoService: MockTodoService()
      ),
      initialState: .init(
        phase: .loaded,
        todos: MockTodoService.fixtures,
        errorMessage: nil,
        shouldFail: false
      )
    )
    let targetID = MockTodoService.fixtures[2].id
    let todo = store.scope(
      collection: \.todos,
      id: targetID,
      action: PhaseDrivenTodoFeature.Action.todoActionPath
    )

    await todo.send(.setDone(true))

    todo.assert {
      $0.isDone = true
    }
    #expect(store.state.todos.first(where: { $0.id == targetID })?.isDone == true)
    await store.assertNoMoreActions()
  }

  @Test("Router login cancels in-flight submit on logout")
  @MainActor
  func routerLoginLogoutCancelsInFlightSubmit() async {
    let clock = ManualTestClock()
    let store = TestStore(
      reducer: RouterLoginFeature(),
      clock: clock
    )

    await store.send(.submit) {
      $0.isSubmitting = true
      $0.log = ["submit login"]
    }

    await store.send(.logout) {
      $0.isSubmitting = false
      $0.isAuthenticated = false
      $0.log = ["submit login", "logout"]
    }

    await clock.advance(by: .milliseconds(200))
    await store.assertNoMoreActions()
    #expect(store.state.authVersion == 0)
    #expect(store.state.isAuthenticated == false)
  }

  @Test("Router composition replays pending detail when view syncs after auth version changes")
  @MainActor
  func routerCompositionReplaysPendingRoute() async {
    let protectedDetailID = "invoice-99"
    let coordinator = RouterCompositionCoordinator(protectedDetailID: protectedDetailID)
    coordinator.queueProtectedDetail()
    coordinator.submitLogin()

    await waitForAuthVersion(1, in: coordinator)

    coordinator.syncNavigationWithDomainState()

    #expect(coordinator.path == [.dashboard, .detail(id: protectedDetailID)])
    #expect(coordinator.pendingRoute == nil)
  }
}

private struct MockTodoService: SampleTodoServiceProtocol {
  static let fixtures: [SampleTodo] = [
    SampleTodo(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!,
      title: "Document legal transitions"
    ),
    SampleTodo(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000102")!,
      title: "Keep navigation out of the phase graph"
    ),
    SampleTodo(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000103")!,
      title: "Assert transitions with TestStore"
    ),
  ]

  var shouldAlwaysFail = false

  func loadTodos(shouldFail: Bool) async throws -> [SampleTodo] {
    if shouldFail || shouldAlwaysFail {
      throw SampleTodoServiceError(errorDescription: "Sample network request failed")
    }
    return Self.fixtures
  }
}
