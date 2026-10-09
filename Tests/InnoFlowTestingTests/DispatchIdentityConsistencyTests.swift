import Foundation
import InnoFlowCore
import InnoFlowTesting
import Testing

@Suite("Dispatch identity and timing schema")
struct DispatchIdentityConsistencyTests {
  @Test func monotonicWithinProcessAndUniqueAcrossConcurrentCallers() async {
    let first = DispatchID()
    let next = DispatchID()
    #expect(next.rawValue > first.rawValue)
    #expect(next.description == String(next.rawValue))
    let values = await withTaskGroup(of: UInt64.self, returning: [UInt64].self) { group in
      for _ in 0..<1_000 { group.addTask { DispatchID().rawValue } }
      var values: [UInt64] = []
      for await value in group { values.append(value) }
      return values
    }
    #expect(Set(values).count == 1_000)
    #expect(values.allSatisfy { $0 > next.rawValue })
  }

  @Test func numericTimingSchemaRoundTripsAndOldAbsentIDRemainsReadable() throws {
    let entry = EffectTimingRecorder.Entry(
      phase: .runStarted, sequence: 1, effectID: nil, actionLabel: nil, dispatchID: UInt64.max,
      timestampNanos: 10)
    let data = try JSONEncoder().encode(entry)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["schemaVersion"] as? Int == 2)
    #expect(!(object["dispatchID"] is String))
    #expect(try JSONDecoder().decode(EffectTimingRecorder.Entry.self, from: data) == entry)
    let legacyWithoutID = Data(#"{"phase":"runStarted","sequence":1,"timestampNanos":10}"#.utf8)
    #expect(
      try JSONDecoder().decode(EffectTimingRecorder.Entry.self, from: legacyWithoutID).dispatchID
        == nil)
  }

  @Test func legacyUUIDAndFutureSchemasFailExplicitly() throws {
    let uuid = Data(
      #"{"phase":"runStarted","sequence":1,"timestampNanos":10,"dispatchID":"00000000-0000-0000-0000-000000000001"}"#
        .utf8)
    do {
      _ = try JSONDecoder().decode(EffectTimingRecorder.Entry.self, from: uuid)
      Issue.record("Legacy UUID timing captures must not be silently discarded or coerced")
    } catch DecodingError.dataCorrupted(let context) {
      #expect(context.debugDescription.contains("migrate-effect-timing-jsonl.py"))
    }
    let future = Data(
      #"{"schemaVersion":99,"phase":"runStarted","sequence":1,"timestampNanos":10}"#.utf8)
    #expect(throws: (any Error).self) {
      try JSONDecoder().decode(EffectTimingRecorder.Entry.self, from: future)
    }
  }
}
