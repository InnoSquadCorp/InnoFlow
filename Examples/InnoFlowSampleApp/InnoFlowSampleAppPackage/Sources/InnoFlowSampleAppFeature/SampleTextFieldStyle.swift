import SwiftUI

extension View {
  func sampleTextFieldStyle() -> some View {
    #if os(tvOS) || os(watchOS)
      return self
    #else
      return textFieldStyle(.roundedBorder)
    #endif
  }
}
