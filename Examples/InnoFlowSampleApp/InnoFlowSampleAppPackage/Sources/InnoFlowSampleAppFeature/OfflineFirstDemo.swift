// Offline-first optimistic update + debounced save.
//
// Two effect shapes stack here:
//   1. A manual `run + context.sleep + cancellable(id:, cancelInFlight:)`
//      debounce collapses consecutive edits into a single background save
//      after the user stops typing.
//   2. Optimistic updates apply immediately to local state, and a background
//      task emits either `_saveConfirmed` or `_saveRolledBack(...)` so the
//      reducer can resolve the truth once the server responds.
//
// `PhaseMap` is intentionally absent — optimistic state is a per-item
// concern and does not need a feature-wide phase graph.

import Foundation
import InnoFlow
import SwiftUI

// MARK: - Repository

struct SampleDraft: Identifiable, Equatable, Sendable {
  let id: UUID
  var title: String
  var lastSavedTitle: String
  var inFlightTitle: String?

  init(id: UUID = UUID(), title: String) {
    self.id = id
    self.title = title
    self.lastSavedTitle = title
    self.inFlightTitle = nil
  }

  var isDirty: Bool { inFlightTitle != nil || title != lastSavedTitle }
}

protocol DraftRepositoryProtocol: Sendable {
  func save(id: UUID, title: String) async throws
}

struct DraftRepositoryError: LocalizedError, Equatable, Sendable {
  let errorDescription: String?
}

actor SampleDraftRepository: DraftRepositoryProtocol {
  private var failNextFlag: Bool = false

  func failNext() { failNextFlag = true }

  func save(id: UUID, title: String) async throws {
    if failNextFlag {
      failNextFlag = false
      throw DraftRepositoryError(errorDescription: "Server rejected save for \(id)")
    }
  }
}

// MARK: - Feature

@InnoFlow
struct OfflineFirstFeature {
  struct Dependencies: Sendable {
    let repository: any DraftRepositoryProtocol
    let debounceDuration: Duration
  }

  struct State: Equatable, Sendable, DefaultInitializable {
    var draft: SampleDraft = SampleDraft(
      id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!,
      title: "Offline-first draft"
    )
    var log: [String] = []
    var errorMessage: String?
  }

  struct SaveRollback: Equatable, Sendable {
    let previous: String
    let failedTitle: String
    let reason: String
  }

  enum Action: Equatable, Sendable {
    case titleChanged(String)
    case saveNow
    case _persistPendingSave
    case _saveConfirmed(String)
    case _saveRolledBack(SaveRollback)
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
    self.init(
      dependencies: .init(repository: repository, debounceDuration: debounceDuration)
    )
  }

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .titleChanged(let newTitle):
        state.draft.title = newTitle
        state.log.append("edit: '\(newTitle)'")
        let duration = dependencies.debounceDuration
        return .run { send, context in
          do {
            try await context.sleep(for: duration)
            try await context.checkCancellation()
            await send(._persistPendingSave)
          } catch is CancellationError {
            return
          } catch {
            return
          }
        }
        .cancellable("offline-save-debounce", cancelInFlight: true)

      case .saveNow:
        return .concatenate(
          .cancel("offline-save-debounce"),
          .send(._persistPendingSave)
        )

      case ._persistPendingSave:
        // Optimistic update: the local title already reflects the user's
        // edit. We mark the `inFlightTitle` so the reducer can compare the
        // server's truth when the task resumes.
        let draft = state.draft
        guard draft.title != draft.lastSavedTitle else { return .none }
        guard draft.inFlightTitle != draft.title else { return .none }
        state.draft.inFlightTitle = draft.title
        state.errorMessage = nil
        state.log.append("save attempt: '\(draft.title)'")

        let repository = dependencies.repository
        let id = draft.id
        let pendingTitle = draft.title
        let previousTitle = draft.lastSavedTitle
        return .run { send, context in
          do {
            try await context.checkCancellation()
            try await repository.save(id: id, title: pendingTitle)
            try await context.checkCancellation()
            await send(._saveConfirmed(pendingTitle))
          } catch is CancellationError {
            return
          } catch {
            await send(
              ._saveRolledBack(
                .init(
                  previous: previousTitle,
                  failedTitle: pendingTitle,
                  reason: error.localizedDescription
                )
              )
            )
          }
        }
        .cancellable("offline-save", cancelInFlight: true)

      case ._saveConfirmed(let title):
        state.draft.lastSavedTitle = title
        state.draft.inFlightTitle = nil
        state.errorMessage = nil
        state.log.append("confirmed: '\(title)'")
        return .none

      case ._saveRolledBack(let rollback):
        let previous = rollback.previous
        let failedTitle = rollback.failedTitle
        let reason = rollback.reason
        let isInFlight = state.draft.inFlightTitle == failedTitle
        let isCurrent = state.draft.title == failedTitle

        if isInFlight || isCurrent {
          state.draft.inFlightTitle = nil
        }
        state.errorMessage = reason

        switch (isInFlight, isCurrent) {
        case (true, true):
          state.draft.title = previous
          state.log.append(
            "rolled back current in-flight '\(failedTitle)' to '\(previous)': \(reason)"
          )
        case (true, false):
          state.log.append("cleared stale in-flight '\(failedTitle)': \(reason)")
        case (false, true):
          state.draft.title = previous
          state.log.append(
            "restored current '\(failedTitle)' without matching in-flight save: \(reason)"
          )
        case (false, false):
          state.log.append("ignored stale rollback for '\(failedTitle)': \(reason)")
        }
        return .none
      }
    }
  }
}

// MARK: - View

struct OfflineFirstDemoView: View {
  @State private var store = Store(reducer: OfflineFirstFeature())

  var body: some View {
    ScrollView {
      VStack(spacing: 16) {
        DemoCard(
          title: "What this demonstrates",
          summary:
            "Optimistic local update + debounced save. Each keystroke schedules a save, consecutive edits collapse, and a failed save rolls the title back."
        )

        VStack(alignment: .leading, spacing: 12) {
          TextField(
            "Title",
            text: Binding(
              get: { store.draft.title },
              set: { store.send(.titleChanged($0)) }
            )
          )
          .textFieldStyle(.roundedBorder)
          .accessibilityIdentifier("offline.title")

          HStack {
            Text("Saved: \(store.draft.lastSavedTitle)")
              .font(.footnote)
              .foregroundStyle(.secondary)
              .accessibilityIdentifier("offline.saved-title")
            Spacer()
            if let inFlight = store.draft.inFlightTitle {
              Label("Saving \(inFlight)", systemImage: "arrow.triangle.2.circlepath")
                .font(.footnote.monospaced())
                .accessibilityIdentifier("offline.in-flight")
            } else if store.draft.isDirty {
              Label("Dirty", systemImage: "circle.fill")
                .font(.footnote.monospaced())
                .foregroundStyle(.orange)
                .accessibilityIdentifier("offline.dirty")
            } else {
              Label("Synced", systemImage: "checkmark.circle")
                .font(.footnote.monospaced())
                .foregroundStyle(.green)
                .accessibilityIdentifier("offline.synced")
            }
          }

          Button("Save Now") {
            store.send(.saveNow)
          }
          .buttonStyle(.bordered)
          .disabled(!store.draft.isDirty)
          .accessibilityIdentifier("offline.save-now")

          if let errorMessage = store.errorMessage {
            Text(errorMessage)
              .font(.footnote)
              .foregroundStyle(.red)
              .accessibilityIdentifier("offline.error-message")
          }
        }
        .padding()
        .background(Color.primary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

        LogSection(title: "Save Log", entries: store.log)
      }
      .padding()
    }
    .navigationTitle("Offline-First")
  }
}

#Preview("Offline-First") {
  NavigationStack {
    OfflineFirstDemoView()
  }
}
