// This sample models a multi-step authentication lifecycle with `PhaseMap`.
// Phase-heavy domains (auth, onboarding, checkout) benefit from declaring
// transitions up-front; `PhaseMap` owns `state.phase` after the base reducer
// runs, so the reducer never has to mutate `phase` by hand.
//
// Cancel + retry is wired through `.cancellable("auth-submit", cancelInFlight: true)`,
// which is the canonical way to coalesce an in-flight async request with a
// user-triggered retry or cancel.

import Foundation
import InnoFlow
import SwiftUI

// MARK: - Service

protocol AuthServiceProtocol: Sendable {
  func submitCredentials(username: String, password: String) async throws -> AuthServiceChallenge
  func submitMFA(code: String) async throws -> AuthServiceResult
}

enum AuthServiceChallenge: Equatable, Sendable {
  case authenticated(sessionID: String)
  case mfaRequired(challengeID: String)
}

enum AuthServiceResult: Equatable, Sendable {
  case authenticated(sessionID: String)
}

struct AuthServiceError: LocalizedError, Equatable, Sendable {
  let errorDescription: String?
}

actor SampleAuthService: AuthServiceProtocol {
  func submitCredentials(
    username: String, password: String
  ) async throws -> AuthServiceChallenge {
    if username.contains("mfa") {
      return .mfaRequired(challengeID: "challenge-\(username)")
    }
    if password == "wrong" {
      throw AuthServiceError(errorDescription: "Invalid credentials")
    }
    return .authenticated(sessionID: "sample-session-\(username)")
  }

  func submitMFA(code: String) async throws -> AuthServiceResult {
    if code == "000000" {
      throw AuthServiceError(errorDescription: "MFA code rejected")
    }
    return .authenticated(sessionID: "sample-session-mfa-\(code)")
  }
}

// MARK: - Feature

@InnoFlow
struct AuthenticationFlowFeature {
  struct Dependencies: Sendable {
    let authService: any AuthServiceProtocol
  }

  struct State: Equatable, Sendable, DefaultInitializable {
    enum Phase: String, Hashable, Sendable {
      case idle
      case submitting
      case mfaRequired
      case submittingMFA
      case authenticated
      case failed
    }

    enum LastSubmissionStage: Equatable, Sendable {
      case credentials
      case mfa
    }

    var phase: Phase = .idle
    @BindableField var username = ""
    @BindableField var password = ""
    @BindableField var mfaCode = ""
    var challengeID: String?
    var sessionID: String?
    var errorMessage: String?
    var lastSubmissionStage: LastSubmissionStage = .credentials
  }

  enum Action: Equatable, Sendable {
    case setUsername(String)
    case setPassword(String)
    case setMFACode(String)
    case submitCredentials
    case submitMFA
    case cancelSubmission
    case retry
    case dismissError
    case _mfaChallenge(String)
    case _authenticated(String)
    case _failed(String)
  }

  let dependencies: Dependencies

  init(
    dependencies: Dependencies = .init(authService: SampleAuthService())
  ) {
    self.dependencies = dependencies
  }

  init(authService: any AuthServiceProtocol) {
    self.init(dependencies: .init(authService: authService))
  }

  static var phaseMap: PhaseMap<State, Action, State.Phase> {
    PhaseMap(\State.phase) {
      From(.idle) {
        On(.submitCredentials, to: .submitting)
      }
      From(.submitting) {
        On(.cancelSubmission, to: .idle)
        On(Action.mfaChallengeCasePath, to: .mfaRequired)
        On(Action.authenticatedCasePath, to: .authenticated)
        On(Action.failedCasePath, to: .failed)
      }
      From(.mfaRequired) {
        On(.submitMFA, to: .submittingMFA)
        On(.cancelSubmission, to: .idle)
      }
      From(.submittingMFA) {
        On(.cancelSubmission, to: .mfaRequired)
        On(Action.authenticatedCasePath, to: .authenticated)
        On(Action.failedCasePath, to: .failed)
      }
      From(.failed) {
        On(.retry, targets: [.submitting, .submittingMFA]) { state in
          switch state.lastSubmissionStage {
          case .credentials:
            .submitting
          case .mfa:
            .submittingMFA
          }
        }
        On(.dismissError, to: .idle)
      }
    }
  }

  static var phaseGraph: PhaseTransitionGraph<State.Phase> {
    phaseMap.derivedGraph
  }

  private func submitCredentialsEffect(
    username: String,
    password: String
  ) -> EffectTask<Action> {
    let authService = dependencies.authService
    return .run { send, context in
      do {
        let challenge = try await authService.submitCredentials(
          username: username,
          password: password
        )
        try await context.checkCancellation()
        switch challenge {
        case .authenticated(let sessionID):
          await send(._authenticated(sessionID))
        case .mfaRequired(let challengeID):
          await send(._mfaChallenge(challengeID))
        }
      } catch is CancellationError {
        return
      } catch {
        await send(._failed(error.localizedDescription))
      }
    }
    .cancellable("auth-submit", cancelInFlight: true)
  }

  private func submitMFAEffect(code: String) -> EffectTask<Action> {
    let authService = dependencies.authService
    return .run { send, context in
      do {
        let result = try await authService.submitMFA(code: code)
        try await context.checkCancellation()
        switch result {
        case .authenticated(let sessionID):
          await send(._authenticated(sessionID))
        }
      } catch is CancellationError {
        return
      } catch {
        await send(._failed(error.localizedDescription))
      }
    }
    .cancellable("auth-submit", cancelInFlight: true)
  }

  var body: some Reducer<State, Action> {
    let map: PhaseMap<State, Action, State.Phase> = Self.phaseMap

    return Reduce { state, action in
      switch action {
      case .setUsername(let value):
        state.username = value
        return .none

      case .setPassword(let value):
        state.password = value
        return .none

      case .setMFACode(let value):
        state.mfaCode = value
        return .none

      case .submitCredentials:
        state.errorMessage = nil
        state.challengeID = nil
        state.lastSubmissionStage = .credentials
        let username = state.username
        let password = state.password
        return submitCredentialsEffect(username: username, password: password)

      case .submitMFA:
        state.errorMessage = nil
        state.lastSubmissionStage = .mfa
        let code = state.mfaCode
        return submitMFAEffect(code: code)

      case .retry:
        switch state.lastSubmissionStage {
        case .credentials:
          state.errorMessage = nil
          let username = state.username
          let password = state.password
          return submitCredentialsEffect(username: username, password: password)

        case .mfa:
          state.errorMessage = nil
          let code = state.mfaCode
          return submitMFAEffect(code: code)
        }

      case .cancelSubmission:
        return .cancel("auth-submit")

      case .dismissError:
        state.errorMessage = nil
        state.challengeID = nil
        state.mfaCode = ""
        state.lastSubmissionStage = .credentials
        return .none

      case ._mfaChallenge(let challengeID):
        state.challengeID = challengeID
        // `submitCredentials` resets `state.lastSubmissionStage` to `.credentials`,
        // but once MFA is required we intentionally flip it to `.mfa` so retry targets that step.
        state.lastSubmissionStage = .mfa
        return .none

      case ._authenticated(let sessionID):
        state.sessionID = sessionID
        state.challengeID = nil
        state.mfaCode = ""
        state.errorMessage = nil
        return .none

      case ._failed(let message):
        state.errorMessage = message
        return .none
      }
    }
    .phaseMap(map)
  }
}

// MARK: - View

struct AuthenticationFlowDemoView: View {
  @State private var store = Store(reducer: AuthenticationFlowFeature())

  var body: some View {
    ScrollView {
      VStack(spacing: 16) {
        DemoCard(
          title: "What this demonstrates",
          summary:
            "A multi-step authentication lifecycle declared with `PhaseMap`. Cancel + retry share a single `cancellable` id so in-flight submits are coalesced."
        )

        VStack(alignment: .leading, spacing: 12) {
          HStack {
            Text("Phase")
              .font(.headline)
            Spacer()
            Text(store.phase.rawValue.capitalized)
              .font(.subheadline.monospaced())
              .foregroundStyle(.secondary)
              .accessibilityIdentifier("auth.phase")
          }

          TextField(
            "Email",
            text: store.binding(\.$username, to: AuthenticationFlowFeature.Action.setUsername)
          )
          .textFieldStyle(.roundedBorder)
          .accessibilityLabel(Text("Email"))
          .accessibilityIdentifier("auth.username")

          SecureField(
            "Password",
            text: store.binding(\.$password, to: AuthenticationFlowFeature.Action.setPassword)
          )
          .textFieldStyle(.roundedBorder)
          .accessibilityLabel(Text("Password"))
          .accessibilityIdentifier("auth.password")

          if requiresMFAInput {
            TextField(
              "MFA code",
              text: store.binding(\.$mfaCode, to: AuthenticationFlowFeature.Action.setMFACode)
            )
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel(Text("MFA code"))
            .accessibilityIdentifier("auth.mfa-code")
          }

          HStack {
            Button(submitButtonTitle) {
              store.send(primaryAction)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isSubmittingPhase)
            .accessibilityIdentifier("auth.submit")

            if isSubmittingPhase {
              Button("Cancel") {
                store.send(.cancelSubmission)
              }
              .buttonStyle(.bordered)
              .accessibilityIdentifier("auth.cancel")
            }

            if store.phase == .failed {
              Button("Retry") {
                store.send(.retry)
              }
              .buttonStyle(.bordered)
              .accessibilityIdentifier("auth.retry")
            }
          }

          if let errorMessage = store.errorMessage {
            VStack(alignment: .leading, spacing: 8) {
              Text(errorMessage)
                .font(.footnote)
                .foregroundStyle(.red)
                .accessibilityIdentifier("auth.error-message")
              Button("Dismiss") {
                store.send(.dismissError)
              }
              .buttonStyle(.bordered)
              .accessibilityIdentifier("auth.dismiss-error")
            }
          }

          if let sessionID = store.sessionID, store.phase == .authenticated {
            Text("Session: \(sessionID)")
              .font(.footnote.monospaced())
              .foregroundStyle(.secondary)
              .accessibilityIdentifier("auth.session-id")
          }
        }
        .padding()
        .background(Color.primary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

        LogSection(
          title: "Phase Graph",
          entries: [
            "idle -> submitting",
            "submitting -> mfaRequired | authenticated | failed",
            "mfaRequired -> submittingMFA",
            "submittingMFA -> authenticated | failed",
            "failed -> submitting | submittingMFA (retry) | idle (dismiss)",
          ]
        )
      }
      .padding()
    }
    .navigationTitle("Authentication Flow")
  }

  private var isSubmittingPhase: Bool {
    store.phase == .submitting || store.phase == .submittingMFA
  }

  private var requiresMFAInput: Bool {
    store.phase == .mfaRequired
      || store.phase == .submittingMFA
      || (store.phase == .failed && store.lastSubmissionStage == .mfa)
  }

  private var submitButtonTitle: String {
    switch store.phase {
    case .submitting: "Submitting..."
    case .submittingMFA: "Verifying..."
    case .mfaRequired: "Verify MFA"
    case .authenticated: "Signed In"
    default: "Sign In"
    }
  }

  private var primaryAction: AuthenticationFlowFeature.Action {
    switch store.phase {
    case .mfaRequired, .submittingMFA: .submitMFA
    default: .submitCredentials
    }
  }
}

#Preview("Authentication Flow") {
  NavigationStack {
    AuthenticationFlowDemoView()
  }
}
