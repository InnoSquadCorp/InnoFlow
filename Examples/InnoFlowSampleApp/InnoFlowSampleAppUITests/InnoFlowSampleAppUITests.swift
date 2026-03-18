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
    tapButton(identifier, in: app, failureMessage: "Expected sample hub item \(identifier) to become visible")
  }

  @MainActor
  private func tapButton(
    _ identifier: String,
    in app: XCUIApplication,
    failureMessage: String
  ) {
    let button = app.buttons[identifier]
    if button.waitForExistence(timeout: 2) {
      button.tap()
      return
    }

    for _ in 0..<4 {
      app.swipeUp()
      if button.waitForExistence(timeout: 1) {
        button.tap()
        return
      }
    }

    XCTFail(failureMessage)
  }

  @MainActor
  func testDemoHubShowsCanonicalSamples() throws {
    let app = launchApp()

    XCTAssertTrue(app.buttons["sample.basics"].waitForExistence(timeout: 2))
    XCTAssertTrue(app.buttons["sample.orchestration"].exists)
    XCTAssertTrue(app.buttons["sample.phase-driven-fsm"].exists)
    XCTAssertTrue(app.buttons["sample.router-composition"].exists)
  }

  @MainActor
  func testDemoHubNavigatesToRouterCompositionFlow() throws {
    let app = launchApp(environment: ["INNOFLOW_ROUTER_PENDING_DETAIL_ID": "invoice-42"])

    openDemoFromHub("sample.router-composition", in: app)
    tapButton("router.sign-in", in: app, failureMessage: "Expected router sign-in button after hub navigation")

    XCTAssertTrue(app.staticTexts["router.detail-title"].waitForExistence(timeout: 4))
    XCTAssertEqual(app.staticTexts["router.detail-title"].label, "Protected detail for invoice-42")
  }

  @MainActor
  func testDemoHubNavigatesToPhaseDrivenRecoveryFlow() throws {
    let app = launchApp()

    openDemoFromHub("sample.phase-driven-fsm", in: app)

    XCTAssertTrue(app.switches["phase.fail-next-load"].waitForExistence(timeout: 2))

    let failSwitch = app.switches["phase.fail-next-load"]
    if let value = failSwitch.value as? String, value == "0" {
      failSwitch.tap()
    }

    app.buttons["phase.load-todos"].tap()
    XCTAssertTrue(app.staticTexts["phase.error-message"].waitForExistence(timeout: 4))

    app.buttons["phase.dismiss-error"].tap()
    if let value = failSwitch.value as? String, value == "1" {
      failSwitch.tap()
    }

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
    if let value = failSwitch.value as? String, value == "0" {
      failSwitch.tap()
    }

    app.buttons["phase.load-todos"].tap()
    XCTAssertTrue(app.staticTexts["phase.error-message"].waitForExistence(timeout: 4))
    XCTAssertEqual(app.staticTexts["phase.error-message"].label, "Sample network request failed")

    app.buttons["phase.dismiss-error"].tap()
    if let value = failSwitch.value as? String, value == "1" {
      failSwitch.tap()
    }

    app.buttons["phase.load-todos"].tap()
    XCTAssertTrue(app.staticTexts["Document legal transitions"].waitForExistence(timeout: 4))
  }
}
