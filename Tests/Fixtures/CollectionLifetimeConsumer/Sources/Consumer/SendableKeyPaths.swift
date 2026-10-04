import InnoFlowCore

private func exerciseKeyPaths(
  child: any WritableKeyPath<KeyPathState, KeyPathChild> & Sendable,
  optional: any WritableKeyPath<KeyPathState, KeyPathChild?> & Sendable,
  rows: any WritableKeyPath<KeyPathState, [KeyPathChild]> & Sendable,
  identified: any WritableKeyPath<KeyPathState, IdentifiedArray<Int, KeyPathChild>> & Sendable,
  phase: any WritableKeyPath<KeyPathState, Int> & Sendable
) {
  var state = KeyPathState()
  _ = Scope(state: child, action: keyPathAction, reducer: keyPathChildReducer())
    .reduce(into: &state, action: .child(1))
  precondition(state.child.count == 1)
  _ = IfLet(state: optional, action: keyPathAction, reducer: keyPathChildReducer())
    .reduce(into: &state, action: .child(2))
  precondition(state.optional?.count == 2)
  _ = ForEachReducer(state: rows, action: keyPathRowAction, reducer: keyPathChildReducer())
    .reduce(into: &state, action: .row(1, 3))
  precondition(state.rows[0].count == 3)
  _ = ForEachIdentifiedReducer(
    state: identified, action: keyPathRowAction, reducer: keyPathChildReducer()
  ).reduce(into: &state, action: .row(1, 4))
  precondition(state.identified[id: 1]?.count == 4)
  _ = keyPathParentReducer().optionalChild(
    state: optional, action: keyPathAction, instanceID: { $0.id }, child: keyPathChildReducer()
  ).reduce(into: &state, action: .child(5))
  precondition(state.optional?.count == 7)
  _ = OptionalChildLifetime(
    parent: keyPathParentReducer(), state: optional, action: keyPathAction,
    instanceID: { $0.id }, child: keyPathChildReducer()
  ).reduce(into: &state, action: .child(1))
  precondition(state.optional?.count == 8)
  let map = PhaseMap<KeyPathState, KeyPathAction, Int>(phase) {
    From(0) { On(.advance, to: 1) }
  }
  _ = keyPathParentReducer().phaseMap(map).reduce(into: &state, action: .advance)
  precondition(state.phase == 1)
}

func verifySendableCompositionKeyPaths() {
  // The ordinary literal spelling keeps inferred Sendable without annotations.
  exerciseKeyPaths(
    child: \.child, optional: \.optional, rows: \.rows, identified: \.identified, phase: \.phase)

  // A typed reusable path must preserve the marker explicitly, including aliases.
  let child: any PlainStatePath<KeyPathChild> & Sendable = \.child
  let optional: any PlainStatePath<KeyPathChild?> & Sendable = \.optional
  let rows: any PlainStatePath<[KeyPathChild]> & Sendable = \.rows
  let identified: any PlainStatePath<IdentifiedArray<Int, KeyPathChild>> & Sendable = \.identified
  let phase: any PlainStatePath<Int> & Sendable = \.phase
  exerciseKeyPaths(
    child: child, optional: optional, rows: rows, identified: identified, phase: phase)

  // Subscripts are supported when every captured index is Sendable.
  let index = ImmutableIndex(value: 0)
  exerciseKeyPaths(
    child: \KeyPathState.[index].child, optional: \KeyPathState.[index].optional,
    rows: \KeyPathState.[index].rows, identified: \KeyPathState.[index].identified,
    phase: \KeyPathState.[index].phase)
  print("Literal, explicitly hoisted, and Sendable-index composition key paths passed")
}
