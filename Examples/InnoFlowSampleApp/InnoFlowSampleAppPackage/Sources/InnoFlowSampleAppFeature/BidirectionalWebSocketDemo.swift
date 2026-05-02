// Explicitly labeled cross-framework transport sample.
//
// The reducer owns business-facing connection status and transcript entries.
// The websocket adapter owns protocol details, event streams, and reconnect
// mechanics. The default sample dependency is scripted for deterministic UI
// tests; the same reducer also accepts a live InnoNetwork-backed adapter.

import Foundation
import InnoFlow
import InnoNetworkWebSocket
import SwiftUI

public protocol BidirectionalSocketClient: Sendable {
  func connect() async -> AsyncStream<BidirectionalSocketTransportEvent>
  func reconnect() async -> AsyncStream<BidirectionalSocketTransportEvent>
  func disconnect() async
  func send(text: String) async throws -> [BidirectionalSocketTransportEvent]
}

public enum BidirectionalSocketTransportEvent: Equatable, Sendable {
  case connected(String?)
  case disconnected(String)
  case reconnecting(String)
  case received(String)
  case sent(String)
  case transportFailure(String)
}

private enum ScriptedBidirectionalSocketError: LocalizedError, Equatable, Sendable {
  case notConnected

  var errorDescription: String? {
    switch self {
    case .notConnected:
      "Connect the sample transport before sending a message."
    }
  }
}

public struct BidirectionalWebSocketDemoDependencies: Sendable {
  public static let defaultIntegrationNote =
    "Default sample transport is scripted for deterministic UI tests. Swap the dependency to InnoNetworkBidirectionalSocketClient at the app boundary to talk to a live websocket backend that keeps adapter-owned auto-retry enabled and surfaces reconnecting state for retryable transport failures and peer closes."

  public let socketClient: any BidirectionalSocketClient
  public let integrationNote: String

  public init(
    socketClient: any BidirectionalSocketClient,
    integrationNote: String
  ) {
    self.socketClient = socketClient
    self.integrationNote = integrationNote
  }

  public static var scripted: Self {
    .init(
      socketClient: ScriptedBidirectionalSocketClient(),
      integrationNote: Self.defaultIntegrationNote
    )
  }

  public static func live(
    url: URL,
    subprotocols: [String]? = nil,
    configuration: WebSocketConfiguration = .safeDefaults(),
    integrationNote: String = Self.defaultIntegrationNote
  ) -> Self {
    .init(
      socketClient: InnoNetworkBidirectionalSocketClient(
        url: url,
        subprotocols: subprotocols,
        configuration: configuration
      ),
      integrationNote: integrationNote
    )
  }
}

actor ScriptedBidirectionalSocketClient: BidirectionalSocketClient {
  private var continuation: AsyncStream<BidirectionalSocketTransportEvent>.Continuation?
  private var isConnected = false

  func connect() async -> AsyncStream<BidirectionalSocketTransportEvent> {
    continuation?.finish()
    isConnected = true

    return AsyncStream<BidirectionalSocketTransportEvent> { continuation in
      self.continuation = continuation
      continuation.yield(BidirectionalSocketTransportEvent.connected("sample-echo"))
      continuation.onTermination = { _ in
        Task { await self.clearContinuationIfNeeded() }
      }
    }
  }

  func reconnect() async -> AsyncStream<BidirectionalSocketTransportEvent> {
    await disconnect()
    return await connect()
  }

  func disconnect() async {
    guard isConnected else { return }
    isConnected = false
    continuation?.yield(.disconnected("Transport adapter closed the sample connection."))
    continuation?.finish()
    continuation = nil
  }

  func send(text: String) async throws -> [BidirectionalSocketTransportEvent] {
    guard isConnected else { throw ScriptedBidirectionalSocketError.notConnected }
    return [
      .sent(text),
      .received("echo: \(text)"),
    ]
  }

  private func clearContinuationIfNeeded() {
    if !isConnected {
      continuation = nil
    }
  }
}

private enum LiveBidirectionalSocketClientError: LocalizedError, Sendable {
  case notConnected

  var errorDescription: String? {
    switch self {
    case .notConnected:
      "The live websocket task is not connected."
    }
  }
}

enum BidirectionalSocketLiveEventMapper {
  static func map(
    _ event: WebSocketEvent,
    taskState: WebSocketState,
    willRetry: Bool
  ) -> BidirectionalSocketTransportEvent? {
    switch event {
    case .connected(let subprotocol):
      return .connected(subprotocol)

    case .disconnected(let error):
      let reason = describeDisconnect(error)
      if willRetry {
        return .reconnecting(reason)
      }
      return .disconnected(reason)

    case .string(let value):
      return .received(value)

    case .message(let data):
      guard let text = String(data: data, encoding: .utf8) else { return nil }
      return .received(text)

    case .error(let error):
      let reason = String(describing: error)
      if taskState == .reconnecting {
        return .reconnecting(reason)
      }
      return .transportFailure(reason)

    case .pong:
      return nil

    @unknown default:
      return nil
    }
  }

  private static func describeDisconnect(_ error: WebSocketError?) -> String {
    if let error {
      return String(describing: error)
    }
    return "Socket disconnected."
  }
}

public actor InnoNetworkBidirectionalSocketClient: BidirectionalSocketClient {
  // Keep this retryable close-code mirror in sync with
  // InnoNetworkWebSocket.WebSocketCloseDisposition.classifyPeerClose.
  private static let retryablePeerCloseCodes: Set<Int> = [1001, 1006, 1011, 1012, 1013, 1015]

  private let manager: WebSocketManager
  private let url: URL
  private let subprotocols: [String]?
  private let maxReconnectAttempts: Int
  private var task: WebSocketTask?

  public init(
    url: URL,
    subprotocols: [String]? = nil,
    configuration: WebSocketConfiguration = .safeDefaults()
  ) {
    self.url = url
    self.subprotocols = subprotocols
    self.maxReconnectAttempts = configuration.maxReconnectAttempts
    self.manager = WebSocketManager(configuration: configuration)
  }

  public func connect() async -> AsyncStream<BidirectionalSocketTransportEvent> {
    if let task {
      await manager.disconnect(task)
      self.task = nil
    }

    let task = await manager.connect(url: url, subprotocols: subprotocols)
    self.task = task
    return await relayStream(for: task)
  }

  public func reconnect() async -> AsyncStream<BidirectionalSocketTransportEvent> {
    if let task {
      await manager.retry(task)
      return await relayStream(for: task)
    }
    return await connect()
  }

  public func disconnect() async {
    guard let task else { return }
    await manager.disconnect(task)
    self.task = nil
  }

  public func send(text: String) async throws -> [BidirectionalSocketTransportEvent] {
    guard let task else { throw LiveBidirectionalSocketClientError.notConnected }
    try await manager.send(task, string: text)
    return [.sent(text)]
  }

  private func relayStream(
    for task: WebSocketTask
  ) async -> AsyncStream<BidirectionalSocketTransportEvent> {
    let source = await manager.events(for: task)

    return AsyncStream<BidirectionalSocketTransportEvent>(bufferingPolicy: .unbounded) {
      continuation in
      let relayTask = Task {
        for await event in source {
          if let mappedEvent = await mapTransportEvent(event, for: task) {
            continuation.yield(mappedEvent)
          }
        }
        continuation.finish()
      }

      continuation.onTermination = { _ in
        relayTask.cancel()
      }
    }
  }

  private func mapTransportEvent(
    _ event: WebSocketEvent,
    for task: WebSocketTask
  ) async -> BidirectionalSocketTransportEvent? {
    let closeCode = await task.closeCode
    return BidirectionalSocketLiveEventMapper.map(
      event,
      taskState: await task.state,
      willRetry: await transportWillRetryPeerClose(closeCode: closeCode, for: task)
    )
  }

  private func transportWillRetryPeerClose(
    closeCode: URLSessionWebSocketTask.CloseCode?,
    for task: WebSocketTask
  ) async -> Bool {
    guard await task.autoReconnectEnabled else { return false }
    guard let closeCode else { return false }
    guard Self.retryablePeerCloseCodes.contains(Int(closeCode.rawValue)) else { return false }
    return await task.reconnectCount < maxReconnectAttempts
  }
}

@InnoFlow
struct BidirectionalWebSocketFeature {
  struct Dependencies: Sendable {
    let socketClient: any BidirectionalSocketClient
    let integrationNote: String
  }

  struct State: Equatable, Sendable, DefaultInitializable {
    enum ConnectionState: String, Equatable, Sendable {
      case idle
      case connecting
      case connected
      case reconnecting
      case disconnected
    }

    @BindableField var draftMessage = ""
    var connectionState: ConnectionState = .idle
    var statusNote = "Idle"
    var transcript: [String] = []
    var lastError: String?
    var canReconnect = false

    var canSendMessage: Bool {
      connectionState == .connected
        && !draftMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
  }

  enum Action: Equatable, Sendable {
    case setDraftMessage(String)
    case connectTapped
    case reconnectTapped
    case disconnectTapped
    case sendTapped
    case clearTranscript
    case _sendSucceeded
    case _transportEvent(BidirectionalSocketTransportEvent)
  }

  private enum StreamMode {
    case connect
    case reconnect
  }

  private static let streamCancellationID: EffectID = "bidirectional-websocket-stream"
  static let defaultIntegrationNote = BidirectionalWebSocketDemoDependencies.defaultIntegrationNote

  let dependencies: Dependencies

  init(
    dependencies: Dependencies = .init(
      socketClient: ScriptedBidirectionalSocketClient(),
      integrationNote: Self.defaultIntegrationNote
    )
  ) {
    self.dependencies = dependencies
  }

  init(demoDependencies: BidirectionalWebSocketDemoDependencies) {
    self.init(
      dependencies: .init(
        socketClient: demoDependencies.socketClient,
        integrationNote: demoDependencies.integrationNote
      )
    )
  }

  init(
    socketClient: any BidirectionalSocketClient,
    integrationNote: String
  ) {
    self.init(
      dependencies: .init(
        socketClient: socketClient,
        integrationNote: integrationNote
      )
    )
  }

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .setDraftMessage(let value):
        state.draftMessage = value
        state.lastError = nil
        return .none

      case .connectTapped:
        state.connectionState = .connecting
        state.statusNote = "Connecting via adapter"
        state.lastError = nil
        state.canReconnect = false
        return transportStreamEffect(mode: .connect)

      case .reconnectTapped:
        state.connectionState = .reconnecting
        state.statusNote = "Requesting adapter reconnect"
        state.lastError = nil
        state.canReconnect = false
        return transportStreamEffect(mode: .reconnect)

      case .disconnectTapped:
        state.connectionState = .disconnected
        state.statusNote = "Disconnected by sample action"
        state.canReconnect = true
        return .concatenate(
          .cancel(Self.streamCancellationID),
          .run { _, _ in
            await dependencies.socketClient.disconnect()
          }
        )

      case .sendTapped:
        let text = state.draftMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .none }
        let socketClient = dependencies.socketClient
        return .run { send, _ in
          do {
            let transportEvents = try await socketClient.send(text: text)
            await send(._sendSucceeded)
            for event in transportEvents {
              await send(._transportEvent(event))
            }
          } catch {
            await send(._transportEvent(.transportFailure(error.localizedDescription)))
          }
        }

      case .clearTranscript:
        state.transcript = []
        return .none

      case ._sendSucceeded:
        state.draftMessage = ""
        return .none

      case ._transportEvent(let event):
        switch event {
        case .connected(let subprotocol):
          let connectionLabel = subprotocol.map { "Connected via \($0)" } ?? "Connected"
          state.connectionState = .connected
          state.statusNote = connectionLabel
          state.lastError = nil
          state.canReconnect = false
          state.transcript.append("system: \(connectionLabel)")
          return .none

        case .disconnected(let reason):
          state.connectionState = .disconnected
          state.statusNote = "Disconnected"
          state.lastError = nil
          state.canReconnect = true
          state.transcript.append("system: \(reason)")
          return .none

        case .reconnecting(let reason):
          state.connectionState = .reconnecting
          state.statusNote = "Reconnecting"
          state.lastError = nil
          state.canReconnect = false
          state.transcript.append("system: reconnecting via transport adapter \(reason)")
          return .none

        case .received(let text):
          state.statusNote = "Received message"
          state.transcript.append("inbound: \(text)")
          return .none

        case .sent(let text):
          state.statusNote = "Sent message"
          state.transcript.append("outbound: \(text)")
          return .none

        case .transportFailure(let reason):
          state.connectionState = .disconnected
          state.statusNote = "Transport error"
          state.lastError = reason
          state.canReconnect = true
          state.transcript.append("system: transport error \(reason)")
          return .none
        }
      }
    }
  }

  private func transportStreamEffect(mode: StreamMode) -> EffectTask<Action> {
    let socketClient = dependencies.socketClient
    return .run { send, context in
      let stream: AsyncStream<BidirectionalSocketTransportEvent>
      switch mode {
      case .connect:
        stream = await socketClient.connect()
      case .reconnect:
        stream = await socketClient.reconnect()
      }

      do {
        for await event in stream {
          try await context.checkCancellation()
          await send(._transportEvent(event))
        }
      } catch is CancellationError {
        return
      } catch {
        return
      }
    }
    .cancellable(Self.streamCancellationID, cancelInFlight: true)
  }
}

struct BidirectionalWebSocketDemoView: View {
  @State private var store: Store<BidirectionalWebSocketFeature>
  private let integrationNote: String

  @MainActor
  init(
    dependencies: BidirectionalWebSocketDemoDependencies = .scripted
  ) {
    self.init(
      store: Store(
        reducer: BidirectionalWebSocketFeature(demoDependencies: dependencies)
      ),
      integrationNote: dependencies.integrationNote
    )
  }

  @MainActor
  init(
    store: Store<BidirectionalWebSocketFeature>,
    integrationNote: String
  ) {
    _store = State(initialValue: store)
    self.integrationNote = integrationNote
  }

  var body: some View {
    ScrollView {
      VStack(spacing: 16) {
        DemoCard(
          title: "What this demonstrates",
          summary:
            "A reducer attached to a websocket adapter boundary. The reducer owns business-facing status and transcript state; the adapter owns connect, disconnect, retry, and raw transport events, including automatic reconnect transitions for retryable transport failures and peer closes."
        )

        DemoCard(
          title: "Transport ownership",
          summary: integrationNote
        )

        VStack(alignment: .leading, spacing: 12) {
          HStack {
            Text("Status")
              .font(.headline)
            Spacer()
            Text(store.connectionState.rawValue.capitalized)
              .font(.subheadline.monospaced())
              .foregroundStyle(store.connectionState == .connected ? .green : .secondary)
              .accessibilityIdentifier("websocket.status")
          }

          Text(store.statusNote)
            .font(.footnote)
            .foregroundStyle(.secondary)

          TextField(
            "Message",
            text: store.binding(
              \.$draftMessage, to: BidirectionalWebSocketFeature.Action.setDraftMessage)
          )
          .textFieldStyle(.roundedBorder)
          .autocorrectionDisabled()
          .accessibilityIdentifier("websocket.message")

          HStack {
            Button("Connect") {
              store.send(.connectTapped)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("websocket.connect")

            Button("Reconnect") {
              store.send(.reconnectTapped)
            }
            .buttonStyle(.bordered)
            .disabled(!store.canReconnect)
            .accessibilityIdentifier("websocket.reconnect")

            Button("Disconnect") {
              store.send(.disconnectTapped)
            }
            .buttonStyle(.bordered)
            .disabled(store.connectionState == .idle)
            .accessibilityIdentifier("websocket.disconnect")
          }

          HStack {
            Button("Send") {
              store.send(.sendTapped)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!store.canSendMessage)
            .accessibilityIdentifier("websocket.send")

            Button("Clear Log") {
              store.send(.clearTranscript)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("websocket.clear")
          }

          if let lastError = store.lastError {
            Text(lastError)
              .font(.footnote)
              .foregroundStyle(.red)
              .accessibilityIdentifier("websocket.error")
          }

          Text(
            store.transcript.isEmpty
              ? "No websocket events yet."
              : store.transcript.suffix(10).joined(separator: "\n")
          )
          .font(.footnote.monospaced())
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(12)
          .background(Color.primary.opacity(0.04))
          .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
          .accessibilityIdentifier("websocket.transcript")
        }
        .padding()
        .background(Color.primary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
      }
      .padding()
    }
    .navigationTitle("Bidirectional WebSocket")
  }
}

#Preview("Bidirectional WebSocket") {
  NavigationStack {
    BidirectionalWebSocketDemoView()
  }
}
