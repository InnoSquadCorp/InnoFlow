// MARK: - TestStoreDeliveryOrderTests.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

import Foundation
import InnoFlowCore
import InnoFlowTesting
import Testing

@testable import InnoFlowCoreTestSupport

// A `Store` reduces an effect action the moment an effect delivers it, and a
// run's `send` returns only after that reduction. A `TestStore` buffers the
// action until the test receives it. These tests compare what a `Store`
// reduces with what a `TestStore` lets a test receive, exhaustively and
// non-exhaustively, for orders a `Store` fixes: a cancellation that comes
// after a delivery never removes the delivered value; a received action's
// plain follow-ups, at any depth, precede everything delivered after it; and
// a follow-up a `Store` interprets in a task it creates while it handles the
// action comes where that task runs: after the MainActor jobs queued before
// it, such as the rest of the received action's job or an emission already
// on its way when the action was delivered or sent, and before the jobs
// queued after it, such as the run's next emission or the next step of a
// `concatenate` after a run. A cancellation the test issues itself is the
// one exception to the first rule: it lands before the values it covers.
//
// A test queues a MainActor job ahead of its next statement by creating a
// MainActor task that delivers through the store's effect driver, as the
// MainActor job of a run's emission does: created MainActor tasks run in the
// order they are created, so no blocking or sleeping is needed.

private let markID = EffectID<String>("delivery-order-mark")
private let otherID = EffectID<String>("delivery-order-other")
private let runID = EffectID<String>("delivery-order-run")
private let unrelatedID = EffectID<String>("delivery-order-unrelated")

private enum OwnShape: String, CaseIterable, Sendable, CustomTestStringConvertible {
  /// `.concatenate(.send(.mark).cancellable(id), .cancel(id))`, the MIGRATION example.
  case sendThenCancel
  /// `.concatenate(.send(.mark), .cancel(id)).cancellable(id)`.
  case cancellableConcat
  /// `.concatenate(.run { send(.mark) }.cancellable(id), .cancel(id))`.
  case runThenCancel

  var testDescription: String { rawValue }
}

private struct OwnCancellationFeature: Reducer {
  struct State: Equatable, Sendable {
    var log: [String] = []
  }

  enum Action: Equatable, Sendable {
    case start(OwnShape)
    /// A timer and a piece of work under one ID; the work cancels the timer.
    case timerAndWork
    /// Delivers `.mark` under `markID`, then cancels another ID.
    case markThenCancelOther
    /// A run under `markID` delivers `.mark`; nothing of its own cancels it.
    case runUnderMark
    case mark
    case workDone
    case tick
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .start(.sendThenCancel):
      return .concatenate(EffectTask<Action>.send(.mark).cancellable(markID), .cancel(markID))
    case .start(.cancellableConcat):
      return EffectTask<Action>.concatenate(.send(.mark), .cancel(markID)).cancellable(markID)
    case .start(.runThenCancel):
      return .concatenate(
        EffectTask<Action>.run { send in await send(.mark) }.cancellable(markID),
        .cancel(markID)
      )
    case .timerAndWork:
      return .merge(
        EffectTask<Action>.run { send, context in
          // Only cancellation ends the wait: the clock is never advanced.
          try? await context.sleep(for: .seconds(60))
          await send(.tick)
        }
        .cancellable(markID),
        .concatenate(
          EffectTask<Action>.run { send in await send(.workDone) }.cancellable(markID),
          .cancel(markID)
        )
      )
    case .markThenCancelOther:
      return .concatenate(EffectTask<Action>.send(.mark).cancellable(markID), .cancel(otherID))
    case .runUnderMark:
      return EffectTask<Action>.run { send in await send(.mark) }.cancellable(markID)
    case .mark:
      state.log.append("mark")
      return .none
    case .workDone:
      state.log.append("workDone")
      return .none
    case .tick:
      state.log.append("tick")
      return .none
    }
  }
}

private struct FollowUpFeature: Reducer {
  struct State: Equatable, Sendable {
    var log: [String] = []
  }

  enum Action: Equatable, Sendable {
    case start(secondCancelsFollowUp: Bool)
    case first
    case firstFollowUp
    case second(cancelsFollowUp: Bool)
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .start(let cancels):
      return .run { send in
        await send(.first)
        await send(.second(cancelsFollowUp: cancels))
      }
    case .first:
      state.log.append("first")
      return EffectTask<Action>.send(.firstFollowUp).cancellable(markID)
    case .firstFollowUp:
      state.log.append("firstFollowUp")
      return .none
    case .second(let cancels):
      state.log.append("second")
      return .cancel(cancels ? markID : otherID)
    }
  }
}

private struct BehindFeature: Reducer {
  struct State: Equatable, Sendable {
    var log: [String] = []
  }

  enum Action: Equatable, Sendable {
    case start(markCancels: Bool)
    case mark(cancels: Bool)
    case late
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .start(let cancels):
      // `.late` is delivered after `.mark`, then this effect's own cancel
      // settles both.
      return .concatenate(
        .send(.mark(cancels: cancels)),
        EffectTask<Action>.send(.late).cancellable(markID),
        .cancel(markID)
      )
    case .mark(let cancels):
      state.log.append("mark")
      return cancels ? .cancel(markID) : .none
    case .late:
      state.log.append("late")
      return .none
    }
  }
}

private struct OutputFeature: Reducer {
  struct State: Equatable, Sendable {}

  enum Action: Equatable, Sendable {
    case start
  }

  enum Output: Equatable, Sendable {
    case done
  }

  func reduce(into state: inout State, action: Action) -> ReducerEffect<Action, Output> {
    .concatenate(Self.output(.done).cancellable(markID), .cancel(markID))
  }
}

private struct ScopedParentFeature: Reducer {
  struct ChildState: Equatable, Sendable {
    var log: [String] = []
  }

  struct State: Equatable, Sendable {
    var child = ChildState()
  }

  enum ChildAction: Equatable, Sendable {
    case start
    case mark
  }

  enum Action: Equatable, Sendable {
    case child(ChildAction)

    static let childPath = CasePath<Self, ChildAction>(
      embed: Self.child,
      extract: { action in
        guard case .child(let childAction) = action else { return nil }
        return childAction
      }
    )
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .child(.start):
      return .concatenate(
        EffectTask<Action>.send(.child(.mark)).cancellable(markID), .cancel(markID))
    case .child(.mark):
      state.child.log.append("mark")
      return .none
    }
  }
}

/// How an action of a follow-up chain returns the next one.
private enum ChainLink: String, Sendable {
  /// `.send(next)`
  case bare
  /// `.send(next).cancellable(unrelatedID)`
  case wrapped

  func effect<Action: Sendable>(_ next: Action) -> EffectTask<Action> {
    switch self {
    case .bare: .send(next)
    case .wrapped: EffectTask<Action>.send(next).cancellable(unrelatedID)
    }
  }
}

/// A run emits `a1` and `a2`; each `a` starts the chain `a -> f -> g`.
private struct ChainShape: Sendable, CustomTestStringConvertible {
  let first: ChainLink
  let second: ChainLink
  /// Whether `g1` cancels the run.
  let cancelsRun: Bool

  var testDescription: String {
    "\(first.rawValue)-\(second.rawValue)\(cancelsRun ? "-cancelsRun" : "")"
  }

  // Two wrapped links are left out: a `Store` orders the second one against
  // the run's next emission by a race.
  static let all: [Self] = [false, true].flatMap { cancelsRun in
    [(ChainLink.bare, ChainLink.bare), (.bare, .wrapped), (.wrapped, .bare)].map {
      Self(first: $0.0, second: $0.1, cancelsRun: cancelsRun)
    }
  }
}

private struct ChainFeature: Reducer {
  struct State: Equatable, Sendable {
    var log: [String] = []
  }

  enum Action: Equatable, Sendable {
    case start
    case a(Int)
    case f(Int)
    case g(Int)

    init(_ entry: String) {
      let index = Int(entry.dropFirst())!
      switch entry.first {
      case "a": self = .a(index)
      case "f": self = .f(index)
      default: self = .g(index)
      }
    }

    var entry: String {
      switch self {
      case .start: "start"
      case .a(let index): "a\(index)"
      case .f(let index): "f\(index)"
      case .g(let index): "g\(index)"
      }
    }
  }

  let shape: ChainShape

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .start:
      return EffectTask<Action>.run { send in
        await send(.a(1))
        await send(.a(2))
      }
      .cancellable(runID)
    case .a(let index):
      state.log.append("a\(index)")
      return shape.first.effect(.f(index))
    case .f(let index):
      state.log.append("f\(index)")
      return shape.second.effect(.g(index))
    case .g(let index):
      state.log.append("g\(index)")
      return shape.cancelsRun && index == 1 ? .cancel(runID) : .none
    }
  }
}

/// A child run reports progress, the child turns it into a delegate action,
/// and the parent reacts to the delegate action: a chain of plain sends.
private struct ProgressChild: Reducer {
  struct State: Equatable, Sendable {
    var progress: [Int] = []
  }

  enum Action: Equatable, Sendable {
    case start
    case progress(Int)
    case delegate(Int)
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .start:
      return EffectTask<Action>.run { send in
        await send(.progress(1))
        await send(.progress(2))
      }
      .cancellable(runID)
    case .progress(let step):
      state.progress.append(step)
      return .send(.delegate(step))
    case .delegate:
      return .none
    }
  }
}

private struct ProgressParent: Reducer {
  struct State: Equatable, Sendable {
    var child = ProgressChild.State()
    var log: [String] = []
  }

  enum Action: Equatable, Sendable {
    case child(ProgressChild.Action)
    case handled(Int)

    static let childPath = CasePath<Self, ProgressChild.Action>(
      embed: Self.child,
      extract: { action in
        guard case .child(let childAction) = action else { return nil }
        return childAction
      }
    )
  }

  /// The reaction to the first delegate action stops the child's run.
  let stopsAfterFirst: Bool

  private var composed: some Reducer<State, Action, Never> {
    CombineReducers {
      Scope(state: \.child, action: Action.childPath, reducer: ProgressChild())
      Reduce { state, action in
        switch action {
        case .child(.progress(let step)):
          state.log.append("progress\(step)")
          return .none
        case .child(.delegate(let step)):
          state.log.append("delegate\(step)")
          return .send(.handled(step))
        case .child:
          return .none
        case .handled(let step):
          state.log.append("handled\(step)")
          return stopsAfterFirst && step == 1 ? .cancel(runID) : .none
        }
      }
    }
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    composed.reduce(into: &state, action: action)
  }
}

/// `.concatenate(.run { send(.a) }, .run { send(.b) })`: the follow-up of
/// the first run's emission against the emission of the next run.
private enum SequencedShape: String, CaseIterable, Sendable, CustomTestStringConvertible {
  /// `a` returns `.send(.f)`.
  case bare
  /// `a` returns `.send(.f).cancellable(id)` and `b` returns `.cancel(id)`.
  case wrappedThenCancel
  /// `a` and `b` each return `.send(_).cancellable(id, cancelInFlight: true)`,
  /// the shape of differential seed 24.
  case inFlightReplacement

  var testDescription: String { rawValue }
}

private struct SequencedRunsFeature: Reducer {
  struct State: Equatable, Sendable {
    var log: [String] = []
  }

  enum Action: String, Equatable, Sendable {
    case start
    case a
    case f
    case b
    case g

    init(_ entry: String) { self = Self(rawValue: entry)! }
  }

  let shape: SequencedShape

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .start:
      return .concatenate(
        .run { send in await send(.a) },
        .run { send in await send(.b) }
      )
    case .a:
      state.log.append("a")
      switch shape {
      case .bare: return .send(.f)
      case .wrappedThenCancel: return EffectTask<Action>.send(.f).cancellable(markID)
      case .inFlightReplacement:
        return EffectTask<Action>.send(.f).cancellable(markID, cancelInFlight: true)
      }
    case .f:
      state.log.append("f")
      return .none
    case .b:
      state.log.append("b")
      switch shape {
      case .bare: return .none
      case .wrappedThenCancel: return .cancel(markID)
      case .inFlightReplacement:
        return EffectTask<Action>.send(.g).cancellable(markID, cancelInFlight: true)
      }
    case .g:
      state.log.append("g")
      return .none
    }
  }
}

private struct OutputThenActionFeature: Reducer {
  struct State: Equatable, Sendable {
    var log: [String] = []
  }

  enum Action: Equatable, Sendable {
    case start
    case finished
  }

  enum Output: Equatable, Sendable {
    case didStart
  }

  func reduce(into state: inout State, action: Action) -> ReducerEffect<Action, Output> {
    switch action {
    case .start:
      // The output is delivered first; then a run delivers `.finished`.
      return ReducerEffect<Action, Output>.concatenate(
        Self.output(.didStart),
        .run { send in await send(.finished) }
      )
      .cancellable(markID)
    case .finished:
      state.log.append("finished")
      return .cancel(markID)
    }
  }
}

/// A run delivers `.a`, whose follow-up `.f` cancels other work; that work
/// delivers its output only once `.a` was delivered.
private struct ChainCancelsLaterOutputFeature: Reducer {
  struct State: Equatable, Sendable {
    var log: [String] = []
  }

  enum Action: Equatable, Sendable {
    case start
    case a
    case f
  }

  enum Output: Equatable, Sendable {
    case late
  }

  let delivered = RunStartGate()

  func reduce(into state: inout State, action: Action) -> ReducerEffect<Action, Output> {
    switch action {
    case .start:
      let delivered = delivered
      return .merge(
        .run { send in
          await send(.a)
          await delivered.open()
        },
        ReducerEffect<Action, Output>.concatenate(
          .run { _ in await delivered.wait() },
          Self.output(.late)
        )
        .cancellable(markID)
      )
    case .a:
      state.log.append("a")
      return .send(.f)
    case .f:
      state.log.append("f")
      return .cancel(markID)
    }
  }
}

private struct CrossDispatchFeature: Reducer {
  struct State: Equatable, Sendable {
    var log: [String] = []
  }

  enum Action: Equatable, Sendable {
    case startWork
    case startCanceller
    case mark
  }

  /// Opened by the test once both dispatches were sent.
  let go = RunStartGate()
  let delivered = RunStartGate()

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    let (go, delivered) = (go, delivered)
    switch action {
    case .startWork:
      return EffectTask<Action>.run { send in
        await go.wait()
        await send(.mark)
        await delivered.open()
      }
      .cancellable(markID)
    case .startCanceller:
      // Cancels the work only once it has delivered `.mark`.
      return .concatenate(.run { _ in await delivered.wait() }, .cancel(markID))
    case .mark:
      state.log.append("mark")
      return .none
    }
  }
}

/// What the effect of `.start` does after it delivered `.mark` under `markID`.
private enum AfterDeliveryShape: String, CaseIterable, Sendable, CustomTestStringConvertible {
  /// `.concatenate(.send(.mark).cancellable(markID), .cancel(otherID))`
  case continuationCancelsOther
  /// `.concatenate(.send(.mark).cancellable(markID), .run { })`
  case continuationRuns
  /// `.run { send(.mark) }.cancellable(markID)`
  case runReturns
  /// A `merge` sibling cancels another ID once `.mark` was delivered.
  case siblingCancelsOther

  var testDescription: String { rawValue }
}

private struct AfterDeliveryFeature: Reducer {
  struct State: Equatable, Sendable {
    var log: [String] = []
  }

  enum Action: Equatable, Sendable {
    case start(AfterDeliveryShape)
    case mark
  }

  let delivered = RunStartGate()

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .start(.continuationCancelsOther):
      return .concatenate(EffectTask<Action>.send(.mark).cancellable(markID), .cancel(otherID))
    case .start(.continuationRuns):
      return .concatenate(EffectTask<Action>.send(.mark).cancellable(markID), .run { _ in })
    case .start(.runReturns):
      return EffectTask<Action>.run { send in await send(.mark) }.cancellable(markID)
    case .start(.siblingCancelsOther):
      let delivered = delivered
      return .merge(
        EffectTask<Action>.run { send in
          await send(.mark)
          await delivered.open()
        }
        .cancellable(markID),
        .concatenate(.run { _ in await delivered.wait() }, .cancel(otherID))
      )
    case .mark:
      state.log.append("mark")
      return .none
    }
  }
}

private struct DrainTimeoutFeature: Reducer {
  struct State: Equatable, Sendable {
    var log: [String] = []
  }

  enum Action: Equatable, Sendable {
    case start
    case item(Int)
    case other
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    switch action {
    case .start:
      // The trailing cancel of another ID made these actions immune to a
      // test-issued cancellation before.
      return .concatenate(
        EffectTask<Action>.run { send in
          for item in 1...3 { await send(.item(item)) }
        }
        .cancellable(markID),
        .cancel(otherID)
      )
    case .item(let item):
      state.log.append("item\(item)")
      return .none
    case .other:
      state.log.append("other")
      return .none
    }
  }
}

private let followID = EffectID<String>("delivery-order-follow")
private let outerID = EffectID<String>("delivery-order-outer")

/// How an action returns its follow-up. A `Store` drains a plain effect with
/// the reduction and hands a wrapped one to an interpreter job it queues.
private enum FollowUpWrap: String, CaseIterable, Sendable, CustomTestStringConvertible {
  case bare
  case cancellable
  case animation

  var testDescription: String { rawValue }

  func callAsFunction<Action: Sendable, Output: Sendable>(
    _ effect: ReducerEffect<Action, Output>
  ) -> ReducerEffect<Action, Output> {
    switch self {
    case .bare: effect
    case .cancellable: effect.cancellable(followID)
    case .animation: effect.applyingAnimation(EffectAnimation(description: "test") { $0() })
    }
  }
}

/// `.start` delivers `.a` and `.b` from one `concatenate` job.
private enum SiblingShape: String, CaseIterable, Sendable, CustomTestStringConvertible {
  /// `a` returns the follow-up `f`.
  case order
  /// `f` returns the follow-up `g` the same way.
  case chain
  /// `a`'s follow-up is also under `followID`, which `b` cancels.
  case siblingCancelsFollowUp
  /// The `concatenate` is under `outerID`, which `f` cancels.
  case followUpCancelsSibling

  var testDescription: String { rawValue }

  /// What a `Store` reduces.
  func storeLog(_ wrap: FollowUpWrap) -> [String] {
    let drained = wrap == .bare
    switch self {
    case .order: return drained ? ["a", "f", "b"] : ["a", "b", "f"]
    case .chain: return drained ? ["a", "f", "g", "b"] : ["a", "b", "f", "g"]
    case .siblingCancelsFollowUp: return ["a", "b"]
    case .followUpCancelsSibling: return drained ? ["a", "f"] : ["a", "b", "f"]
    }
  }
}

private struct SiblingFeature: Reducer {
  struct State: Equatable, Sendable {
    var log: [String] = []
  }

  enum Action: String, Equatable, Sendable {
    case start, a, b, f, g

    init(_ entry: String) { self = Self(rawValue: entry)! }
  }

  let shape: SiblingShape
  let wrap: FollowUpWrap

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    if action != .start { state.log.append(action.rawValue) }
    switch action {
    case .start:
      let siblings = EffectTask<Action>.concatenate(.send(.a), .send(.b))
      return shape == .followUpCancelsSibling ? siblings.cancellable(outerID) : siblings
    case .a:
      let followUp = wrap(EffectTask<Action>.send(.f))
      return shape == .siblingCancelsFollowUp ? followUp.cancellable(followID) : followUp
    case .b:
      return shape == .siblingCancelsFollowUp ? .cancel(followID) : .none
    case .f:
      switch shape {
      case .chain: return wrap(EffectTask<Action>.send(.g))
      case .followUpCancelsSibling: return .cancel(outerID)
      case .order, .siblingCancelsFollowUp: return .none
      }
    case .g:
      return .none
    }
  }
}

/// An output of a `concatenate` against a follow-up's cancellation.
private enum SiblingOutputShape: String, CaseIterable, Sendable, CustomTestStringConvertible {
  /// `.concatenate(.send(.a), output(.o)).cancellable(outerID)`; `a` returns
  /// the follow-up `f`, which cancels `outerID`.
  case outputBeforeFollowUp
  /// `.concatenate(.send(.a), .send(.b))`; `a` returns the output `o`, under
  /// `followID` unless plain, and `b` cancels `followID`.
  case followUpOutputAfterSibling

  var testDescription: String { rawValue }

  var log: [String] { self == .outputBeforeFollowUp ? ["a", "f"] : ["a", "b"] }

  /// Whether a `Store` publishes `o`.
  func publishes(_ wrap: FollowUpWrap) -> Bool {
    (self == .outputBeforeFollowUp) != (wrap == .bare)
  }
}

private struct SiblingOutputFeature: Reducer {
  struct State: Equatable, Sendable {
    var log: [String] = []
  }

  enum Action: String, Equatable, Sendable {
    case start, a, b, f

    init(_ entry: String) { self = Self(rawValue: entry)! }
  }

  enum Output: Equatable, Sendable {
    case o
  }

  let shape: SiblingOutputShape
  let wrap: FollowUpWrap

  func reduce(into state: inout State, action: Action) -> ReducerEffect<Action, Output> {
    if action != .start { state.log.append(action.rawValue) }
    switch (shape, action) {
    case (.outputBeforeFollowUp, .start):
      return ReducerEffect<Action, Output>.concatenate(.send(.a), Self.output(.o))
        .cancellable(outerID)
    case (.outputBeforeFollowUp, .a):
      return wrap(ReducerEffect<Action, Output>.send(.f))
    case (.outputBeforeFollowUp, .f):
      return .cancel(outerID)
    case (.followUpOutputAfterSibling, .start):
      return .concatenate(.send(.a), .send(.b))
    case (.followUpOutputAfterSibling, .a):
      return wrap == .bare ? Self.output(.o) : wrap(Self.output(.o)).cancellable(followID)
    case (.followUpOutputAfterSibling, .b):
      return .cancel(followID)
    default:
      return .none
    }
  }
}

/// `a` publishes `o`; the effect that delivered `a` publishes `p` after it.
private enum OutputOrderShape: String, CaseIterable, Sendable, CustomTestStringConvertible {
  /// `.concatenate(.send(.a), output(.p))`; `a` returns `output(.o)`.
  case sendThenOutput
  /// `.concatenate(.run { send(.a) }, output(.p))`; `a` returns `output(.o)`.
  case runThenOutput
  /// `.concatenate(.send(.a), output(.p))`; `a` returns `output(.o).cancellable`.
  case sendThenOutputInterpreted

  var testDescription: String { rawValue }

  /// What a `Store` publishes, in order.
  var outputs: [OutputOrderFeature.Output] {
    self == .sendThenOutputInterpreted ? [.p, .o] : [.o, .p]
  }
}

private struct OutputOrderFeature: Reducer {
  struct State: Equatable, Sendable {
    var log: [String] = []
  }

  enum Action: Equatable, Sendable {
    case start
    case a
  }

  enum Output: Equatable, Sendable {
    case o
    case p
  }

  let shape: OutputOrderShape

  func reduce(into state: inout State, action: Action) -> ReducerEffect<Action, Output> {
    switch action {
    case .start:
      return shape == .runThenOutput
        ? .concatenate(.run { send in await send(.a) }, Self.output(.p))
        : .concatenate(.send(.a), Self.output(.p))
    case .a:
      state.log.append("a")
      return shape == .sendThenOutputInterpreted
        ? Self.output(.o).cancellable(followID) : Self.output(.o)
    }
  }
}

/// `w` returns an interpreted follow-up; the effect that delivered `w` goes
/// on to deliver more in a later MainActor job.
private enum LaterJobShape: String, CaseIterable, Sendable, CustomTestStringConvertible {
  /// `.concatenate(.send(.w), .run { send(.v) })`
  case runAfterSend
  /// The same; `v` cancels the follow-up's ID after a `Store` reduced it.
  case runAfterSendCancels
  /// `.concatenate(.send(.w), .run { }, .send(.c))`
  case sendAfterRun

  var testDescription: String { rawValue }

  var storeLog: [String] { self == .sendAfterRun ? ["w", "x", "c"] : ["w", "x", "v"] }
}

private struct LaterJobFeature: Reducer {
  struct State: Equatable, Sendable {
    var log: [String] = []
  }

  enum Action: String, Equatable, Sendable {
    case start, w, x, v, c

    init(_ entry: String) { self = Self(rawValue: entry)! }
  }

  enum Output: Equatable, Sendable {
    case o
  }

  let shape: LaterJobShape
  /// `w` publishes `o` under `followID` instead of sending `x`, and `v`
  /// cancels `followID`.
  var publishes = false

  func reduce(into state: inout State, action: Action) -> ReducerEffect<Action, Output> {
    if action != .start { state.log.append(action.rawValue) }
    switch action {
    case .start:
      return shape == .sendAfterRun
        ? .concatenate(.send(.w), .run { _ in }, .send(.c))
        : .concatenate(.send(.w), .run { send in await send(.v) })
    case .w:
      return publishes
        ? Self.output(.o).cancellable(followID)
        : ReducerEffect<Action, Output>.send(.x).cancellable(followID)
    case .v:
      return publishes || shape == .runAfterSendCancels ? .cancel(followID) : .none
    case .x, .c:
      return .none
    }
  }
}

/// What a `Store` reduces for `action`, after its effect tree is idle.
@MainActor
private func storeLog<R: Reducer>(
  _ reducer: R, _ action: R.Action, state: R.State, log: KeyPath<R.State, [String]>
) async -> [String] {
  let store = Store(reducer: reducer, initialState: state, clock: .manual(ManualTestClock()))
  await store.send(action).finish()
  return store.state[keyPath: log]
}

/// Waits for `condition`, re-evaluating it whenever the test store reports
/// progress, without consuming anything.
@MainActor
private func waitFor<R: Reducer>(
  _ store: TestStore<R>,
  _ condition: @MainActor () -> Bool,
  sourceLocation: SourceLocation = #_sourceLocation
) async where R.State: Equatable {
  let deadline = ContinuousClock.now.advanced(by: scaledTestDeadline(.seconds(10)))
  while true {
    let revision = store.finishActivity.snapshot.revision
    if condition() { return }
    guard await store.finishActivity.waitForChange(after: revision, until: deadline) else {
      Issue.record(
        "The test store made no progress before the deadline", sourceLocation: sourceLocation)
      return
    }
  }
}

@MainActor
private func waitUntilIdle<R: Reducer>(_ store: TestStore<R>) async where R.State: Equatable {
  await waitFor(store) { store.finishActivity.snapshot.activeCount == 0 }
}

// MARK: - Interpreter anchors

private let emitterID = EffectID<String>("delivery-order-emitter")
private let nestedID = EffectID<String>("delivery-order-nested")

/// Queues a MainActor job that delivers `action` through the store's effect
/// driver under `ids`, as the MainActor job of a run's emission does, and
/// then runs `next` in the same job. MainActor tasks run in the order they
/// are created, so the job runs after every job queued before it and before
/// every job queued after it, without blocking or sleeping.
@MainActor
@discardableResult
private func queueEmission<R: Reducer>(
  _ action: R.Action,
  under ids: [AnyEffectID] = [],
  into store: Store<R>,
  then next: (@MainActor @Sendable () -> Void)? = nil
) -> Task<Void, Never> {
  Task { @MainActor in
    let bridge = store.effectBridge
    let context = bridge.makeEffectContext(sequence: bridge.nextSequence(), cancellationIDs: ids)
    store.deliverAction(action, context: context)
    next?()
  }
}

/// The same job for a test store.
@MainActor
@discardableResult
private func queueEmission<R: Reducer>(
  _ action: R.Action,
  under ids: [AnyEffectID] = [],
  into store: TestStore<R>,
  then next: (@MainActor @Sendable () -> Void)? = nil
) -> Task<Void, Never> where R.State: Equatable {
  Task { @MainActor in
    let context = store.makeEffectContext(sequence: store.nextSequence(), cancellationIDs: ids)
    store.deliverAction(action, context: context)
    next?()
  }
}

/// Queues a MainActor job that delivers `action` in a context the store
/// makes now, under `ids`, as a run started before does: a cancellation of
/// one of `ids` before the job runs covers the delivery.
@MainActor
@discardableResult
private func queueEmissionOfEarlierEffect<R: Reducer>(
  _ action: R.Action,
  under ids: [AnyEffectID],
  into store: Store<R>
) -> Task<Void, Never> {
  let bridge = store.effectBridge
  let context = bridge.makeEffectContext(sequence: bridge.nextSequence(), cancellationIDs: ids)
  return Task { @MainActor in store.deliverAction(action, context: context) }
}

/// The same job for a test store.
@MainActor
@discardableResult
private func queueEmissionOfEarlierEffect<R: Reducer>(
  _ action: R.Action,
  under ids: [AnyEffectID],
  into store: TestStore<R>
) -> Task<Void, Never> where R.State: Equatable {
  let context = store.makeEffectContext(sequence: store.nextSequence(), cancellationIDs: ids)
  return Task { @MainActor in store.deliverAction(action, context: context) }
}

/// Returns once every MainActor job queued before the call has run.
@MainActor
private func mainActorBarrier() async {
  await Task { @MainActor in }.value
}

/// Lets a `Store` run the MainActor jobs it queues, one level of interpreter
/// tasks per barrier, until `done` holds.
@MainActor
private func settle(until done: @MainActor () -> Bool) async {
  for _ in 0..<16 where !done() {
    await mainActorBarrier()
  }
}

/// What the interpreted follow-up of `pong` competes with: `x`, delivered by
/// a job queued before `ping` was sent.
private enum CompetingShape: String, CaseIterable, Sendable, CustomTestStringConvertible {
  /// `pong` returns `.send(.p2).cancellable(id)`.
  case order
  /// The same, and `p2` cancels the ID `x` was delivered under.
  case followUpCancelsEmission
  /// `pong` returns `output(.op).cancellable(id)`, and `x` returns `output(.ox)`.
  case outputs

  var testDescription: String { rawValue }

  /// What a `Store` reduces: `pong` during the send, `x` in the queued job,
  /// then the follow-up in the interpreter job queued behind it.
  var log: [String] { self == .outputs ? ["pong", "x"] : ["pong", "x", "p2"] }
}

private struct CompetingFollowUpFeature: Reducer {
  struct State: Equatable, Sendable {
    var log: [String] = []
  }

  enum Action: String, Equatable, Sendable {
    case ping, pong, p2, x
  }

  enum Output: Equatable, Sendable {
    case op, ox
  }

  let shape: CompetingShape

  func reduce(into state: inout State, action: Action) -> ReducerEffect<Action, Output> {
    if action != .ping { state.log.append(action.rawValue) }
    switch action {
    case .ping:
      return .send(.pong)
    case .pong:
      return shape == .outputs
        ? Self.output(.op).cancellable(followID)
        : ReducerEffect<Action, Output>.send(.p2).cancellable(followID)
    case .p2:
      return shape == .followUpCancelsEmission ? .cancel(emitterID) : .none
    case .x:
      return shape == .outputs ? Self.output(.ox) : .none
    }
  }
}

/// When the test receives `pong`, and whether exhaustively.
private struct ReceiveMode: Sendable, CustomTestStringConvertible {
  /// After the queued job and `pong`'s anchor ran, instead of in the job
  /// that sent `ping`.
  let late: Bool
  let exhaustive: Bool

  var testDescription: String {
    "\(late ? "late" : "eager")-\(exhaustive ? "exhaustive" : "nonExhaustive")"
  }

  static let all = [false, true].flatMap { late in
    [true, false].map { Self(late: late, exhaustive: $0) }
  }
}

/// A delivery made between the jobs that deliver `x` and `y`.
private enum InterveningDelivery: String, CaseIterable, Sendable, CustomTestStringConvertible {
  case nothing
  /// Another store delivers `pong`.
  case otherStore
  /// The same store delivers `pong`.
  case sameStore

  var testDescription: String { rawValue }

  /// What a `Store` reduces: `x2` in the interpreter job queued while `x`
  /// was reduced, behind the job that delivers `y`.
  var log: [String] { (self == .sameStore ? ["pong"] : []) + ["x", "y", "x2"] }
}

private struct QueuedEmissionsFeature: Reducer {
  struct State: Equatable, Sendable {
    var log: [String] = []
  }

  enum Action: String, Equatable, Sendable {
    case ping, pong, x, x2, y

    init(_ entry: String) { self = Self(rawValue: entry)! }
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    if action != .ping { state.log.append(action.rawValue) }
    switch action {
    case .ping: return .send(.pong)
    case .x: return EffectTask<Action>.send(.x2).cancellable(followID)
    default: return .none
    }
  }
}

private struct PingFeature: Reducer {
  struct State: Equatable, Sendable {}

  enum Action: Equatable, Sendable {
    case ping, pong
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    action == .ping ? .send(.pong) : .none
  }
}

/// How a sent action returns its follow-up.
private enum SentFollowUpShape: String, CaseIterable, Sendable, CustomTestStringConvertible {
  /// `.send(.pong)`, which a `Store` drains with the send.
  case plain
  /// `.send(.pong).cancellable(id)`, which a `Store` interprets in a job it
  /// queues at the send.
  case wrapped

  var testDescription: String { rawValue }

  var log: [String] { self == .plain ? ["pong", "x"] : ["x", "pong"] }
}

private struct SentFollowUpFeature: Reducer {
  struct State: Equatable, Sendable {
    var log: [String] = []
  }

  enum Action: String, Equatable, Sendable {
    case ping, pong, x

    init(_ entry: String) { self = Self(rawValue: entry)! }
  }

  let shape: SentFollowUpShape

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    if action != .ping { state.log.append(action.rawValue) }
    guard action == .ping else { return .none }
    return shape == .plain ? .send(.pong) : EffectTask<Action>.send(.pong).cancellable(followID)
  }
}

/// `SentFollowUpFeature` as a child, sent through a scoped test store.
private struct ScopedSentFollowUpParent: Reducer {
  struct State: Equatable, Sendable {
    var child = SentFollowUpFeature.State()
  }

  enum Action: Equatable, Sendable {
    case child(SentFollowUpFeature.Action)

    static let childPath = CasePath<Self, SentFollowUpFeature.Action>(
      embed: Self.child,
      extract: { action in
        guard case .child(let childAction) = action else { return nil }
        return childAction
      }
    )
  }

  let shape: SentFollowUpShape

  private var composed: some Reducer<State, Action, Never> {
    Scope(state: \.child, action: Action.childPath, reducer: SentFollowUpFeature(shape: shape))
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    composed.reduce(into: &state, action: action)
  }
}

/// What competes with the interpreted follow-up of an action a send drains.
private enum SendDrainShape: String, CaseIterable, Sendable, CustomTestStringConvertible {
  /// Nothing.
  case alone
  /// `x`, delivered by a job queued before `a` was sent.
  case queuedEmission
  /// The same, and `c` cancels the ID `x` is delivered under.
  case cancelledEmission

  var testDescription: String { rawValue }

  /// What a `Store` reduces: `a`, `b` and `c` during the two sends, then the
  /// queued job, then the interpreter job of `b`, which it created when it
  /// reduced `b` during the first send.
  var log: [String] {
    self == .queuedEmission ? ["a", "b", "c", "x", "b2"] : ["a", "b", "c", "b2"]
  }
}

private let drainedEmissionID = EffectID<String>("delivery-order-drained-emission")

/// `a` returns `.send(.b)`; `b` returns `.send(.b2).cancellable(id)`; `c`
/// returns nothing, or cancels the ID of the queued emission.
private struct SendDrainFeature: Reducer {
  struct State: Equatable, Sendable {
    var log: [String] = []
  }

  enum Action: String, Equatable, Sendable {
    case a, b, b2, c, x

    init(_ entry: String) { self = Self(rawValue: entry)! }
  }

  let shape: SendDrainShape

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    state.log.append(action.rawValue)
    switch action {
    case .a: return .send(.b)
    case .b: return EffectTask<Action>.send(.b2).cancellable(followID)
    case .c: return shape == .cancelledEmission ? .cancel(drainedEmissionID) : .none
    default: return .none
    }
  }
}

/// `SendDrainFeature` as a child, sent through the root or a scoped store.
private struct SendDrainParent: Reducer {
  struct State: Equatable, Sendable {
    var child = SendDrainFeature.State()
  }

  enum Action: Equatable, Sendable {
    case child(SendDrainFeature.Action)

    static let childPath = CasePath<Self, SendDrainFeature.Action>(
      embed: Self.child,
      extract: { action in
        guard case .child(let childAction) = action else { return nil }
        return childAction
      }
    )
  }

  let shape: SendDrainShape

  private var composed: some Reducer<State, Action, Never> {
    Scope(state: \.child, action: Action.childPath, reducer: SendDrainFeature(shape: shape))
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    composed.reduce(into: &state, action: action)
  }
}

/// `a` returns `.send(.b)`; `b`, `b2` and `c` return a wrapped send of the
/// next action, so the sent action's interpreter competes with the follow-up
/// of the drained one.
private struct DeepSendDrainFeature: Reducer {
  struct State: Equatable, Sendable {
    var log: [String] = []
  }

  enum Action: String, Equatable, Sendable {
    case a, b, b2, b3, c, c2

    init(_ entry: String) { self = Self(rawValue: entry)! }
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    state.log.append(action.rawValue)
    switch action {
    case .a: return .send(.b)
    case .b: return EffectTask<Action>.send(.b2).cancellable(followID)
    case .b2: return EffectTask<Action>.send(.b3).cancellable(markID)
    case .c: return EffectTask<Action>.send(.c2).cancellable(otherID)
    default: return .none
    }
  }
}

private let drainThrottleID = EffectID<String>("delivery-order-drain-throttle")

/// `r` returns a throttled `.send(.rl)`, whose walk reads the clock first.
private struct ThrottledDrainFeature: Reducer {
  struct State: Equatable, Sendable {
    var log: [String] = []
  }

  enum Action: String, Equatable, Sendable {
    case r, rl, c, y
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    state.log.append(action.rawValue)
    guard action == .r else { return .none }
    return EffectTask<Action>.send(.rl).throttle(drainThrottleID, for: .seconds(1))
  }
}

/// Interpreted follow-ups two levels deep. `start` delivers `a` and `b` from
/// one job; the tests also deliver them from two jobs, the second queued by
/// the first.
private struct NestedFollowUpFeature: Reducer {
  struct State: Equatable, Sendable {
    var log: [String] = []
  }

  enum Action: String, Equatable, Sendable {
    case start, a, a2, a3, b, b2

    init(_ entry: String) { self = Self(rawValue: entry)! }
  }

  func reduce(into state: inout State, action: Action) -> EffectTask<Action> {
    if action != .start { state.log.append(action.rawValue) }
    switch action {
    case .start: return .concatenate(.send(.a), .send(.b))
    case .a: return EffectTask<Action>.send(.a2).cancellable(followID)
    case .a2: return EffectTask<Action>.send(.a3).cancellable(nestedID)
    case .b: return EffectTask<Action>.send(.b2).cancellable(unrelatedID)
    default: return .none
    }
  }
}

@Suite("TestStore delivery order matches Store", .serialized, .timeLimit(.minutes(2)))
@MainActor
struct TestStoreDeliveryOrderTests {
  @Test(
    "An effect's own later cancel keeps an action it already delivered",
    arguments: OwnShape.allCases, [true, false])
  fileprivate func ownCancelKeepsEarlierDelivery(shape: OwnShape, exhaustive: Bool) async {
    let expected = await storeLog(
      OwnCancellationFeature(), .start(shape), state: .init(), log: \.log)
    #expect(expected == ["mark"])

    let store = TestStore(reducer: OwnCancellationFeature(), initialState: .init())
    store.exhaustivity = exhaustive ? .on : .off
    await store.send(.start(shape))
    // The effect has applied its own cancel when its tree is idle.
    await waitUntilIdle(store)
    if exhaustive {
      await store.receive(.mark) { $0.log = ["mark"] }
    }
    await store.finish()
    #expect(store.state.log == expected)
  }

  @Test("A receive that waits while the effect cancels itself still gets the action")
  func waitingReceiveGetsActionBeforeOwnCancel() async {
    let store = TestStore(reducer: OwnCancellationFeature(), initialState: .init())
    await store.send(.start(.sendThenCancel))
    // No wait: the receive is usually pending when the effect delivers and
    // then cancels; either order must give the test the action.
    await store.receive(.mark) { $0.log = ["mark"] }
    await store.finish()
  }

  @Test(
    "Work that cancels a timer under its own ID keeps its delivered action",
    arguments: [true, false])
  func workCancellingTimerKeepsItsAction(exhaustive: Bool) async {
    let expected = await storeLog(
      OwnCancellationFeature(), .timerAndWork, state: .init(), log: \.log)
    #expect(expected == ["workDone"])

    let store = TestStore(
      reducer: OwnCancellationFeature(), initialState: .init(), clock: ManualTestClock())
    store.exhaustivity = exhaustive ? .on : .off
    await store.send(.timerAndWork)
    // Idle means the work cancelled the timer and the timer's emission was dropped.
    await waitUntilIdle(store)
    if exhaustive {
      await store.receive(.workDone) { $0.log = ["workDone"] }
    }
    await store.finish()
    #expect(store.state.log == expected)
  }

  @Test(
    "Follow-ups of a run's emission precede the run's next emission",
    arguments: [true, false], [true, false])
  func followUpPrecedesNextEmission(secondCancelsFollowUp: Bool, exhaustive: Bool) async {
    let action = FollowUpFeature.Action.start(secondCancelsFollowUp: secondCancelsFollowUp)
    let expected = await storeLog(FollowUpFeature(), action, state: .init(), log: \.log)
    #expect(expected == ["first", "firstFollowUp", "second"])

    let store = TestStore(reducer: FollowUpFeature(), initialState: .init())
    store.exhaustivity = exhaustive ? .on : .off
    await store.send(action)
    // Both emissions are buffered before the test receives the first.
    await waitFor(store) { store.unverifiedSnapshot().actionCount == 2 }
    if exhaustive {
      await store.receive(.first) { $0.log = ["first"] }
      await store.receive(.firstFollowUp) { $0.log = ["first", "firstFollowUp"] }
      await store.receive(.second(cancelsFollowUp: secondCancelsFollowUp)) {
        $0.log = ["first", "firstFollowUp", "second"]
      }
    }
    await store.finish()
    #expect(store.state.log == expected)
  }

  @Test(
    "A received action's cancel removes actions buffered behind it",
    arguments: [true, false], [true, false])
  func receivedCancelRemovesActionsBehindIt(markCancels: Bool, exhaustive: Bool) async {
    let action = BehindFeature.Action.start(markCancels: markCancels)
    let expected = await storeLog(BehindFeature(), action, state: .init(), log: \.log)
    #expect(expected == (markCancels ? ["mark"] : ["mark", "late"]))

    let store = TestStore(reducer: BehindFeature(), initialState: .init())
    store.exhaustivity = exhaustive ? .on : .off
    await store.send(action)
    // `.mark` and `.late` are both buffered when the effect's own cancel runs.
    await waitUntilIdle(store)
    if exhaustive {
      await store.receive(.mark(cancels: markCancels)) { $0.log = ["mark"] }
      if !markCancels {
        await store.receive(.late) { $0.log = ["mark", "late"] }
      }
    }
    await store.finish()
    #expect(store.state.log == expected)
  }

  @Test(
    "A test-issued cancel removes a covered buffered action whatever its effect did since",
    arguments: AfterDeliveryShape.allCases, [false, true])
  fileprivate func testIssuedCancelRemovesCoveredAction(
    shape: AfterDeliveryShape, cancelsAll: Bool
  ) async {
    // A Store reduced `.mark` at its delivery. The test chooses the schedule
    // in which its own cancellation lands first, as in 6.0.x.
    let reduced = await storeLog(AfterDeliveryFeature(), .start(shape), state: .init(), log: \.log)
    #expect(reduced == ["mark"])

    let store = TestStore(reducer: AfterDeliveryFeature(), initialState: .init())
    await store.send(.start(shape))
    await waitUntilIdle(store)
    #expect(store.unverifiedSnapshot().actionCount == 1)
    if cancelsAll {
      await store.cancelAllEffects()
    } else {
      await store.cancelEffects(identifiedBy: markID)
    }
    #expect(store.unverifiedSnapshot().actionCount == 0)
    await store.finish()
    #expect(store.state.log.isEmpty)
  }

  @Test("A send that times out draining removes the buffered actions it did not reduce")
  func sendDrainTimeoutRemovesRemainingActions() async {
    let store = TestStore(
      reducer: DrainTimeoutFeature(), initialState: .init(), effectTimeout: .zero)
    var failures: [String] = []
    store.issueReporter = { message, _ in failures.append(message) }
    await store.send(.start)
    await waitUntilIdle(store)
    #expect(store.unverifiedSnapshot().actionCount == 3)
    // One buffered action is reduced; the deadline stops the drain at the next.
    await store.send(.other) { $0.log = ["item1", "other"] }
    #expect(failures.count == 1)
    #expect(failures.first?.contains("Timed out draining effect actions") == true)
    #expect(store.unverifiedSnapshot().actionCount == 0)
    await store.finish()
    #expect(failures.count == 1)
  }

  @Test("Cancelling the dispatch removes a buffered action its effect's own cancel has passed")
  func dispatchCancelRemovesDeliveredAction() async {
    let store = TestStore(reducer: OwnCancellationFeature(), initialState: .init())
    let dispatch = await store.send(.start(.sendThenCancel))
    await waitUntilIdle(store)
    #expect(store.unverifiedSnapshot().actionCount == 1)
    dispatch.cancel()
    #expect(store.unverifiedSnapshot().actionCount == 0)
    // The removed action no longer holds the dispatch open.
    await dispatch.finish()
    #expect(dispatch.isFinished)
    await store.finish()
    #expect(store.state.log.isEmpty)
  }

  @Test("An output delivered before its effect's own cancel is received", arguments: [true, false])
  func outputBeforeOwnCancelIsReceived(exhaustive: Bool) async {
    let outputStore = Store(reducer: OutputFeature(), initialState: .init())
    let captured = outputStore.send(.start, capturingOutputs: .unbounded)
    var expected: [OutputFeature.Output] = []
    for await output in captured.outputs { expected.append(output) }
    withExtendedLifetime(outputStore) {}
    #expect(expected == [.done])

    let store = TestStore(reducer: OutputFeature(), initialState: .init())
    store.exhaustivity = exhaustive ? .on : .off
    await store.send(.start)
    await waitUntilIdle(store)
    await store.receiveOutput(.done, timeout: .zero)
    await store.finish()
  }

  @Test("A scoped receive gets a child action its effect's own cancel has passed")
  func scopedReceiveGetsDeliveredAction() async {
    let store = TestStore(reducer: ScopedParentFeature(), initialState: .init())
    let child = store.scope(state: \.child, action: ScopedParentFeature.Action.childPath)
    await child.send(.start)
    await waitUntilIdle(store)
    await child.receive(.mark) { $0.log = ["mark"] }
    await store.finish()
  }

  @Test(
    "A received action's follow-up chain precedes its run's next emission",
    arguments: ChainShape.all, [true, false])
  fileprivate func followUpChainPrecedesNextEmission(shape: ChainShape, exhaustive: Bool) async {
    let feature = ChainFeature(shape: shape)
    let expected = await storeLog(feature, .start, state: .init(), log: \.log)
    let first = ["a1", "f1", "g1"]
    #expect(expected == (shape.cancelsRun ? first : first + ["a2", "f2", "g2"]))

    let store = TestStore(reducer: feature, initialState: .init())
    store.exhaustivity = exhaustive ? .on : .off
    await store.send(.start)
    // Both emissions are buffered before the test receives the first.
    await waitFor(store) { store.unverifiedSnapshot().actionCount == 2 }
    if exhaustive {
      var log: [String] = []
      for entry in expected {
        log.append(entry)
        await store.receive(ChainFeature.Action(entry)) { [log] in $0.log = log }
      }
    }
    await store.finish()
    #expect(store.state.log == expected)
  }

  @Test(
    "A delegate chain of a child's emission precedes the child's next emission",
    arguments: [false, true], [true, false])
  func delegateChainPrecedesNextEmission(stopsAfterFirst: Bool, exhaustive: Bool) async {
    let feature = ProgressParent(stopsAfterFirst: stopsAfterFirst)
    let expected = await storeLog(feature, .child(.start), state: .init(), log: \.log)
    let steps = stopsAfterFirst ? [1] : [1, 2]
    #expect(expected == steps.flatMap { ["progress\($0)", "delegate\($0)", "handled\($0)"] })

    let store = TestStore(reducer: feature, initialState: .init())
    store.exhaustivity = exhaustive ? .on : .off
    await store.send(.child(.start))
    await waitFor(store) { store.unverifiedSnapshot().actionCount == 2 }
    if exhaustive {
      for step in steps {
        await store.receive(.child(.progress(step))) {
          $0.child.progress.append(step)
          $0.log.append("progress\(step)")
        }
        await store.receive(.child(.delegate(step))) { $0.log.append("delegate\(step)") }
        await store.receive(.handled(step)) { $0.log.append("handled\(step)") }
      }
    }
    await store.finish()
    #expect(store.state.log == expected)
  }

  @Test(
    "A follow-up of a run's emission precedes the next run of the same concatenate",
    arguments: SequencedShape.allCases, [true, false])
  fileprivate func followUpPrecedesNextConcatenatedRun(
    shape: SequencedShape, exhaustive: Bool
  ) async {
    let feature = SequencedRunsFeature(shape: shape)
    let expected = await storeLog(feature, .start, state: .init(), log: \.log)
    #expect(expected == (shape == .inFlightReplacement ? ["a", "f", "b", "g"] : ["a", "f", "b"]))

    let store = TestStore(reducer: feature, initialState: .init())
    store.exhaustivity = exhaustive ? .on : .off
    await store.send(.start)
    // The second run delivers `.b` without waiting for the test.
    await waitFor(store) { store.unverifiedSnapshot().actionCount == 2 }
    if exhaustive {
      var log: [String] = []
      for entry in expected {
        log.append(entry)
        await store.receive(SequencedRunsFeature.Action(entry)) { [log] in $0.log = log }
      }
    }
    await store.finish()
    #expect(store.state.log == expected)
  }

  @Test(
    "An output delivered before a received action survives that action's cancel",
    arguments: [true, false])
  func outputBeforeReceivedActionSurvivesItsCancel(exhaustive: Bool) async {
    let outputStore = Store(reducer: OutputThenActionFeature(), initialState: .init())
    let captured = outputStore.send(.start, capturingOutputs: .unbounded)
    var expected: [OutputThenActionFeature.Output] = []
    for await output in captured.outputs { expected.append(output) }
    #expect(expected == [.didStart])
    #expect(outputStore.state.log == ["finished"])

    let store = TestStore(reducer: OutputThenActionFeature(), initialState: .init())
    store.exhaustivity = exhaustive ? .on : .off
    await store.send(.start)
    await waitUntilIdle(store)
    await store.receive(.finished) { $0.log = ["finished"] }
    await store.receiveOutput(.didStart, timeout: .zero)
    await store.finish()
  }

  @Test(
    "A follow-up's cancel removes an output delivered after its chain began",
    arguments: [true, false])
  func followUpCancelRemovesLaterOutput(exhaustive: Bool) async {
    let outputStore = Store(reducer: ChainCancelsLaterOutputFeature(), initialState: .init())
    let captured = outputStore.send(.start, capturingOutputs: .unbounded)
    var expected: [ChainCancelsLaterOutputFeature.Output] = []
    for await output in captured.outputs { expected.append(output) }
    #expect(expected.isEmpty)
    #expect(outputStore.state.log == ["a", "f"])

    let store = TestStore(reducer: ChainCancelsLaterOutputFeature(), initialState: .init())
    store.exhaustivity = exhaustive ? .on : .off
    await store.send(.start)
    // `.a`, then the output, are delivered before the test receives `.a`.
    await waitUntilIdle(store)
    #expect(store.unverifiedSnapshot().outputCount == 1)
    await store.receive(.a) { $0.log = ["a"] }
    await store.receive(.f) { $0.log = ["a", "f"] }
    #expect(store.unverifiedSnapshot().outputCount == 0)
    await store.finish()
  }

  @Test(
    "Another dispatch's cancel after the delivery keeps the delivered action",
    arguments: [true, false])
  func otherDispatchCancelKeepsDeliveredAction(exhaustive: Bool) async {
    let storeFeature = CrossDispatchFeature()
    let store = Store(reducer: storeFeature, initialState: .init())
    let work = store.send(.startWork)
    let canceller = store.send(.startCanceller)
    await storeFeature.go.open()
    await work.finish()
    await canceller.finish()
    #expect(store.state.log == ["mark"])

    let feature = CrossDispatchFeature()
    let testStore = TestStore(reducer: feature, initialState: .init())
    testStore.exhaustivity = exhaustive ? .on : .off
    await testStore.send(.startWork)
    await testStore.send(.startCanceller)
    await feature.go.open()
    // The canceller has applied its cancel once both effect trees are idle.
    await waitUntilIdle(testStore)
    if exhaustive {
      await testStore.receive(.mark) { $0.log = ["mark"] }
    }
    await testStore.finish()
    #expect(testStore.state.log == ["mark"])
  }

  @Test(
    "An interpreted follow-up comes after its action's concatenate siblings; a plain one before",
    arguments: SiblingShape.allCases, FollowUpWrap.allCases)
  fileprivate func concatenateSiblingOrder(shape: SiblingShape, wrap: FollowUpWrap) async {
    let feature = SiblingFeature(shape: shape, wrap: wrap)
    let expected = shape.storeLog(wrap)
    #expect(await storeLog(feature, .start, state: .init(), log: \.log) == expected)

    for exhaustive in [true, false] {
      let store = TestStore(reducer: feature, initialState: .init())
      store.exhaustivity = exhaustive ? .on : .off
      await store.send(.start)
      // `.a` and `.b` are both buffered before the test receives `.a`.
      await waitUntilIdle(store)
      if exhaustive {
        var log: [String] = []
        for entry in expected {
          log.append(entry)
          await store.receive(SiblingFeature.Action(entry)) { [log] in $0.log = log }
        }
      }
      await store.finish()
      #expect(store.state.log == expected)
    }
  }

  @Test(
    "Outputs around an action's concatenate siblings are kept as a Store publishes them",
    arguments: SiblingOutputShape.allCases, FollowUpWrap.allCases)
  fileprivate func concatenateSiblingOutputs(shape: SiblingOutputShape, wrap: FollowUpWrap) async {
    let feature = SiblingOutputFeature(shape: shape, wrap: wrap)
    let outputStore = Store(reducer: feature, initialState: .init())
    let captured = outputStore.send(.start, capturingOutputs: .unbounded)
    var published: [SiblingOutputFeature.Output] = []
    for await output in captured.outputs { published.append(output) }
    #expect(published == (shape.publishes(wrap) ? [.o] : []))
    #expect(outputStore.state.log == shape.log)

    for exhaustive in [true, false] {
      let store = TestStore(reducer: feature, initialState: .init())
      store.exhaustivity = exhaustive ? .on : .off
      await store.send(.start)
      await waitUntilIdle(store)
      var log: [String] = []
      for entry in shape.log {
        log.append(entry)
        await store.receive(SiblingOutputFeature.Action(entry)) { [log] in $0.log = log }
      }
      #expect(store.unverifiedSnapshot().outputCount == published.count)
      for output in published {
        await store.receiveOutput(output, timeout: .zero)
      }
      await store.finish()
    }
  }

  @Test(
    "A received action's plain output precedes the outputs its effect publishes later",
    arguments: OutputOrderShape.allCases, [true, false])
  fileprivate func receivedActionOutputOrder(shape: OutputOrderShape, exhaustive: Bool) async {
    let outputStore = Store(reducer: OutputOrderFeature(shape: shape), initialState: .init())
    let captured = outputStore.send(.start, capturingOutputs: .unbounded)
    var published: [OutputOrderFeature.Output] = []
    for await output in captured.outputs { published.append(output) }
    withExtendedLifetime(outputStore) {}
    #expect(published == shape.outputs)

    let store = TestStore(reducer: OutputOrderFeature(shape: shape), initialState: .init())
    store.exhaustivity = exhaustive ? .on : .off
    await store.send(.start)
    // `.a`, then `.p`, are delivered before the test receives `.a`.
    await waitUntilIdle(store)
    await store.receive(.a) { $0.log = ["a"] }
    for output in shape.outputs {
      await store.receiveOutput(output, timeout: .zero)
    }
    await store.finish()
  }

  @Test(
    "An interpreted follow-up precedes what its action's effect delivers in a later job",
    arguments: LaterJobShape.allCases, [true, false])
  fileprivate func interpretedFollowUpPrecedesLaterJob(
    shape: LaterJobShape, exhaustive: Bool
  ) async {
    let feature = LaterJobFeature(shape: shape)
    #expect(await storeLog(feature, .start, state: .init(), log: \.log) == shape.storeLog)

    let store = TestStore(reducer: feature, initialState: .init())
    store.exhaustivity = exhaustive ? .on : .off
    await store.send(.start)
    // Everything the effect delivers is buffered before the test receives `.w`.
    await waitUntilIdle(store)
    if exhaustive {
      var log: [String] = []
      for entry in shape.storeLog {
        log.append(entry)
        await store.receive(LaterJobFeature.Action(entry)) { [log] in $0.log = log }
      }
    }
    await store.finish()
    #expect(store.state.log == shape.storeLog)
  }

  @Test(
    "An interpreted follow-up's output survives a cancel delivered in a later job",
    arguments: [true, false])
  func interpretedOutputSurvivesLaterJobCancel(exhaustive: Bool) async {
    let feature = LaterJobFeature(shape: .runAfterSend, publishes: true)
    let outputStore = Store(reducer: feature, initialState: .init())
    let captured = outputStore.send(.start, capturingOutputs: .unbounded)
    var published: [LaterJobFeature.Output] = []
    for await output in captured.outputs { published.append(output) }
    #expect(published == [.o])
    #expect(outputStore.state.log == ["w", "v"])

    let store = TestStore(reducer: feature, initialState: .init())
    store.exhaustivity = exhaustive ? .on : .off
    await store.send(.start)
    await waitUntilIdle(store)
    await store.receive(.w) { $0.log = ["w"] }
    await store.receive(.v) { $0.log = ["w", "v"] }
    await store.receiveOutput(.o, timeout: .zero)
    await store.finish()
  }

  @Test(
    "A chain of two interpreted follow-ups is received in an order a Store has",
    arguments: [false, true], [true, false])
  func interpretedChainFollowsTheRace(cancelsRun: Bool, exhaustive: Bool) async {
    let shape = ChainShape(first: .wrapped, second: .wrapped, cancelsRun: cancelsRun)
    let feature = ChainFeature(shape: shape)
    // A Store reduces `g1` in a job it queues while it reduces `f1`; the
    // run's next emission races that job and usually reaches the store
    // first. A test store queues the anchor of that job when the anchor of
    // `f1`'s interpreter runs, and follows the race as it happens.
    let usual = ["a1", "f1", "a2", "g1", "f2", "g2"]
    let chainFirst = cancelsRun ? ["a1", "f1", "g1"] : ["a1", "f1", "g1", "a2", "f2", "g2"]
    let orders = [usual, chainFirst]
    let reduced = await storeLog(feature, .start, state: .init(), log: \.log)
    #expect(orders.contains(reduced))

    let store = TestStore(reducer: feature, initialState: .init())
    store.exhaustivity = exhaustive ? .on : .off
    await store.send(.start)
    // Both emissions are buffered before the test receives the first.
    await waitFor(store) { store.unverifiedSnapshot().actionCount == 2 }
    if exhaustive {
      // Receive whichever of the two orders the buffer keeps.
      var log: [String] = []
      while true {
        let candidates = orders.filter { $0.starts(with: log) && $0.count > log.count }
        let next = Set(candidates.map { $0[log.count] })
        guard !next.isEmpty else { break }
        let received = await store.receive(
          where: { next.contains($0.entry) },
          assert: { [log] state, action in state.log = log + [action.entry] }
        )
        guard let received else { break }
        log.append(received.entry)
      }
    }
    await store.finish()
    #expect(orders.contains(store.state.log))
  }

  @Test(
    "A received action's interpreted follow-up comes after a job queued before its delivery",
    arguments: CompetingShape.allCases, ReceiveMode.all)
  fileprivate func interpretedFollowUpAfterQueuedJob(
    shape: CompetingShape, mode: ReceiveMode
  ) async {
    let (late, exhaustive) = (mode.late, mode.exhaustive)
    let feature = CompetingFollowUpFeature(shape: shape)
    let emitter = [AnyEffectID(emitterID)]
    let outputs: [CompetingFollowUpFeature.Output] = shape == .outputs ? [.ox, .op] : []

    let reference = Store(reducer: feature, initialState: .init())
    let published = reference.outputs()
    let referenceEmission = queueEmission(.x, under: emitter, into: reference)
    // Reduces `pong`, whose interpreter job is queued behind the emission job.
    let ping = reference.send(.ping)
    await referenceEmission.value
    await ping.finish()
    #expect(reference.state.log == shape.log)
    var iterator = published.makeAsyncIterator()
    var referenceOutputs: [CompetingFollowUpFeature.Output] = []
    for _ in outputs {
      if let output = await iterator.next() { referenceOutputs.append(output) }
    }
    #expect(referenceOutputs == outputs)

    let store = TestStore(reducer: feature, initialState: .init())
    store.exhaustivity = exhaustive ? .on : .off
    let emission = queueEmission(.x, under: emitter, into: store)
    // `pong` is buffered, and its anchor queued, while the emission job is
    // still queued.
    await store.send(.ping)
    if late {
      await emission.value
      await mainActorBarrier()
    }
    // Eager: `pong` is reduced in the job that sent `ping`.
    var log: [String] = []
    for entry in shape.log {
      log.append(entry)
      await store.receive(CompetingFollowUpFeature.Action(rawValue: entry)!) { [log] in
        $0.log = log
      }
    }
    for output in outputs {
      await store.receiveOutput(output, timeout: .zero)
    }
    await store.finish()
    #expect(store.state.log == shape.log)
  }

  @Test(
    "An interpreted follow-up comes after a job queued behind its action's delivery job",
    arguments: InterveningDelivery.allCases, [true, false])
  fileprivate func interpretedFollowUpAfterLaterQueuedJob(
    delivery: InterveningDelivery, exhaustive: Bool
  ) async {
    let reference = Store(reducer: QueuedEmissionsFeature(), initialState: .init())
    let otherReference = Store(reducer: PingFeature(), initialState: .init())
    let referenceFirst = queueEmission(.x, into: reference)
    switch delivery {
    case .nothing: break
    case .otherStore: otherReference.send(.ping)
    case .sameStore: reference.send(.ping)
    }
    let referenceSecond = queueEmission(.y, into: reference)
    await referenceFirst.value
    await referenceSecond.value
    await settle { reference.state.log.count == delivery.log.count }
    #expect(reference.state.log == delivery.log)

    let store = TestStore(reducer: QueuedEmissionsFeature(), initialState: .init())
    let other = TestStore(reducer: PingFeature(), initialState: .init())
    store.exhaustivity = exhaustive ? .on : .off
    other.exhaustivity = exhaustive ? .on : .off
    queueEmission(.x, into: store)
    switch delivery {
    case .nothing: break
    case .otherStore: await other.send(.ping)
    case .sameStore: await store.send(.ping)
    }
    queueEmission(.y, into: store)
    var log: [String] = []
    for entry in delivery.log {
      log.append(entry)
      await store.receive(QueuedEmissionsFeature.Action(entry)) { [log] in $0.log = log }
    }
    await store.finish()
    #expect(store.state.log == delivery.log)
    if delivery == .otherStore {
      await other.receive(.pong)
    }
    await other.finish()
  }

  @Test(
    "A sent action's interpreted follow-up comes after a job queued before the send",
    arguments: SentFollowUpShape.allCases, [true, false])
  fileprivate func sentFollowUpAfterQueuedJob(shape: SentFollowUpShape, exhaustive: Bool) async {
    let feature = SentFollowUpFeature(shape: shape)
    let reference = Store(reducer: feature, initialState: .init())
    let referenceEmission = queueEmission(.x, into: reference)
    let ping = reference.send(.ping)
    await referenceEmission.value
    await ping.finish()
    #expect(reference.state.log == shape.log)

    let store = TestStore(reducer: feature, initialState: .init())
    store.exhaustivity = exhaustive ? .on : .off
    queueEmission(.x, into: store)
    // A wrapped follow-up is walked where the job a Store queues at the
    // send runs, behind the emission job.
    await store.send(.ping)
    var log: [String] = []
    for entry in shape.log {
      log.append(entry)
      await store.receive(SentFollowUpFeature.Action(entry)) { [log] in $0.log = log }
    }
    await store.finish()
    #expect(store.state.log == shape.log)
  }

  @Test(
    "A scoped send's interpreted follow-up comes after a job queued before the send",
    arguments: SentFollowUpShape.allCases, [true, false])
  fileprivate func scopedSentFollowUpAfterQueuedJob(
    shape: SentFollowUpShape, exhaustive: Bool
  ) async {
    let feature = ScopedSentFollowUpParent(shape: shape)
    let reference = Store(reducer: feature, initialState: .init())
    let referenceEmission = queueEmission(.child(.x), into: reference)
    let ping = reference.send(.child(.ping))
    await referenceEmission.value
    await ping.finish()
    #expect(reference.state.child.log == shape.log)

    let store = TestStore(reducer: feature, initialState: .init())
    store.exhaustivity = exhaustive ? .on : .off
    let child = store.scope(state: \.child, action: ScopedSentFollowUpParent.Action.childPath)
    queueEmission(.child(.x), into: store)
    await child.send(.ping)
    var log: [String] = []
    for entry in shape.log {
      log.append(entry)
      await child.receive(SentFollowUpFeature.Action(entry)) { [log] in $0.log = log }
    }
    await store.finish()
    #expect(store.state.child.log == shape.log)
  }

  @Test(
    "A send reduces the sent action before the interpreted effects of the actions it drains",
    arguments: SendDrainShape.allCases, [false, true])
  fileprivate func sendReducesSentActionBeforeDrainedInterpreters(
    shape: SendDrainShape, viaScope: Bool
  ) async {
    // A `Store` reduces `b` with the first send and creates its interpreter
    // job then; it reduces `c` during the second send, before that job and
    // before the job queued ahead of it.
    let atSend = ["a", "b", "c"]
    let emissionIDs = [AnyEffectID(drainedEmissionID)]
    let reference = Store(reducer: SendDrainParent(shape: shape), initialState: .init())
    let referenceEmission =
      shape == .alone
      ? nil : queueEmissionOfEarlierEffect(.child(.x), under: emissionIDs, into: reference)
    reference.send(.child(.a))
    reference.send(.child(.c))
    #expect(reference.state.child.log == atSend)
    await referenceEmission?.value
    await settle { reference.state.child.log.count == shape.log.count }
    #expect(reference.state.child.log == shape.log)

    let store = TestStore(reducer: SendDrainParent(shape: shape), initialState: .init())
    store.exhaustivity = .off
    let child = store.scope(state: \.child, action: SendDrainParent.Action.childPath)
    if shape != .alone {
      queueEmissionOfEarlierEffect(.child(.x), under: emissionIDs, into: store)
    }
    if viaScope {
      await child.send(.a)
      await child.send(.c)
    } else {
      await store.send(.child(.a))
      await store.send(.child(.c))
    }
    // The second send drained `b` and reduced `c` before it started `b`'s
    // effect where the Store's interpreter job runs.
    #expect(store.state.child.log == atSend)
    var log = atSend
    for entry in shape.log.dropFirst(atSend.count) {
      log.append(entry)
      await store.receive(.child(SendDrainFeature.Action(entry))) { [log] in $0.child.log = log }
    }
    await store.finish()
    #expect(store.state.child.log == shape.log)
  }

  @Test(
    "A sent action's interpreter comes before the follow-ups of the actions its send drains",
    arguments: [true, false])
  func sentInterpreterPrecedesDrainedFollowUps(exhaustive: Bool) async {
    // A `Store` creates `b`'s interpreter job during the first send and
    // `c`'s during the second; `b`'s job creates the one that reduces `b3`
    // behind `c`'s.
    let expected = ["a", "b", "c", "b2", "c2", "b3"]
    let reference = Store(reducer: DeepSendDrainFeature(), initialState: .init())
    reference.send(.a)
    reference.send(.c)
    await settle { reference.state.log.count == expected.count }
    #expect(reference.state.log == expected)

    let store = TestStore(reducer: DeepSendDrainFeature(), initialState: .init())
    store.exhaustivity = .off
    await store.send(.a)
    await store.send(.c)
    store.exhaustivity = exhaustive ? .on : .off
    var log = ["a", "b", "c"]
    for entry in expected.dropFirst(log.count) {
      log.append(entry)
      await store.receive(DeepSendDrainFeature.Action(entry)) { [log] in $0.log = log }
    }
    await store.finish()
    #expect(store.state.log == expected)
  }

  @Test("A send leaves buffered what is delivered while it drains earlier actions")
  func sendLeavesValuesDeliveredDuringItsDrain() async {
    // `r`'s interpreter job already ran when `c` is sent, and `y`'s job was
    // queued before the send: a `Store` reduces `y` after `c`.
    let reference = Store(
      reducer: ThrottledDrainFeature(), initialState: .init(),
      clock: .manual(ManualTestClock()))
    await queueEmission(.r, into: reference).value
    await mainActorBarrier()
    let referenceEmission = queueEmission(.y, into: reference)
    reference.send(.c)
    await referenceEmission.value
    #expect(reference.state.log.firstIndex(of: "c")! < reference.state.log.firstIndex(of: "y")!)

    let clock = ManualTestClock()
    let store = TestStore(reducer: ThrottledDrainFeature(), initialState: .init(), clock: clock)
    store.exhaustivity = .off
    await queueEmission(.r, into: store).value
    await mainActorBarrier()
    queueEmission(.y, into: store)
    // The send drains `r`; its throttle walk reads the manual clock, and `y`
    // is delivered while it waits.
    await store.send(.c)
    #expect(store.state.log == ["r", "c"])
    await store.receive(.y)
    await store.receive(.rl)
    await clock.advance(by: .seconds(1))
    await store.finish()
    #expect(store.state.log == ["r", "c", "y", "rl"])
  }

  @Test(
    "An interpreted follow-up's own follow-up comes after its siblings' follow-ups",
    arguments: [true, false])
  func nestedFollowUpsKeepInterpreterOrder(exhaustive: Bool) async {
    // A Store reduces `a` and `b` in one job and queues their interpreter
    // jobs; the job of `a` reduces `a2` and queues the job that reduces `a3`
    // behind the job of `b`.
    let expected = ["a", "b", "a2", "b2", "a3"]
    #expect(await storeLog(NestedFollowUpFeature(), .start, state: .init(), log: \.log) == expected)

    let store = TestStore(reducer: NestedFollowUpFeature(), initialState: .init())
    store.exhaustivity = exhaustive ? .on : .off
    await store.send(.start)
    var log: [String] = []
    for entry in expected {
      log.append(entry)
      await store.receive(NestedFollowUpFeature.Action(entry)) { [log] in $0.log = log }
    }
    await store.finish()
    #expect(store.state.log == expected)
  }

  @Test(
    "A nested interpreted follow-up comes after an emission queued while its chain ran",
    arguments: [true, false])
  func nestedFollowUpAfterQueuedEmission(exhaustive: Bool) async {
    // The shape of `run { send(a); send(b) }`, with the job of `b` queued once
    // `a` was delivered: a Store runs the interpreter job of `a` first, which
    // queues the one of `a2` behind the job of `b`, and that job queues the
    // interpreter job of `b` behind the one of `a2`.
    let expected = ["a", "a2", "b", "a3", "b2"]
    let reference = Store(reducer: NestedFollowUpFeature(), initialState: .init())
    queueEmission(.a, into: reference) {
      queueEmission(.b, into: reference)
    }
    await settle { reference.state.log.count == expected.count }
    #expect(reference.state.log == expected)

    let store = TestStore(reducer: NestedFollowUpFeature(), initialState: .init())
    store.exhaustivity = exhaustive ? .on : .off
    queueEmission(.a, into: store) {
      queueEmission(.b, into: store)
    }
    var log: [String] = []
    for entry in expected {
      log.append(entry)
      await store.receive(NestedFollowUpFeature.Action(entry)) { [log] in $0.log = log }
    }
    await store.finish()
    #expect(store.state.log == expected)
  }

  @Test("A delivered action left unreceived queues a bounded number of anchor markers")
  func unreceivedActionBoundsAnchorMarkers() async {
    let store = TestStore(reducer: QueuedEmissionsFeature(), initialState: .init())
    store.exhaustivity = .off
    store.deliverAction(.y, context: nil)
    // Every barrier lets the marker queued before it run, and that marker
    // queues the next level while `y` is unreceived.
    for _ in 0..<(TestStoreAnchorChain.depth + 2) {
      await mainActorBarrier()
    }
    #expect(store.queuedAnchorMarkerCount == TestStoreAnchorChain.depth)

    // An action whose walk ends before its first marker runs stops there.
    store.deliverAction(.pong, context: nil)
    await store.receive(.y)
    await store.receive(.pong)
    for _ in 0..<(TestStoreAnchorChain.depth + 2) {
      await mainActorBarrier()
    }
    #expect(store.queuedAnchorMarkerCount == TestStoreAnchorChain.depth + 1)
    await store.finish()
  }
}
