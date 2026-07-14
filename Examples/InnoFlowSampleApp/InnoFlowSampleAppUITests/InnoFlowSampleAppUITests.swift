import InnoFlowSampleAppFeature
import XCTest

final class InnoFlowSampleAppUITests: XCTestCase {
  private enum UIWait {
    static let launch: TimeInterval = 15
    static let acknowledgement: TimeInterval = 3
    static let scrollSettle: TimeInterval = 1
    static let transition: TimeInterval = 8
  }

  private struct UICondition {
    let element: XCUIElement
    let predicate: NSPredicate
    let description: String
  }

  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  @MainActor
  private func launchApp(
    environment: [String: String] = [:],
    readyWhen: (XCUIApplication) -> UICondition,
    file: StaticString = #filePath,
    line: UInt = #line
  ) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchEnvironment.merge(environment) { _, new in new }
    app.launch()

    let foreground = UICondition(
      element: app,
      predicate: NSPredicate { object, _ in
        (object as? XCUIApplication)?.state == .runningForeground
      },
      description: "the sample app to run in the foreground"
    )
    XCTAssertTrue(
      waitForCondition(foreground, timeout: UIWait.launch),
      "Expected \(foreground.description)",
      file: file,
      line: line
    )

    let readiness = readyWhen(app)
    XCTAssertTrue(
      waitForCondition(readiness, timeout: UIWait.launch),
      "Expected \(readiness.description) after launch",
      file: file,
      line: line
    )
    return app
  }

  @MainActor
  private func openDemoFromHub(
    _ identifier: String,
    in app: XCUIApplication,
    destinationAnchor: XCUIElement,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let hubButton = app.buttons[identifier]
    tapButton(
      identifier,
      in: app,
      until: exists(destinationAnchor, describedAs: "destination for \(identifier)"),
      retryWhile: hittable(hubButton, describedAs: "hub button \(identifier)"),
      file: file,
      line: line
    )
  }

  @MainActor
  private func tapButton(
    _ identifier: String,
    in app: XCUIApplication,
    until postcondition: UICondition,
    timeout: TimeInterval = UIWait.transition,
    retryWhile retryCondition: UICondition? = nil,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let button = app.buttons[identifier]
    guard scrollToHittable(button, in: app) else {
      XCTFail(
        "Expected button \(identifier) to become hittable",
        file: file,
        line: line
      )
      return
    }

    button.tap()
    if waitForCondition(postcondition, timeout: timeout) {
      return
    }

    if let retryCondition,
      conditionIsSatisfied(retryCondition),
      scrollToHittable(button, in: app, maxSwipes: 1)
    {
      if conditionIsSatisfied(postcondition) {
        return
      }
      if conditionIsSatisfied(retryCondition) {
        button.tap()
        if waitForCondition(postcondition, timeout: timeout) {
          return
        }
      }
    }

    if waitForCondition(postcondition, timeout: UIWait.acknowledgement) {
      return
    }

    XCTFail(
      "Expected button \(identifier) to produce \(postcondition.description)",
      file: file,
      line: line
    )
  }

  @MainActor
  private func scrollToHittable(
    _ element: XCUIElement,
    in app: XCUIApplication,
    maxSwipes: Int = 6
  ) -> Bool {
    if waitForCondition(
      hittable(element, describedAs: "element \(element)"),
      timeout: UIWait.scrollSettle
    ) {
      return true
    }

    for _ in 0..<maxSwipes {
      app.swipeUp()
      if waitForCondition(
        hittable(element, describedAs: "element \(element)"),
        timeout: UIWait.scrollSettle
      ) {
        return true
      }
    }

    return false
  }

  @MainActor
  private func waitForCondition(_ condition: UICondition, timeout: TimeInterval) -> Bool {
    if conditionIsSatisfied(condition) {
      return true
    }

    let expectation = XCTNSPredicateExpectation(
      predicate: condition.predicate,
      object: condition.element
    )
    return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
  }

  @MainActor
  private func conditionIsSatisfied(_ condition: UICondition) -> Bool {
    condition.predicate.evaluate(with: condition.element)
  }

  private func exists(_ element: XCUIElement, describedAs description: String) -> UICondition {
    UICondition(
      element: element,
      predicate: NSPredicate(format: "exists == true"),
      description: description
    )
  }

  private func disappears(
    _ element: XCUIElement,
    describedAs description: String
  ) -> UICondition {
    UICondition(
      element: element,
      predicate: NSPredicate(format: "exists == false"),
      description: description
    )
  }

  private func hittable(_ element: XCUIElement, describedAs description: String) -> UICondition {
    UICondition(
      element: element,
      predicate: NSPredicate(format: "exists == true AND hittable == true"),
      description: description
    )
  }

  private func label(
    of element: XCUIElement,
    equals expectedLabel: String,
    describedAs description: String
  ) -> UICondition {
    UICondition(
      element: element,
      predicate: NSPredicate(format: "exists == true AND label == %@", expectedLabel),
      description: description
    )
  }

  private func label(
    of element: XCUIElement,
    differsFrom previousLabel: String,
    describedAs description: String
  ) -> UICondition {
    UICondition(
      element: element,
      predicate: NSPredicate(format: "exists == true AND label != %@", previousLabel),
      description: description
    )
  }

  private func label(
    of element: XCUIElement,
    contains text: String,
    describedAs description: String
  ) -> UICondition {
    UICondition(
      element: element,
      predicate: NSPredicate(format: "exists == true AND label CONTAINS %@", text),
      description: description
    )
  }

  private func value(
    of element: XCUIElement,
    equals expectedValue: String,
    describedAs description: String
  ) -> UICondition {
    UICondition(
      element: element,
      predicate: NSPredicate(format: "exists == true AND value == %@", expectedValue),
      description: description
    )
  }

  private func clearedTextField(
    _ element: XCUIElement,
    describedAs description: String
  ) -> UICondition {
    UICondition(
      element: element,
      predicate: NSPredicate { object, _ in
        guard let element = object as? XCUIElement, element.exists else { return false }
        guard let rawValue = element.value else { return true }
        guard let value = rawValue as? String else { return false }
        return value.isEmpty || value == element.placeholderValue
      },
      description: description
    )
  }

  private func switchMatches(
    _ element: XCUIElement,
    isOn: Bool,
    describedAs description: String
  ) -> UICondition {
    UICondition(
      element: element,
      predicate: NSPredicate { object, _ in
        guard let element = object as? XCUIElement else { return false }
        return Self.switchState(of: element) == isOn
      },
      description: description
    )
  }

  @MainActor
  private func enterText(
    _ text: String,
    into element: XCUIElement,
    in app: XCUIApplication,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    guard scrollToHittable(element, in: app) else {
      XCTFail("Expected text field to become hittable", file: file, line: line)
      return
    }

    element.tap()
    element.typeText(text)
    let enteredValue = value(
      of: element,
      equals: text,
      describedAs: "text field value \(text)"
    )
    XCTAssertTrue(
      waitForCondition(enteredValue, timeout: UIWait.acknowledgement),
      "Expected \(enteredValue.description)",
      file: file,
      line: line
    )
  }

  @MainActor
  private func setSwitch(
    _ element: XCUIElement,
    to isOn: Bool,
    in app: XCUIApplication,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let targetState = switchMatches(
      element,
      isOn: isOn,
      describedAs: "switch \(element) to become \(isOn ? "on" : "off")"
    )

    for _ in 0..<2 {
      guard let currentState = Self.switchState(of: element) else {
        XCTFail("Unable to read switch state for \(element)", file: file, line: line)
        return
      }
      if currentState == isOn {
        return
      }

      guard scrollToHittable(element, in: app, maxSwipes: 1) else {
        XCTFail("Expected switch \(element) to become hittable", file: file, line: line)
        return
      }

      guard let stateBeforeTap = Self.switchState(of: element) else {
        XCTFail("Unable to read switch state for \(element)", file: file, line: line)
        return
      }
      if stateBeforeTap == isOn {
        return
      }

      element.tap()
      if waitForCondition(targetState, timeout: UIWait.acknowledgement) {
        return
      }
    }

    XCTFail("Expected \(targetState.description)", file: file, line: line)
  }

  private static func switchState(of element: XCUIElement) -> Bool? {
    switch element.value {
    case let value as Bool:
      return value
    case let value as NSNumber:
      return value.boolValue
    case let value as String:
      let normalizedValue = value.lowercased()
      if ["1", "true", "on", "yes"].contains(normalizedValue) {
        return true
      }
      if ["0", "false", "off", "no"].contains(normalizedValue) {
        return false
      }
      return nil
    default:
      return nil
    }
  }

  @MainActor
  private func dismissKeyboard(in app: XCUIApplication) {
    let keyboard = app.keyboards.element
    guard keyboard.exists else { return }

    let returnKey = app.keyboards.buttons["Return"]
    if returnKey.exists {
      returnKey.tap()
    } else {
      let doneKey = app.keyboards.buttons["Done"]
      if doneKey.exists {
        doneKey.tap()
      } else {
        app.swipeDown()
      }
    }

    _ = waitForCondition(
      disappears(keyboard, describedAs: "keyboard to disappear"),
      timeout: UIWait.acknowledgement
    )
  }

  @MainActor
  func testDemoHubShowsCanonicalSamples() throws {
    let app = launchApp { app in
      exists(
        app.navigationBars["InnoFlow Samples"],
        describedAs: "the sample hub navigation bar"
      )
    }

    for demo in SampleDemo.catalog {
      XCTAssertTrue(
        scrollToHittable(app.buttons[demo.accessibilityIdentifier], in: app),
        "Expected hub button \(demo.accessibilityIdentifier)"
      )
    }
  }

  @MainActor
  func testDemoHubNavigatesToRouterCompositionFlow() throws {
    let app = launchApp(
      environment: ["INNOFLOW_ROUTER_PENDING_DETAIL_ID": "invoice-42"]
    ) { app in
      exists(
        app.navigationBars["InnoFlow Samples"],
        describedAs: "the sample hub navigation bar"
      )
    }

    let signInButton = app.buttons["router.sign-in"]
    openDemoFromHub(
      SampleDemo.routerComposition.metadata.accessibilityIdentifier,
      in: app,
      destinationAnchor: signInButton
    )

    let pendingRoute = app.staticTexts["router.pending-route"]
    XCTAssertTrue(
      waitForCondition(
        label(
          of: pendingRoute,
          equals: "Pending route: detail(invoice-42)",
          describedAs: "the pending protected route"
        ),
        timeout: UIWait.transition
      )
    )

    let detailTitle = app.staticTexts["router.detail-title"]
    tapButton(
      "router.sign-in",
      in: app,
      until: label(
        of: detailTitle,
        equals: "Protected detail for invoice-42",
        describedAs: "the replayed protected detail"
      )
    )
    XCTAssertEqual(detailTitle.label, "Protected detail for invoice-42")
  }

  @MainActor
  func testDemoHubNavigatesToPhaseDrivenRecoveryFlow() throws {
    let app = launchApp { app in
      exists(
        app.navigationBars["InnoFlow Samples"],
        describedAs: "the sample hub navigation bar"
      )
    }

    let failSwitch = app.switches["phase.fail-next-load"]
    openDemoFromHub(
      SampleDemo.phaseDrivenFSM.metadata.accessibilityIdentifier,
      in: app,
      destinationAnchor: failSwitch
    )

    setSwitch(failSwitch, to: true, in: app)

    let errorMessage = app.staticTexts["phase.error-message"]
    tapButton(
      "phase.load-todos",
      in: app,
      until: label(
        of: errorMessage,
        equals: "Sample network request failed",
        describedAs: "the sample failure message"
      )
    )

    tapButton(
      "phase.dismiss-error",
      in: app,
      until: disappears(errorMessage, describedAs: "the failure message to disappear"),
      retryWhile: exists(errorMessage, describedAs: "the failure message to remain visible")
    )
    setSwitch(failSwitch, to: false, in: app)

    let loadedTodo = app.staticTexts["Document legal transitions"]
    tapButton(
      "phase.load-todos",
      in: app,
      until: exists(loadedTodo, describedAs: "the loaded sample todo")
    )
  }

  @MainActor
  func testRouterCompositionReplaysPendingProtectedDetail() throws {
    let app = launchApp(
      environment: ["INNOFLOW_SAMPLE_DEMO": "router-composition"]
    ) { app in
      exists(
        app.buttons["router.queue-protected-detail"],
        describedAs: "the queue protected detail button"
      )
    }

    let pendingRoute = app.staticTexts["router.pending-route"]
    tapButton(
      "router.queue-protected-detail",
      in: app,
      until: label(
        of: pendingRoute,
        equals: "Pending route: detail(invoice-42)",
        describedAs: "the pending protected route"
      ),
      retryWhile: disappears(
        pendingRoute,
        describedAs: "the pending protected route to remain absent"
      )
    )

    let detailTitle = app.staticTexts["router.detail-title"]
    tapButton(
      "router.sign-in",
      in: app,
      until: label(
        of: detailTitle,
        equals: "Protected detail for invoice-42",
        describedAs: "the replayed protected detail"
      )
    )
    XCTAssertEqual(detailTitle.label, "Protected detail for invoice-42")
  }

  @MainActor
  func testPhaseDrivenFlowRecoversFromFailureAndLoadsTodos() throws {
    let app = launchApp(
      environment: ["INNOFLOW_SAMPLE_DEMO": "phase-driven-fsm"]
    ) { app in
      exists(
        app.switches["phase.fail-next-load"],
        describedAs: "the fail-next-load switch"
      )
    }

    let failSwitch = app.switches["phase.fail-next-load"]
    setSwitch(failSwitch, to: true, in: app)

    let errorMessage = app.staticTexts["phase.error-message"]
    tapButton(
      "phase.load-todos",
      in: app,
      until: label(
        of: errorMessage,
        equals: "Sample network request failed",
        describedAs: "the sample failure message"
      )
    )
    XCTAssertEqual(errorMessage.label, "Sample network request failed")

    tapButton(
      "phase.dismiss-error",
      in: app,
      until: disappears(errorMessage, describedAs: "the failure message to disappear"),
      retryWhile: exists(errorMessage, describedAs: "the failure message to remain visible")
    )
    setSwitch(failSwitch, to: false, in: app)

    let loadedTodo = app.staticTexts["Document legal transitions"]
    tapButton(
      "phase.load-todos",
      in: app,
      until: exists(loadedTodo, describedAs: "the loaded sample todo")
    )
  }

  @MainActor
  func testFormValidationDemoSubmitsAndResets() throws {
    let app = launchApp(
      environment: ["INNOFLOW_SAMPLE_DEMO": "form-validation"]
    ) { app in
      exists(app.textFields["form.full-name"], describedAs: "the full-name field")
    }

    let fullName = app.textFields["form.full-name"]
    enterText("Ada Lovelace", into: fullName, in: app)

    let email = app.textFields["form.email"]
    enterText("ada@innosquad.com", into: email, in: app)

    let confirmEmail = app.textFields["form.confirm-email"]
    enterText("ada@innosquad.com", into: confirmEmail, in: app)
    dismissKeyboard(in: app)

    let terms = app.switches["form.accept-terms"]
    setSwitch(terms, to: true, in: app)

    let success = app.staticTexts["form.success"]
    tapButton(
      "form.submit",
      in: app,
      until: label(
        of: success,
        equals: "Submitted: Ada Lovelace <ada@innosquad.com>",
        describedAs: "the submitted form summary"
      )
    )

    tapButton(
      "form.reset",
      in: app,
      until: disappears(success, describedAs: "the submitted form summary to disappear"),
      retryWhile: exists(success, describedAs: "the submitted form summary to remain visible")
    )
    let resetSummary = app.staticTexts["form.validation-summary"]
    XCTAssertTrue(
      waitForCondition(
        label(
          of: resetSummary,
          equals: "Submit to run validation.",
          describedAs: "the reset validation summary"
        ),
        timeout: UIWait.acknowledgement
      )
    )
    for (field, description) in [
      (fullName, "the full-name field to be cleared"),
      (email, "the email field to be cleared"),
      (confirmEmail, "the confirmation field to be cleared"),
    ] {
      let clearedField = clearedTextField(field, describedAs: description)
      XCTAssertTrue(
        waitForCondition(clearedField, timeout: UIWait.acknowledgement),
        "Expected \(clearedField.description)"
      )
    }
    XCTAssertTrue(
      waitForCondition(
        switchMatches(
          terms,
          isOn: false,
          describedAs: "the reset terms switch to be off"
        ),
        timeout: UIWait.acknowledgement
      )
    )
  }

  @MainActor
  func testBidirectionalWebSocketDemoEchoesScriptedMessages() throws {
    let app = launchApp(
      environment: ["INNOFLOW_SAMPLE_DEMO": "bidirectional-websocket"]
    ) { app in
      label(
        of: app.staticTexts["websocket.status"],
        equals: "Idle",
        describedAs: "the idle websocket status"
      )
    }

    let status = app.staticTexts["websocket.status"]
    tapButton(
      "websocket.connect",
      in: app,
      until: label(
        of: status,
        differsFrom: "Idle",
        describedAs: "a websocket connection acknowledgement"
      ),
      timeout: UIWait.acknowledgement,
      retryWhile: label(
        of: status,
        equals: "Idle",
        describedAs: "the websocket status to remain idle"
      )
    )
    XCTAssertTrue(
      waitForCondition(
        label(of: status, equals: "Connected", describedAs: "the connected websocket status"),
        timeout: UIWait.transition
      )
    )

    let messageField = app.textFields["websocket.message"]
    enterText("hello", into: messageField, in: app)
    dismissKeyboard(in: app)

    let sendButton = app.buttons["websocket.send"]
    XCTAssertTrue(
      waitForCondition(
        UICondition(
          element: sendButton,
          predicate: NSPredicate(
            format: "exists == true AND enabled == true AND hittable == true"
          ),
          description: "the websocket send button to become enabled"
        ),
        timeout: UIWait.transition
      )
    )

    let transcript = app.staticTexts["websocket.transcript"]
    tapButton(
      "websocket.send",
      in: app,
      until: label(
        of: transcript,
        contains: "echo: hello",
        describedAs: "the echoed websocket message"
      )
    )
    XCTAssertTrue(transcript.label.contains("echo: hello"))

    tapButton(
      "websocket.disconnect",
      in: app,
      until: label(
        of: status,
        equals: "Disconnected",
        describedAs: "the disconnected websocket status"
      ),
      retryWhile: label(
        of: status,
        equals: "Connected",
        describedAs: "the websocket status to remain connected"
      )
    )
    XCTAssertEqual(status.label, "Disconnected")
  }
}
