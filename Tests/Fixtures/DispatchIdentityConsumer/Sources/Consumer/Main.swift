import Foundation
import InnoFlowCore
import InnoFlowTesting

@main struct Consumer {
  static func main() throws {
    let first = DispatchID()
    let second = DispatchID()
    let raw: UInt64 = first.rawValue
    precondition(second.rawValue > raw && Set([first, second]).count == 2)
    let oldArgumentShape = EffectTimingRecorder.Entry(
      phase: .runStarted, sequence: 1, effectID: nil, actionLabel: nil, timestampNanos: 1)
    precondition(oldArgumentShape.dispatchID == nil)
    let entry = EffectTimingRecorder.Entry(
      phase: .runStarted, sequence: 1, effectID: nil, actionLabel: nil, dispatchID: raw,
      timestampNanos: 10)
    let data = try JSONEncoder().encode(entry)
    let decoded = try JSONDecoder().decode(EffectTimingRecorder.Entry.self, from: data)
    precondition(decoded == entry)
    let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    precondition(object["schemaVersion"] as? Int == 2)
    if CommandLine.arguments.count == 2 {
      let imported = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        .split(separator: 0x0A).map {
          try JSONDecoder().decode(EffectTimingRecorder.Entry.self, from: Data($0))
        }
      precondition(imported.count == 3)
      precondition(imported[0].dispatchID == imported[2].dispatchID)
      precondition(imported[0].dispatchID != imported[1].dispatchID)
      precondition(imported.allSatisfy { $0.dispatchID != nil })
    }
    print("Dispatch identity consumer passed")
  }
}
