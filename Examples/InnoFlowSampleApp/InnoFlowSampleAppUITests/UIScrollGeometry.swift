import CoreGraphics

// Test-only geometry checks. A visible frame permits an XCTest hit test; it
// never substitutes for that hit test or proves that a control is tappable.
enum UIScrollGeometry {
  static func isHittable(
    frame: CGRect,
    viewport: CGRect,
    hitTest: () -> Bool
  ) -> Bool {
    guard isUsable(frame), isUsable(viewport), !frame.intersection(viewport).isEmpty else {
      return false
    }
    return hitTest()
  }

  static func swipeUpFirst(target: CGRect, viewport: CGRect) -> Bool {
    guard isUsable(target), isUsable(viewport) else { return true }
    return target.midY >= viewport.midY
  }

  private static func isUsable(_ frame: CGRect) -> Bool {
    !frame.isNull && !frame.isInfinite && !frame.isEmpty
      && frame.origin.x.isFinite && frame.origin.y.isFinite
      && frame.size.width.isFinite && frame.size.height.isFinite
  }
}
