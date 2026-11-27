// MARK: - StoreRootInterpreterLine.swift
// InnoFlow - A Hybrid Architecture Framework for SwiftUI
// Copyright © 2025 InnoSquad. All rights reserved.

/// The line in which a store's root interpreter tasks take their turn.
///
/// A `Store` hands every effect it interprets to a MainActor task it creates
/// while it reduces the action, and walks those effects one at a time, in the
/// order it created the tasks. A task whose turn has come when it runs walks
/// its effect right there. A task that runs earlier — a walk before it
/// suspended and has not finished — leaves its walk in the line, and the
/// interpreter before it starts that walk when it finishes, in a MainActor
/// task it creates in the same MainActor job.
///
/// Creating the task there fixes where a waiting walk starts. MainActor tasks
/// run in the order they are created, so the walk starts behind every job
/// queued before the earlier walk finished and ahead of every job queued
/// after it. A suspended task that is resumed instead — one awaiting the
/// earlier task's value, or a continuation resumed in that job — re-enters
/// the MainActor through the global executor, at a point that depends on how
/// soon that executor hands it back.
///
/// The task that walks a waiting effect is therefore not the one the
/// reduction created: it carries that task's priority, and the task-local
/// values of the interpreter that started it, which the code that sent an
/// earlier action set.
///
/// Turns end in the order they were issued. A turn that has nothing to walk,
/// because its dispatch was cancelled or its store is gone, still waits for
/// the turns before it and takes a MainActor job of its own.
@MainActor
package final class StoreRootInterpreterLine {
  /// One interpreter's walk and the dispatch that owns it.
  package struct Walk {
    /// Walks the effect in the current task, or skips it when the store is
    /// gone or the dispatch was cancelled, and ends the dispatch activity.
    package let run: @MainActor () async -> Void
    /// Makes the dispatch own the task that runs the walk, so cancelling the
    /// dispatch cancels that task.
    package let adopt: @MainActor (Task<Void, Never>) -> Void

    package init(
      run: @escaping @MainActor () async -> Void,
      adopt: @escaping @MainActor (Task<Void, Never>) -> Void
    ) {
      self.run = run
      self.adopt = adopt
    }
  }

  private struct Pending {
    let walk: Walk
    /// The priority of the task created with the walk, once that task has
    /// run ahead of its turn and left the walk here.
    var waitingPriority: TaskPriority?
  }

  private var lastIssuedTurn: UInt64 = 0
  private var lastFinishedTurn: UInt64 = 0
  /// The walks that have not started, by turn.
  private var pending: [UInt64: Pending] = [:]
  /// The task responsible for each unfinished turn: the one created with the
  /// walk, then the one that walks it when that is another task.
  private var tasks: [UInt64: Task<Void, Never>] = [:]

  package init() {}

  /// Adds `walk` at the end of the line and creates its interpreter task.
  package func enqueue(_ walk: Walk) {
    lastIssuedTurn &+= 1
    let turn = lastIssuedTurn
    pending[turn] = Pending(walk: walk)
    // The task body is MainActor-isolated and this method runs on the
    // MainActor without suspending, so the body cannot run before the task is
    // recorded and adopted below.
    let task = Task { @MainActor in
      await self.runCreatedTask(turn: turn)
    }
    tasks[turn] = task
    walk.adopt(task)
  }

  /// The body of the task created with a walk.
  private func runCreatedTask(turn: UInt64) async {
    if let walk = takeWalk(ifTurnHasCome: turn) {
      await walk.run()
      finish(turn)
      return
    }
    // An earlier walk has not finished. The interpreter before this one
    // starts the walk left here when it finishes.
    pending[turn]?.waitingPriority = Task.currentPriority
    // Keep depending on the tasks of the turn before this one until that
    // turn ends, as a task awaiting its predecessor did: the runtime can
    // raise them to this task's priority. Nothing else happens here. That
    // turn has at most two tasks, the one created with its walk and the one
    // that walks it, and each is awaited once.
    var awaited: Task<Void, Never>?
    while lastFinishedTurn &+ 1 < turn, let earlier = tasks[turn &- 1], earlier != awaited {
      awaited = earlier
      await earlier.value
    }
  }

  private func takeWalk(ifTurnHasCome turn: UInt64) -> Walk? {
    guard lastFinishedTurn &+ 1 == turn else { return nil }
    return pending.removeValue(forKey: turn)?.walk
  }

  /// Ends `turn` and starts the walk waiting behind it in a MainActor task
  /// created here, at the end of the job in which `turn`'s walk finished.
  /// The walk runs where that task is queued: behind every job queued
  /// before, ahead of every job queued after.
  private func finish(_ turn: UInt64) {
    lastFinishedTurn = turn
    tasks[turn] = nil
    let next = turn &+ 1
    guard let waiting = pending[next], let priority = waiting.waitingPriority else { return }
    pending[next] = nil
    let task = Task(priority: priority) { @MainActor in
      await waiting.walk.run()
      self.finish(next)
    }
    tasks[next] = task
    waiting.walk.adopt(task)
  }
}
