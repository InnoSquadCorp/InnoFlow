// Form-heavy sample with multiple bindable fields and cross-field validation.
//
// The reducer owns business validation rules and submit/reset decisions.
// Concrete form controls stay in SwiftUI, but the validation contract is
// reducer-owned and fully testable through `TestStore`.

import InnoFlow
import SwiftUI

@InnoFlow
struct FormValidationFeature {
  struct State: Equatable, Sendable, DefaultInitializable {
    @BindableField var fullName = ""
    @BindableField var email = ""
    @BindableField var confirmEmail = ""
    @BindableField var acceptsTerms = false
    var validationMessages: [String] = []
    var diagnostics: [String] = []
    var submittedSummary: String?
    var hasAttemptedSubmit = false
  }

  enum Action: Equatable, Sendable {
    case setFullName(String)
    case setEmail(String)
    case setConfirmEmail(String)
    case setAcceptsTerms(Bool)
    case submit
    case reset
  }

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .setFullName(let value):
        state.fullName = value
        state.submittedSummary = nil
        refreshValidationIfNeeded(into: &state)
        return .none

      case .setEmail(let value):
        state.email = value
        state.submittedSummary = nil
        refreshValidationIfNeeded(into: &state)
        return .none

      case .setConfirmEmail(let value):
        state.confirmEmail = value
        state.submittedSummary = nil
        refreshValidationIfNeeded(into: &state)
        return .none

      case .setAcceptsTerms(let value):
        state.acceptsTerms = value
        state.submittedSummary = nil
        refreshValidationIfNeeded(into: &state)
        return .none

      case .submit:
        state.hasAttemptedSubmit = true
        state.validationMessages = Self.validationMessages(for: state)

        guard state.validationMessages.isEmpty else {
          state.submittedSummary = nil
          state.diagnostics.append(
            "blocked submit with \(state.validationMessages.count) validation issue(s)"
          )
          return .none
        }

        let summary = "\(state.fullName) <\(state.email)>"
        state.submittedSummary = summary
        state.diagnostics.append("submitted form for \(summary)")
        return .none

      case .reset:
        state.fullName = ""
        state.email = ""
        state.confirmEmail = ""
        state.acceptsTerms = false
        state.validationMessages = []
        state.submittedSummary = nil
        state.hasAttemptedSubmit = false
        state.diagnostics.append("reset form")
        return .none
      }
    }
  }

  private func refreshValidationIfNeeded(into state: inout State) {
    guard state.hasAttemptedSubmit else { return }
    state.validationMessages = Self.validationMessages(for: state)
  }

  private static func validationMessages(for state: State) -> [String] {
    let trimmedName = state.fullName.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedEmail = state.email.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedConfirmation = state.confirmEmail.trimmingCharacters(in: .whitespacesAndNewlines)

    var messages: [String] = []

    if trimmedName.split(separator: " ").count < 2 {
      messages.append("Full name must include at least two words.")
    }
    if !looksLikeEmail(trimmedEmail) {
      messages.append("Email must look like a valid address.")
    }
    if trimmedConfirmation != trimmedEmail {
      messages.append("Confirmation email must match the primary email.")
    }
    if !state.acceptsTerms {
      messages.append("Accept the terms before submitting.")
    }

    return messages
  }

  private static func looksLikeEmail(_ value: String) -> Bool {
    guard let atIndex = value.firstIndex(of: "@") else { return false }
    let domain = value[value.index(after: atIndex)...]
    return !domain.isEmpty && domain.contains(".")
  }
}

struct FormValidationDemoView: View {
  @State private var store = Store(reducer: FormValidationFeature())

  var body: some View {
    ScrollView {
      VStack(spacing: 16) {
        DemoCard(
          title: "What this demonstrates",
          summary:
            "A form-heavy reducer with four bindable fields, cross-field validation, and explicit submit-or-reset behavior. Validation rules stay in the reducer so the same contract is testable without the view."
        )

        DemoCard(
          title: "Ownership note",
          summary:
            "SwiftUI owns text fields and toggle chrome. The reducer owns when the form is valid, what cross-field mismatch means, and what reset should clear."
        )

        VStack(alignment: .leading, spacing: 12) {
          TextField(
            "Full name",
            text: store.binding(\.$fullName, to: FormValidationFeature.Action.setFullName)
          )
          .textFieldStyle(.roundedBorder)
          .accessibilityIdentifier("form.full-name")

          TextField(
            "Email",
            text: store.binding(\.$email, to: FormValidationFeature.Action.setEmail)
          )
          .textFieldStyle(.roundedBorder)
          .autocorrectionDisabled()
          .accessibilityIdentifier("form.email")

          TextField(
            "Confirm email",
            text: store.binding(\.$confirmEmail, to: FormValidationFeature.Action.setConfirmEmail)
          )
          .textFieldStyle(.roundedBorder)
          .autocorrectionDisabled()
          .accessibilityIdentifier("form.confirm-email")

          Toggle(
            "Accept terms for the sample submission",
            isOn: store.binding(\.$acceptsTerms, to: FormValidationFeature.Action.setAcceptsTerms)
          )
          .toggleStyle(.switch)
          .accessibilityIdentifier("form.accept-terms")

          HStack {
            Button("Submit") {
              store.send(.submit)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("form.submit")

            Button("Reset") {
              store.send(.reset)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("form.reset")
          }

          if !store.validationMessages.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
              Text("Validation")
                .font(.headline)
              Text(store.validationMessages.joined(separator: "\n"))
                .font(.footnote)
                .foregroundStyle(.red)
                .accessibilityIdentifier("form.validation-summary")
            }
          } else {
            Text(store.hasAttemptedSubmit ? "Form is ready to submit." : "Submit to run validation.")
              .font(.footnote)
              .foregroundStyle(.secondary)
              .accessibilityIdentifier("form.validation-summary")
          }

          if let summary = store.submittedSummary {
            Text("Submitted: \(summary)")
              .font(.footnote.monospaced())
              .foregroundStyle(.green)
              .accessibilityIdentifier("form.success")
          }
        }
        .padding()
        .background(Color.primary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

        LogSection(
          title: "Diagnostics",
          entries: store.diagnostics.isEmpty ? ["No submit or reset yet."] : store.diagnostics
        )
      }
      .padding()
    }
    .navigationTitle("Form Validation")
  }
}

#Preview("Form Validation") {
  NavigationStack {
    FormValidationDemoView()
  }
}
