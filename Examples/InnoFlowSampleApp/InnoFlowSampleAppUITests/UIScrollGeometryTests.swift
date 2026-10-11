import CoreGraphics
import XCTest

final class UIScrollGeometryTests: XCTestCase {
  private let viewport = CGRect(x: 0, y: 0, width: 420, height: 912)

  func testOffscreenAndInvalidFramesDoNotRequestHittability() {
    let frames: [CGRect] = [
      .null,
      .infinite,
      .zero,
      CGRect(x: .nan, y: 0, width: 100, height: 40),
      CGRect(x: 20, y: -120, width: 380, height: 100),
      CGRect(x: 20, y: 912, width: 380, height: 100),
      CGRect(x: 420, y: 100, width: 100, height: 40),
    ]

    for frame in frames {
      var didRequestHitTest = false
      XCTAssertFalse(
        UIScrollGeometry.isHittable(frame: frame, viewport: viewport) {
          didRequestHitTest = true
          return true
        },
        "Invalid or offscreen frame: \(frame)"
      )
      XCTAssertFalse(didRequestHitTest, "Must not hit-test invalid or offscreen geometry")
    }
  }

  func testVisibleGeometryStillRequiresSuccessfulHittability() {
    let frame = CGRect(x: 20, y: 200, width: 380, height: 100)
    for actualHittability in [false, true] {
      var didRequestHitTest = false
      XCTAssertEqual(
        UIScrollGeometry.isHittable(frame: frame, viewport: viewport) {
          didRequestHitTest = true
          return actualHittability
        },
        actualHittability
      )
      XCTAssertTrue(didRequestHitTest)
    }
  }

  func testInvalidViewportDoesNotRequestHittability() {
    let frame = CGRect(x: 20, y: 200, width: 380, height: 100)
    let invalidViewports: [CGRect] = [.null, .infinite, .zero]
    for invalidViewport in invalidViewports {
      var didRequestHitTest = false
      XCTAssertFalse(
        UIScrollGeometry.isHittable(frame: frame, viewport: invalidViewport) {
          didRequestHitTest = true
          return true
        }
      )
      XCTAssertFalse(didRequestHitTest)
    }
  }

  func testPartiallyClippedRouterRowSearchesBackTowardEarlierCatalogRows() {
    // Captured from the failed main UI run: this row was above the visible
    // catalog while the old helper repeatedly swiped up, farther away.
    let router = CGRect(x: 20, y: -18.7, width: 380, height: 102.3)
    XCTAssertFalse(UIScrollGeometry.swipeUpFirst(target: router, viewport: viewport))
    XCTAssertFalse(
      UIScrollGeometry.isHittable(frame: router, viewport: viewport) { false },
      "Partial screen intersection must not imply that the row is hittable"
    )
  }

  func testSearchDirectionFollowsTargetAfterReturningFromNavigation() {
    let earlierRow = CGRect(x: 20, y: -400, width: 380, height: 100)
    let laterRow = CGRect(x: 20, y: 1_100, width: 380, height: 100)
    XCTAssertFalse(UIScrollGeometry.swipeUpFirst(target: earlierRow, viewport: viewport))
    XCTAssertTrue(UIScrollGeometry.swipeUpFirst(target: laterRow, viewport: viewport))
    XCTAssertTrue(UIScrollGeometry.swipeUpFirst(target: .null, viewport: viewport))
  }
}
