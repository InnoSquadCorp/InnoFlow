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
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      if coordinator.loginStore.authVersion == target {
        return
      }
      try Task.checkCancellation()
      await Task.yield()
      do {
        try await Task.sleep(for: .milliseconds(20))
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        Issue.record("Unexpected wait failure while observing authVersion: \(error)")
        return
      }
    }

    Issue.record("Expected authVersion to reach \(target) before timing out")
  }

  @MainActor
  private func waitForSleeperRegistration(
    _ clock: ManualTestClock,
    minimumCount: Int = 1,
    timeout: Duration = .seconds(1)
  ) async -> Bool {
    let wallClock = ContinuousClock()
    let deadline = wallClock.now.advanced(by: timeout)

    while wallClock.now < deadline {
      if await clock.sleeperCount >= minimumCount {
        return true
      }
      await Task.yield()
      try? await Task.sleep(for: .milliseconds(5))
    }

    Issue.record("Timed out waiting for sleeper registration to reach \(minimumCount)")
    return false
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

    let targetID = MockTodoService.navigationTodoID
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
    let targetID = MockTodoService.assertionTodoID
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
  func routerCompositionReplaysPendingRoute() async throws {
    let protectedDetailID = "invoice-99"
    let coordinator = RouterCompositionCoordinator(protectedDetailID: protectedDetailID)
    coordinator.queueProtectedDetail()
    coordinator.submitLogin()

    try await waitForAuthVersion(1, in: coordinator)

    coordinator.syncNavigationWithDomainState()

    #expect(coordinator.path == [.dashboard, .detail(id: protectedDetailID)])
    #expect(coordinator.pendingRoute == nil)
  }

  // MARK: - AuthenticationFlowDemo

  @Test("Authentication flow reaches authenticated on successful credentials")
  @MainActor
  func authenticationFlowSuccess() async {
    let map:
      PhaseMap<
        AuthenticationFlowFeature.State, AuthenticationFlowFeature.Action,
        AuthenticationFlowFeature.State.Phase
      > = AuthenticationFlowFeature.phaseMap
    let store = TestStore(
      reducer: AuthenticationFlowFeature(authService: MockAuthService()),
      initialState: .init(
        phase: .idle,
        username: "user@innosquad.com",
        password: "correct",
        mfaCode: "",
        challengeID: nil,
        sessionID: nil,
        errorMessage: nil
      )
    )

    await store.send(.submitCredentials, through: map) {
      $0.phase = .submitting
      $0.errorMessage = nil
    }

    await store.receive(._authenticated("session-correct"), through: map) {
      $0.phase = .authenticated
      $0.sessionID = "session-correct"
      $0.errorMessage = nil
    }

    await store.assertNoMoreActions()
  }

  @Test("Authentication flow transitions through mfaRequired to authenticated")
  @MainActor
  func authenticationFlowMFAPath() async {
    let map:
      PhaseMap<
        AuthenticationFlowFeature.State, AuthenticationFlowFeature.Action,
        AuthenticationFlowFeature.State.Phase
      > = AuthenticationFlowFeature.phaseMap
    let store = TestStore(
      reducer: AuthenticationFlowFeature(authService: MockAuthService()),
      initialState: .init(
        phase: .idle,
        username: "mfa-user@innosquad.com",
        password: "correct",
        mfaCode: "",
        challengeID: nil,
        sessionID: nil,
        errorMessage: nil
      )
    )

    await store.send(.submitCredentials, through: map) {
      $0.phase = .submitting
      $0.errorMessage = nil
    }

    await store.receive(._mfaChallenge("challenge-mfa-user@innosquad.com"), through: map) {
      $0.phase = .mfaRequired
      $0.challengeID = "challenge-mfa-user@innosquad.com"
      $0.lastSubmissionStage = .mfa
    }

    await store.send(.setMFACode("123456")) {
      $0.mfaCode = "123456"
    }

    await store.send(.submitMFA, through: map) {
      $0.phase = .submittingMFA
      $0.errorMessage = nil
    }

    await store.receive(._authenticated("session-mfa-123456"), through: map) {
      $0.phase = .authenticated
      $0.sessionID = "session-mfa-123456"
      $0.challengeID = nil
      $0.mfaCode = ""
      $0.errorMessage = nil
    }

    await store.assertNoMoreActions()
  }

  @Test("Authentication flow credential retry returns to submitting")
  @MainActor
  func authenticationFlowFailureThenRetry() async {
    let map:
      PhaseMap<
        AuthenticationFlowFeature.State, AuthenticationFlowFeature.Action,
        AuthenticationFlowFeature.State.Phase
      > = AuthenticationFlowFeature.phaseMap
    let store = TestStore(
      reducer: AuthenticationFlowFeature(authService: MockAuthService()),
      initialState: .init(
        phase: .idle,
        username: "user@innosquad.com",
        password: "wrong",
        mfaCode: "",
        challengeID: nil,
        sessionID: nil,
        errorMessage: nil
      )
    )

    await store.send(.submitCredentials, through: map) {
      $0.phase = .submitting
      $0.errorMessage = nil
    }

    await store.receive(._failed("Invalid credentials"), through: map) {
      $0.phase = .failed
      $0.errorMessage = "Invalid credentials"
    }

    await store.send(.retry, through: map) {
      $0.phase = .submitting
      $0.errorMessage = nil
    }

    await store.receive(._failed("Invalid credentials"), through: map) {
      $0.phase = .failed
      $0.errorMessage = "Invalid credentials"
    }

    await store.assertNoMoreActions()
  }

  @Test("Authentication flow MFA retry stays on the MFA path")
  @MainActor
  func authenticationFlowMFAFailureThenRetry() async {
    let map:
      PhaseMap<
        AuthenticationFlowFeature.State, AuthenticationFlowFeature.Action,
        AuthenticationFlowFeature.State.Phase
      > = AuthenticationFlowFeature.phaseMap
    let store = TestStore(
      reducer: AuthenticationFlowFeature(authService: MockAuthService()),
      initialState: .init(
        phase: .mfaRequired,
        username: "mfa-user@innosquad.com",
        password: "correct",
        mfaCode: "000000",
        challengeID: "challenge-mfa-user@innosquad.com",
        sessionID: nil,
        errorMessage: nil,
        lastSubmissionStage: .mfa
      )
    )

    await store.send(.submitMFA, through: map) {
      $0.phase = .submittingMFA
      $0.errorMessage = nil
      $0.lastSubmissionStage = .mfa
    }

    await store.receive(._failed("MFA code rejected"), through: map) {
      $0.phase = .failed
      $0.errorMessage = "MFA code rejected"
    }

    await store.send(.setMFACode("123456")) {
      $0.mfaCode = "123456"
    }

    await store.send(.retry, through: map) {
      $0.phase = .submittingMFA
      $0.errorMessage = nil
    }

    await store.receive(._authenticated("session-mfa-123456"), through: map) {
      $0.phase = .authenticated
      $0.sessionID = "session-mfa-123456"
      $0.challengeID = nil
      $0.mfaCode = ""
      $0.errorMessage = nil
    }

    await store.assertNoMoreActions()
  }

  // MARK: - ListDetailPaginationDemo

  @Test("List-detail pagination loads first page and appends results")
  @MainActor
  func listDetailPaginationFirstPage() async {
    let store = TestStore(
      reducer: ListDetailPaginationFeature(articlesService: MockArticlesService())
    )

    await store.send(.loadFirstPage) {
      $0.articles = []
      $0.currentPage = -1
      $0.hasReachedEnd = false
      $0.errorMessage = nil
    }

    await store.receive(.loadNextPage) {
      $0.isLoading = true
      $0.errorMessage = nil
    }

    await store.receive(
      ._loaded(MockArticlesService.page0, page: 0)
    ) {
      $0.isLoading = false
      $0.currentPage = 0
      $0.articles = MockArticlesService.page0
    }

    await store.assertNoMoreActions()
  }

  @Test("List-detail pagination detects end of feed when service yields empty page")
  @MainActor
  func listDetailPaginationReachesEnd() async {
    let store = TestStore(
      reducer: ListDetailPaginationFeature(articlesService: MockArticlesService()),
      initialState: .init(
        articles: MockArticlesService.page0,
        currentPage: 0,
        isLoading: false,
        hasReachedEnd: false,
        errorMessage: nil
      )
    )

    await store.send(.loadNextPage) {
      $0.isLoading = true
      $0.errorMessage = nil
    }

    await store.receive(._loaded([], page: 1)) {
      $0.isLoading = false
      $0.currentPage = 1
      $0.hasReachedEnd = true
    }

    await store.assertNoMoreActions()
  }

  @Test("List-detail pagination routes row actions through collection scope")
  @MainActor
  func listDetailPaginationRowScope() async {
    let store = TestStore(
      reducer: ListDetailPaginationFeature(articlesService: MockArticlesService()),
      initialState: .init(
        articles: MockArticlesService.page0,
        currentPage: 0,
        isLoading: false,
        hasReachedEnd: false,
        errorMessage: nil
      )
    )

    let targetID = MockArticlesService.page0[0].id
    let article = store.scope(
      collection: \.articles,
      id: targetID,
      action: ListDetailPaginationFeature.Action.articleActionPath
    )

    await article.send(.toggleFavorite)

    article.assert {
      $0.isFavorite = true
    }
    #expect(store.state.articles.first(where: { $0.id == targetID })?.isFavorite == true)
    await store.assertNoMoreActions()
  }

  // MARK: - OfflineFirstDemo

  @Test("Offline-first save confirms optimistic update when repository succeeds")
  @MainActor
  func offlineFirstSaveConfirmed() async {
    let draftID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    let repository = MockDraftRepository()
    let store = TestStore(
      reducer: OfflineFirstFeature(repository: repository, debounceDuration: .milliseconds(1)),
      initialState: .init(
        draft: SampleDraft(id: draftID, title: "Offline-first draft"),
        log: [],
        errorMessage: nil
      )
    )

    await store.send(.saveNow)

    await store.receive(._persistPendingSave)
    // No-op because title matches lastSavedTitle.
    await store.assertNoMoreActions()

    // Now make the draft dirty and persist.
    await store.send(.titleChanged("Edited title")) {
      $0.draft.title = "Edited title"
      $0.log = ["edit: 'Edited title'"]
    }

    await store.send(.saveNow)

    await store.receive(._persistPendingSave) {
      $0.draft.inFlightTitle = "Edited title"
      $0.log = ["edit: 'Edited title'", "save attempt: 'Edited title'"]
    }

    await store.receive(._saveConfirmed(title: "Edited title")) {
      $0.draft.lastSavedTitle = "Edited title"
      $0.draft.inFlightTitle = nil
      $0.errorMessage = nil
      $0.log = [
        "edit: 'Edited title'",
        "save attempt: 'Edited title'",
        "confirmed: 'Edited title'",
      ]
    }
  }

  @Test("Offline-first save rolls back when repository fails")
  @MainActor
  func offlineFirstSaveRolledBack() async {
    let draftID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    let repository = MockDraftRepository(shouldFail: true)
    let store = TestStore(
      reducer: OfflineFirstFeature(repository: repository, debounceDuration: .milliseconds(1)),
      initialState: .init(
        draft: SampleDraft(id: draftID, title: "Offline-first draft"),
        log: [],
        errorMessage: nil
      )
    )

    await store.send(.titleChanged("Broken edit")) {
      $0.draft.title = "Broken edit"
      $0.log = ["edit: 'Broken edit'"]
    }

    await store.send(.saveNow)

    await store.receive(._persistPendingSave) {
      $0.draft.inFlightTitle = "Broken edit"
      $0.log = ["edit: 'Broken edit'", "save attempt: 'Broken edit'"]
    }

    await store.receive(
      ._saveRolledBack(
        previous: "Offline-first draft",
        failedTitle: "Broken edit",
        reason: "mock-rejected"
      )
    ) {
      $0.draft.title = "Offline-first draft"
      $0.draft.inFlightTitle = nil
      $0.errorMessage = "mock-rejected"
      $0.log = [
        "edit: 'Broken edit'",
        "save attempt: 'Broken edit'",
        "rolled back current in-flight 'Broken edit' to 'Offline-first draft': mock-rejected",
      ]
    }
  }

  @Test("Offline-first saveNow cancels pending debounce and avoids duplicate saves")
  @MainActor
  func offlineFirstSaveNowCancelsPendingDebounce() async {
    let clock = ManualTestClock()
    let repository = MockDraftRepository(clock: clock)
    let store = TestStore(
      reducer: OfflineFirstFeature(repository: repository, debounceDuration: .milliseconds(100)),
      initialState: .init(),
      clock: clock
    )

    await store.send(.titleChanged("Edited title")) {
      $0.draft.title = "Edited title"
      $0.log = ["edit: 'Edited title'"]
    }

    await store.send(.saveNow)

    await store.receive(._persistPendingSave) {
      $0.draft.inFlightTitle = "Edited title"
      $0.errorMessage = nil
      $0.log = ["edit: 'Edited title'", "save attempt: 'Edited title'"]
    }

    await store.receive(._saveConfirmed(title: "Edited title")) {
      $0.draft.lastSavedTitle = "Edited title"
      $0.draft.inFlightTitle = nil
      $0.errorMessage = nil
      $0.log = [
        "edit: 'Edited title'",
        "save attempt: 'Edited title'",
        "confirmed: 'Edited title'",
      ]
    }

    await clock.advance(by: .milliseconds(100))
    await store.assertNoMoreActions()
    #expect(await repository.saveCount == 1)
  }

  @Test("Offline-first stale save failure keeps the latest local edit")
  @MainActor
  func offlineFirstStaleSaveFailureKeepsLatestEdit() async {
    let clock = ManualTestClock()
    let repository = MockDraftRepository(
      failureMode: .alwaysReject,
      saveDelay: .milliseconds(20),
      clock: clock
    )
    let store = TestStore(
      reducer: OfflineFirstFeature(repository: repository, debounceDuration: .seconds(1)),
      initialState: .init(),
      clock: clock
    )

    await store.send(.titleChanged("Broken edit")) {
      $0.draft.title = "Broken edit"
      $0.log = ["edit: 'Broken edit'"]
    }

    await store.send(.saveNow)

    await store.receive(._persistPendingSave) {
      $0.draft.inFlightTitle = "Broken edit"
      $0.errorMessage = nil
      $0.log = ["edit: 'Broken edit'", "save attempt: 'Broken edit'"]
    }
    guard await waitForSleeperRegistration(clock) else { return }

    await store.send(.titleChanged("Newer local edit")) {
      $0.draft.title = "Newer local edit"
      $0.log = ["edit: 'Broken edit'", "save attempt: 'Broken edit'", "edit: 'Newer local edit'"]
    }

    await clock.advance(by: .milliseconds(20))

    await store.receive(
      ._saveRolledBack(
        previous: "Offline-first draft",
        failedTitle: "Broken edit",
        reason: "mock-rejected"
      )
    ) {
      $0.draft.inFlightTitle = nil
      $0.errorMessage = "mock-rejected"
      $0.log = [
        "edit: 'Broken edit'",
        "save attempt: 'Broken edit'",
        "edit: 'Newer local edit'",
        "cleared stale in-flight 'Broken edit': mock-rejected",
      ]
    }

    #expect(store.state.draft.title == "Newer local edit")
    #expect(store.state.draft.lastSavedTitle == "Offline-first draft")
    await store.assertNoMoreActions()
  }

  // MARK: - RealtimeStreamDemo

  @Test("Realtime stream emits ticks when the clock advances")
  @MainActor
  func realtimeStreamAdvancesClock() async {
    let clock = ManualTestClock()
    let store = TestStore(
      reducer: RealtimeStreamFeature(tickInterval: .milliseconds(100)),
      clock: clock
    )

    await store.send(.subscribe) {
      $0.isSubscribed = true
    }

    guard await waitForSleeperRegistration(clock) else { return }

    await clock.advance(by: .milliseconds(100))
    await store.receive(._tick(1)) {
      $0.ticks = [1]
    }

    guard await waitForSleeperRegistration(clock) else { return }
    await clock.advance(by: .milliseconds(100))
    await store.receive(._tick(2)) {
      $0.ticks = [1, 2]
    }

    await store.send(.unsubscribe) {
      $0.isSubscribed = false
    }

    await store.assertNoMoreActions()
  }

  @Test("Realtime stream unsubscribe stops delivering ticks")
  @MainActor
  func realtimeStreamUnsubscribeStopsTicks() async {
    let clock = ManualTestClock()
    let store = TestStore(
      reducer: RealtimeStreamFeature(tickInterval: .milliseconds(100)),
      clock: clock
    )

    await store.send(.subscribe) {
      $0.isSubscribed = true
    }
    await store.send(.unsubscribe) {
      $0.isSubscribed = false
    }

    await clock.advance(by: .seconds(1))
    await store.assertNoMoreActions()
    #expect(store.state.ticks.isEmpty)
  }

  @Test("Realtime stream subscribe restarts the loop without duplicating tick emitters")
  @MainActor
  func realtimeStreamSubscribeRestartsLoop() async {
    let clock = ManualTestClock()
    let store = TestStore(
      reducer: RealtimeStreamFeature(tickInterval: .milliseconds(100)),
      clock: clock
    )

    await store.send(.subscribe) {
      $0.isSubscribed = true
    }
    guard await waitForSleeperRegistration(clock) else { return }

    await clock.advance(by: .milliseconds(100))
    await store.receive(._tick(1)) {
      $0.ticks = [1]
    }

    await store.send(.subscribe) {
      $0.isSubscribed = true
    }
    // Restarting a cancellable sleep can keep `sleeperCount` at 1 across the
    // cancel + re-register boundary, so polling that count is not enough to
    // prove the replacement loop is ready. Give the cooperative executor a
    // real wall-clock slice to process the restart before advancing.
    try? await Task.sleep(for: .milliseconds(100))

    await clock.advance(by: .milliseconds(100))
    await store.receive(._tick(1)) {
      $0.ticks = [1, 1]
    }

    await store.assertNoMoreActions()
  }
}

// MARK: - Test doubles

private struct MockAuthService: AuthServiceProtocol {
  func submitCredentials(
    username: String, password: String
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

private struct MockArticlesService: ArticlesServiceProtocol {
  static let page0: [SampleArticle] = [
    SampleArticle(
      id: UUID(uuidString: "00000000-0000-0000-0000-0000000B0001")!,
      title: "Mock Article #1",
      summary: "Mock summary 1"
    ),
    SampleArticle(
      id: UUID(uuidString: "00000000-0000-0000-0000-0000000B0002")!,
      title: "Mock Article #2",
      summary: "Mock summary 2"
    ),
  ]

  var pageCount: Int { 1 }

  func loadPage(_ page: Int, pageSize: Int) async throws -> [SampleArticle] {
    if page == 0 { return Self.page0 }
    return []
  }
}

private actor MockDraftRepository: DraftRepositoryProtocol {
  enum FailureMode: Sendable {
    case never
    case alwaysReject
  }

  private let failureMode: FailureMode
  private let saveDelay: Duration
  private let clock: ManualTestClock?
  private(set) var saveCount = 0

  init(
    shouldFail: Bool = false,
    failureMode: FailureMode? = nil,
    saveDelay: Duration = .zero,
    clock: ManualTestClock? = nil
  ) {
    self.failureMode = failureMode ?? (shouldFail ? .alwaysReject : .never)
    self.saveDelay = saveDelay
    self.clock = clock
  }

  func save(id: UUID, title: String) async throws {
    saveCount += 1
    if saveDelay > .zero {
      if let clock {
        try await clock.sleep(for: saveDelay)
      } else {
        try await Task.sleep(for: saveDelay)
      }
    }
    if failureMode == .alwaysReject {
      throw DraftRepositoryError(errorDescription: "mock-rejected")
    }
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
  static let navigationTodoID =
    fixtures.first { $0.title == "Keep navigation out of the phase graph" }!.id
  static let assertionTodoID =
    fixtures.first { $0.title == "Assert transitions with TestStore" }!.id

  var shouldAlwaysFail = false

  func loadTodos(shouldFail: Bool) async throws -> [SampleTodo] {
    if shouldFail || shouldAlwaysFail {
      throw SampleTodoServiceError(errorDescription: "Sample network request failed")
    }
    return Self.fixtures
  }
}
