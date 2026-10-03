import Foundation
import InnoFlowCore

@main struct Consumer {
  static func main() { _ = DispatchID(rawValue: UUID()) }
}
