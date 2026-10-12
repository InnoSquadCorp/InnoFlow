import CoreGraphics
import Testing

@Suite("UI scroll geometry")
struct UIScrollGeometryTests {
  private let viewport = CGRect(x: 0, y: 0, width: 420, height: 912)

  @Test
  func testOffscreenAndInvalidFramesDoNotRequestHittability() {
    let frames: [CGRect] = [
      .null,
      .infinite,
      .zero,
      CGRect(x: CGFloat.nan, y: 0, width: 100, height: 40),
      CGRect(x: 20, y: -120, width: 380, height: 100),
      CGRect(x: 20, y: 912, width: 380, height: 100),
      CGRect(x: 420, y: 100, width: 100, height: 40),
    ]

    for frame in frames {
      var didRequestHitTest = false
      #expect(
        !(UIScrollGeometry.isHittable(frame: frame, viewport: viewport) {
          didRequestHitTest = true
          return true
        }), "Invalid or offscreen frame: \(frame)")
      #expect(!(didRequestHitTest), "Must not hit-test invalid or offscreen geometry")
    }
  }

  @Test
  func testVisibleGeometryStillRequiresSuccessfulHittability() {
    let frame = CGRect(x: 20, y: 200, width: 380, height: 100)
    for actualHittability in [false, true] {
      var didRequestHitTest = false
      #expect(
        (UIScrollGeometry.isHittable(frame: frame, viewport: viewport) {
          didRequestHitTest = true
          return actualHittability
        }) == (actualHittability))
      #expect(didRequestHitTest)
    }
  }

  @Test
  func testInvalidViewportDoesNotRequestHittability() {
    let frame = CGRect(x: 20, y: 200, width: 380, height: 100)
    let invalidViewports: [CGRect] = [.null, .infinite, .zero]
    for invalidViewport in invalidViewports {
      var didRequestHitTest = false
      #expect(
        !(UIScrollGeometry.isHittable(frame: frame, viewport: invalidViewport) {
          didRequestHitTest = true
          return true
        }))
      #expect(!(didRequestHitTest))
    }
  }

  @Test
  func testPartiallyClippedRouterRowSearchesBackTowardEarlierCatalogRows() {
    // Captured from the failed main UI run: this row was above the visible
    // catalog while the old helper repeatedly swiped up, farther away.
    let router = CGRect(x: 20, y: -18.7, width: 380, height: 102.3)
    #expect(!(UIScrollGeometry.swipeUpFirst(target: router, viewport: viewport)))
    #expect(
      !(UIScrollGeometry.isHittable(frame: router, viewport: viewport) { false }),
      "Partial screen intersection must not imply that the row is hittable")
  }

  @Test
  func testSearchDirectionFollowsTargetAfterReturningFromNavigation() {
    let earlierRow = CGRect(x: 20, y: -400, width: 380, height: 100)
    let laterRow = CGRect(x: 20, y: 1_100, width: 380, height: 100)
    #expect(!(UIScrollGeometry.swipeUpFirst(target: earlierRow, viewport: viewport)))
    #expect(UIScrollGeometry.swipeUpFirst(target: laterRow, viewport: viewport))
    #expect(UIScrollGeometry.swipeUpFirst(target: .null, viewport: viewport))
  }

  @Test
  func testHubViewportIntersectsListAndAppBelowCurrentNavigationBar() {
    let container = CGRect(x: 10, y: -20, width: 400, height: 1_000)
    let navigationBar = CGRect(x: 0, y: 62, width: 420, height: 60)
    #expect(
      (UIScrollGeometry.viewportBelowNavigationBar(
        container: container, app: viewport, navigationBar: navigationBar))
        == (CGRect(x: 10, y: 122, width: 400, height: 790)))

    // A large-title or changed layout must use the newly measured bar, not a
    // fixed screen inset or the frame from before navigation/scrolling.
    #expect(
      (UIScrollGeometry.viewportBelowNavigationBar(
        container: container,
        app: viewport,
        navigationBar: CGRect(x: 0, y: 62, width: 420, height: 100)))
        == (CGRect(x: 10, y: 162, width: 400, height: 750)))
    #expect(
      (UIScrollGeometry.viewportBelowNavigationBar(
        container: CGRect(x: 20, y: 200, width: 380, height: 500),
        app: viewport,
        navigationBar: navigationBar)) == (CGRect(x: 20, y: 200, width: 380, height: 500)))
  }

  @Test
  func testHubRowUnderNavigationBarDoesNotRequestEvenSuccessfulHittability() {
    // Main run 38185706400 reported AX hittable and tapped (21, 122) twice,
    // although nearly this entire row was above the content viewport.
    let router = CGRect(x: 20, y: 20.67, width: 380, height: 102.33)
    let contentViewport = CGRect(x: 0, y: 122, width: 420, height: 790)
    var didRequestHitTest = false
    #expect(
      !(UIScrollGeometry.isHittable(
        frame: router, viewport: contentViewport, requiresFullVisibility: true
      ) {
        didRequestHitTest = true
        return true
      }))
    #expect(!(didRequestHitTest))
    #expect(!(UIScrollGeometry.swipeUpFirst(target: router, viewport: contentViewport)))
  }

  @Test
  func testHubRowsClippedAtAnyViewportEdgeDoNotRequestHittability() {
    let contentViewport = CGRect(x: 10, y: 122, width: 400, height: 750)
    let clippedRows = [
      CGRect(x: 20, y: 121, width: 380, height: 100),
      CGRect(x: 20, y: 773, width: 380, height: 100),
      CGRect(x: 9, y: 200, width: 380, height: 100),
      CGRect(x: 31, y: 200, width: 380, height: 100),
    ]
    for row in clippedRows {
      var didRequestHitTest = false
      #expect(
        !(UIScrollGeometry.isHittable(
          frame: row, viewport: contentViewport, requiresFullVisibility: true
        ) {
          didRequestHitTest = true
          return true
        }))
      #expect(!(didRequestHitTest))
    }
  }

  @Test
  func testFullyVisibleHubRowStillRequiresActualHittability() {
    let contentViewport = CGRect(x: 10, y: 122, width: 400, height: 750)
    let rows = [contentViewport, CGRect(x: 20, y: 200, width: 380, height: 100)]
    for row in rows {
      for actualHittability in [false, true] {
        var didRequestHitTest = false
        #expect(
          (UIScrollGeometry.isHittable(
            frame: row, viewport: contentViewport, requiresFullVisibility: true
          ) {
            didRequestHitTest = true
            return actualHittability
          }) == (actualHittability))
        #expect(didRequestHitTest)
      }
    }
    #expect(
      UIScrollGeometry.isHittable(
        frame: CGRect(x: 20, y: 100, width: 380, height: 100), viewport: contentViewport
      ) { true }, "Non-hub controls retain their existing partial-visibility hit-test behavior")
  }

  @Test
  func testMissingOrInvalidHubGeometryFailsClosed() {
    let invalidFrames: [CGRect] = [
      .null, .infinite, .zero, CGRect(x: CGFloat.nan, y: 0, width: 420, height: 60),
    ]
    let bar = CGRect(x: 0, y: 62, width: 420, height: 60)
    for invalid in invalidFrames {
      #expect(
        UIScrollGeometry.viewportBelowNavigationBar(
          container: invalid, app: viewport, navigationBar: bar
        ).isNull)
      #expect(
        UIScrollGeometry.viewportBelowNavigationBar(
          container: viewport, app: invalid, navigationBar: bar
        ).isNull)
      #expect(
        UIScrollGeometry.viewportBelowNavigationBar(
          container: viewport, app: viewport, navigationBar: invalid
        ).isNull)
    }
    #expect(
      UIScrollGeometry.viewportBelowNavigationBar(
        container: CGRect(x: 0, y: 1_000, width: 420, height: 100),
        app: viewport, navigationBar: bar
      ).isNull)
    #expect(
      UIScrollGeometry.viewportBelowNavigationBar(
        container: viewport, app: viewport,
        navigationBar: CGRect(x: 0, y: 62, width: 420, height: 850)
      ).isNull)
  }
}
