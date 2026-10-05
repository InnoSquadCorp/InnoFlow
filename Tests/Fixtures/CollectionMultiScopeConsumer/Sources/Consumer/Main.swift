import Foundation
import InnoFlowCore

struct GroupChild: Equatable, Sendable { var generation: Int }
struct GroupRow: Equatable, Identifiable, Sendable {
  let id: Int
  var child: GroupChild?
}
struct GroupState: Equatable, Sendable { var rows: [GroupRow] }
struct GroupsState: Equatable, Sendable {
  var groups: [GroupState]
  var ticks = 0
}
enum GroupAction: Sendable {
  case install
  case row(Int, Void)
}
enum GroupsAction: Sendable {
  case install, tick
  case group(Int, GroupAction)
}

func groupReducer() -> Reduce<GroupState, GroupAction, Never> {
  let row = Reduce<GroupRow, Void, Never> { _, _ in .none }.optionalChild(
    state: \.child, action: CasePath<Void, Void>(embed: { $0 }, extract: { $0 }),
    instanceID: { $0.generation }, reducer: Reduce<GroupChild, Void, Never> { _, _ in .none })
  let route = ForEachReducer(
    state: \GroupState.rows,
    action: CollectionActionPath<GroupAction, Int, Void>(
      embed: { .row($0, $1) },
      extract: { if case .row(let id, let value) = $0 { (id, value) } else { nil } }),
    reducer: row)
  return Reduce { state, action in
    if case .install = action {
      let ids = state.rows.map(\.id)
      return .merge(ids.map { route.reduce(into: &state, action: .row($0, ())) })
    }
    return route.reduce(into: &state, action: action)
  }
}

func groupsReducer(groupCount: Int) -> Reduce<GroupsState, GroupsAction, Never> {
  let scopes = (0..<groupCount).map { group in
    Scope(
      state: \GroupsState.groups[group],
      action: CasePath<GroupsAction, GroupAction>(
        embed: { .group(group, $0) },
        extract: {
          if case .group(let index, let value) = $0, index == group { value } else { nil }
        }),
      reducer: groupReducer())
  }
  return Reduce { state, action in
    switch action {
    case .install:
      return .merge(
        scopes.enumerated().map { index, scope in
          scope.reduce(into: &state, action: .group(index, .install))
        })
    case .tick:
      state.ticks += 1
      return .none
    case .group(let index, _):
      return scopes[index].reduce(into: &state, action: action)
    }
  }
}

// Public-API workload prepared for a later source-frozen timing harness. It has
// no clock calls, metadata hooks, privileged imports or internal owner APIs.
// Construction/installation and result checking can stay outside its measured
// loop. Direct indexed Scope avoids an outer ForEach linear scan confound.
@MainActor func makeGroupsStore(groupCount: Int, rowsPerGroup: Int = 2)
  -> Store<Reduce<GroupsState, GroupsAction, Never>>
{
  let initial = GroupsState(
    groups: (0..<groupCount).map { group in
      GroupState(
        rows: (0..<rowsPerGroup).map { row in
          GroupRow(id: row, child: .init(generation: group * rowsPerGroup + row))
        })
    })
  let store = Store(reducer: groupsReducer(groupCount: groupCount), initialState: initial)
  precondition(store.send(.install).isFinished)
  return store
}

@MainActor func tickGroups(
  _ store: Store<Reduce<GroupsState, GroupsAction, Never>>, iterations: Int
) {
  for _ in 0..<iterations { precondition(store.send(.tick).isFinished) }
}

@main struct MultiScopeConsumer {
  @MainActor static func main() throws {
    var results: [[String: Int]] = []
    for rowsPerGroup in [1, 2] {
      for groupCount in [1, 8, 32, 128] {
        let store = makeGroupsStore(groupCount: groupCount, rowsPerGroup: rowsPerGroup)
        tickGroups(store, iterations: 1)
        precondition(store.state.ticks == 1)
        precondition(store.state.groups.count == groupCount)
        precondition(
          store.state.groups.enumerated().allSatisfy { group, value in
            value.rows.enumerated().allSatisfy { row, value in
              value.child?.generation == group * rowsPerGroup + row
            }
          })
        let result = [
          "groups": groupCount, "rows_per_group": rowsPerGroup, "ticks": store.state.ticks,
        ]
        results.append(result)
      }
    }
    print(
      String(
        decoding: try JSONSerialization.data(
          withJSONObject: results, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
  }
}
