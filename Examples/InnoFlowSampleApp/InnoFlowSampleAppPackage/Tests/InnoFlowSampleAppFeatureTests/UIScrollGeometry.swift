import CoreGraphics

// Test-only geometry checks. A visible frame permits an XCTest hit test; it
// never substitutes for that hit test or proves that a control is tappable.
enum UIScrollGeometry {
  static func isHittable(
    frame: CGRect,
    viewport: CGRect,
    requiresFullVisibility: Bool = false,
    hitTest: () -> Bool
  ) -> Bool {
    guard isUsable(frame), isUsable(viewport), !frame.intersection(viewport).isEmpty else {
      return false
    }
    if requiresFullVisibility && !viewport.contains(frame) {
      return false
    }
    return hitTest()
  }

  static func viewportBelowNavigationBar(
    container: CGRect,
    app: CGRect,
    navigationBar: CGRect
  ) -> CGRect {
    guard isUsable(container), isUsable(app), isUsable(navigationBar) else { return .null }
    let visibleContainer = container.intersection(app)
    guard isUsable(visibleContainer) else { return .null }
    let top = max(visibleContainer.minY, navigationBar.maxY)
    guard top < visibleContainer.maxY else { return .null }
    return CGRect(
      x: visibleContainer.minX,
      y: top,
      width: visibleContainer.width,
      height: visibleContainer.maxY - top
    )
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
