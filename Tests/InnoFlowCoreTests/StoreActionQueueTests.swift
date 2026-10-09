// MARK: - StoreActionQueueTests.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Testing

@testable import InnoFlowCore

@Suite("Store action queue", .serialized)
@MainActor
struct StoreActionQueueTests {
  @Test("Sequential reentry compacts consumed storage without changing FIFO order")
  func sequentialReentryCompactsConsumedStorage() {
    let queue = StoreActionQueue<Int>()
    #expect(queue.beginDrain())

    for value in 0..<10_000 {
      queue.enqueue(value, animation: nil)
      #expect(queue.next()?.action == value)
    }

    #expect(queue.next() == nil)
    let snapshot = queue.finishDrain()

    #expect(snapshot.processedActionCount == 10_000)
    #expect(snapshot.pendingActionHighWaterMark == 1)
    #expect(snapshot.storageHighWaterMark <= 64)
    #expect(snapshot.retainedByteEstimate <= storeActionQueueRetainedStorageBudget)
  }

  @Test("Burst drains losslessly and releases retained storage above the byte budget")
  func burstReleasesExcessRetainedStorage() {
    let queue = StoreActionQueue<Int>()
    let expected = Array(0..<10_000)

    for value in expected {
      queue.enqueue(value, animation: nil)
    }

    #expect(queue.beginDrain())
    var received: [Int] = []
    while let queued = queue.next() {
      received.append(queued.action)
    }
    let snapshot = queue.finishDrain()

    #expect(received == expected)
    #expect(snapshot.processedActionCount == expected.count)
    #expect(snapshot.pendingActionHighWaterMark == expected.count)
    #expect(snapshot.storageHighWaterMark == expected.count)
    #expect(snapshot.didReleaseExcessCapacity)
    #expect(snapshot.retainedByteEstimate <= storeActionQueueRetainedStorageBudget)
  }
}
