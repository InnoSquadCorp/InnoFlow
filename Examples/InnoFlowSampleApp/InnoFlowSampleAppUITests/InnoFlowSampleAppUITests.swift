import InnoFlowSampleAppFeature
import XCTest

final class InnoFlowSampleAppUITests: XCTestCase {
  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  @MainActor
  private func launchApp(environment: [String: String] = [:]) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchEnvironment.merge(environment) { _, new in new }
    app.launch()
    return app
  }

  @MainActor
  private func openDemoFromHub(_ identifier: String, in app: XCUIApplication) {
    tapButton(
      identifier, in: app,
      failureMessage: "Expected sample hub item \(identifier) to become visible")
  }

  @MainActor
  private func tapButton(
    _ identifier: String,
    in app: XCUIApplication,
    failureMessage: String
  ) {
    let button = app.buttons[identifier]
    if waitForElement(button, in: app, requireHittable: true) {
      button.tap()
      return
    }

    XCTFail(failureMessage)
  }

  @MainActor
  private func waitForElement(
    _ element: XCUIElement,
    in app: XCUIApplication,
    timeout: TimeInterval = 2,
    scrollAttempts: Int = 4,
    requireHittable: Bool = false
  ) -> Bool {
    if element.waitForExistence(timeout: timeout),
      waitForElementReadiness(element, timeout: 1, requireHittable: requireHittable)
    {
      return true
    }

    for _ in 0..<scrollAttempts {
      app.swipeUp()
      if element.waitForExistence(timeout: 1),
        waitForElementReadiness(element, timeout: 1, requireHittable: requireHittable)
      {
        return true
      }
    }

    return false
  }

  @MainActor
  private func waitForElementReadiness(
    _ element: XCUIElement,
    timeout: TimeInterval,
    requireHittable: Bool
  ) -> Bool {
    guard requireHittable else { return true }
    if element.isHittable { return true }

    let predicate = NSPredicate(format: "hittable == true")
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
    return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
  }

  @MainActor
  private func setSwitch(
    _ element: XCUIElement,
    to isOn: Bool,
    in app: XCUIApplication,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertTrue(
      waitForElement(element, in: app, requireHittable: true),
      "Expected switch \(element) to become hittable",
      file: file,
      line: line
    )

    if !Self.switchStateMatches(element, isOn: isOn) {
      element.tap()
    }

    let predicate = NSPredicate { object, _ in
      guard let element = object as? XCUIElement else { return false }
      return Self.switchStateMatches(element, isOn: isOn)
    }
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
    XCTAssertEqual(
      XCTWaiter().wait(for: [expectation], timeout: 2),
      .completed,
      "Expected switch \(element) to become \(isOn ? "on" : "off")",
      file: file,
      line: line
    )
  }

  private static func switchStateMatches(_ element: XCUIElement, isOn: Bool) -> Bool {
    let actualValue: Bool
    switch element.value {
    case let value as Bool:
      actualValue = value
    case let value as NSNumber:
      actualValue = value.boolValue
    case let value as String:
      actualValue = ["1", "true", "on", "yes"].contains(value.lowercased())
    default:
      actualValue = false
    }
    return actualValue == isOn
  }

  @MainActor
  private func dismissKeyboard(in app: XCUIApplication) {
    guard app.keyboards.element.exists else { return }

    let returnKey = app.keyboards.buttons["Return"]
    if returnKey.exists {
      returnKey.tap()
      return
    }

    let doneKey = app.keyboards.buttons["Done"]
    if doneKey.exists {
      doneKey.tap()
      return
    }

    app.swipeDown()
  }

  @MainActor
  func testDemoHubShowsCanonicalSamples() throws {
    let app = launchApp()

    for demo in SampleDemo.catalog {
      XCTAssertTrue(
        waitForElement(app.buttons[demo.accessibilityIdentifier], in: app, requireHittable: true),
        "Expected hub button \(demo.accessibilityIdentifier)"
      )
    }
  }

  @MainActor
  func testDemoHubNavigatesToRouterCompositionFlow() throws {
    let app = launchApp(environment: ["INNOFLOW_ROUTER_PENDING_DETAIL_ID": "invoice-42"])

    openDemoFromHub(SampleDemo.routerComposition.metadata.accessibilityIdentifier, in: app)
    tapButton(
      "router.sign-in", in: app,
      failureMessage: "Expected router sign-in button after hub navigation")

    XCTAssertTrue(app.staticTexts["router.detail-title"].waitForExistence(timeout: 4))
    XCTAssertEqual(app.staticTexts["router.detail-title"].label, "Protected detail for invoice-42")
  }

  @MainActor
  func testDemoHubNavigatesToPhaseDrivenRecoveryFlow() throws {
    let app = launchApp()

    openDemoFromHub(SampleDemo.phaseDrivenFSM.metadata.accessibilityIdentifier, in: app)

    XCTAssertTrue(app.switches["phase.fail-next-load"].waitForExistence(timeout: 2))

    let failSwitch = app.switches["phase.fail-next-load"]
    setSwitch(failSwitch, to: true, in: app)

    app.buttons["phase.load-todos"].tap()
    XCTAssertTrue(app.staticTexts["phase.error-message"].waitForExistence(timeout: 4))

    app.buttons["phase.dismiss-error"].tap()
    setSwitch(failSwitch, to: false, in: app)

    app.buttons["phase.load-todos"].tap()
    XCTAssertTrue(app.staticTexts["Document legal transitions"].waitForExistence(timeout: 4))
  }

  @MainActor
  func testRouterCompositionReplaysPendingProtectedDetail() throws {
    let app = launchApp(environment: ["INNOFLOW_SAMPLE_DEMO": "router-composition"])

    XCTAssertTrue(app.buttons["router.queue-protected-detail"].waitForExistence(timeout: 2))

    app.buttons["router.queue-protected-detail"].tap()
    app.buttons["router.sign-in"].tap()

    XCTAssertTrue(app.staticTexts["router.detail-title"].waitForExistence(timeout: 4))
    XCTAssertEqual(app.staticTexts["router.detail-title"].label, "Protected detail for invoice-42")
  }

  @MainActor
  func testPhaseDrivenFlowRecoversFromFailureAndLoadsTodos() throws {
    let app = launchApp(environment: ["INNOFLOW_SAMPLE_DEMO": "phase-driven-fsm"])

    XCTAssertTrue(app.switches["phase.fail-next-load"].waitForExistence(timeout: 2))

    let failSwitch = app.switches["phase.fail-next-load"]
    setSwitch(failSwitch, to: true, in: app)

    app.buttons["phase.load-todos"].tap()
    XCTAssertTrue(app.staticTexts["phase.error-message"].waitForExistence(timeout: 4))
    XCTAssertEqual(app.staticTexts["phase.error-message"].label, "Sample network request failed")

    app.buttons["phase.dismiss-error"].tap()
    setSwitch(failSwitch, to: false, in: app)

    app.buttons["phase.load-todos"].tap()
    XCTAssertTrue(app.staticTexts["Document legal transitions"].waitForExistence(timeout: 4))
  }

  @MainActor
  func testFormValidationDemoSubmitsAndResets() throws {
    let app = launchApp(environment: ["INNOFLOW_SAMPLE_DEMO": "form-validation"])

    let fullName = app.textFields["form.full-name"]
    XCTAssertTrue(fullName.waitForExistence(timeout: 2))
    fullName.tap()
    fullName.typeText("Ada Lovelace")

    let email = app.textFields["form.email"]
    email.tap()
    email.typeText("ada@innosquad.com")

    let confirmEmail = app.textFields["form.confirm-email"]
    confirmEmail.tap()
    confirmEmail.typeText("ada@innosquad.com")
    dismissKeyboard(in: app)

    let terms = app.switches["form.accept-terms"]
    XCTAssertTrue(waitForElement(terms, in: app, requireHittable: true))
    if let value = terms.value as? String, value == "0" {
      terms.tap()
    }

    tapButton("form.submit", in: app, failureMessage: "Expected form submit button")
    XCTAssertTrue(waitForElement(app.staticTexts["form.success"], in: app))

    tapButton("form.reset", in: app, failureMessage: "Expected form reset button")
    XCTAssertFalse(app.staticTexts["form.success"].waitForExistence(timeout: 1))
  }

  @MainActor
  func testBidirectionalWebSocketDemoEchoesScriptedMessages() throws {
    let app = launchApp(environment: ["INNOFLOW_SAMPLE_DEMO": "bidirectional-websocket"])

    tapButton(
      "websocket.connect", in: app,
      failureMessage: "Expected websocket connect button")
    let connectedStatus = app.staticTexts["websocket.status"]
    let connectedPredicate = NSPredicate(format: "label == %@", "Connected")
    expectation(for: connectedPredicate, evaluatedWith: connectedStatus)
    waitForExpectations(timeout: 4)

    let messageField = app.textFields["websocket.message"]
    XCTAssertTrue(messageField.waitForExistence(timeout: 2))
    messageField.tap()
    messageField.typeText("hello")
    dismissKeyboard(in: app)

    let sendButton = app.buttons["websocket.send"]
    let sendReadyPredicate = NSPredicate(format: "enabled == true AND hittable == true")
    expectation(for: sendReadyPredicate, evaluatedWith: sendButton)
    waitForExpectations(timeout: 4)

    tapButton(
      "websocket.send", in: app,
      failureMessage: "Expected websocket send button")
    let transcript = app.staticTexts["websocket.transcript"]
    let echoPredicate = NSPredicate(format: "label CONTAINS %@", "echo: hello")
    expectation(for: echoPredicate, evaluatedWith: transcript)
    waitForExpectations(timeout: 4)
    XCTAssertTrue(transcript.label.contains("echo: hello"))

    tapButton(
      "websocket.disconnect", in: app,
      failureMessage: "Expected websocket disconnect button")
    let status = app.staticTexts["websocket.status"]
    let disconnectedPredicate = NSPredicate(format: "label == %@", "Disconnected")
    expectation(for: disconnectedPredicate, evaluatedWith: status)
    waitForExpectations(timeout: 2)
    XCTAssertEqual(status.label, "Disconnected")
  }
}
