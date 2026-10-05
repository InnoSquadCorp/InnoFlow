import InnoFlowCore

struct KeyPathChild: Equatable, Identifiable, Sendable {
  var id = 1
  var count = 0
}

struct ImmutableIndex: Hashable, Sendable { let value: Int }

// A stable identity with mutable, non-Sendable storage: a key path may capture
// it for local use, but must not carry it into Sendable lifetime metadata.
final class MutableIndex: Hashable {
  var value = 0
  static func == (lhs: MutableIndex, rhs: MutableIndex) -> Bool { lhs === rhs }
  func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

struct KeyPathState: Sendable {
  var child = KeyPathChild()
  var optional: KeyPathChild? = .init()
  var rows = [KeyPathChild()]
  var identified = IdentifiedArray(uniqueElements: [KeyPathChild()], id: \.id)
  var phase = 0

  subscript(index: ImmutableIndex) -> Self {
    get { self }
    set { self = newValue }
  }
  subscript(index: MutableIndex) -> Self {
    get { self }
    set { self = newValue }
  }
}

enum KeyPathAction: Equatable, Sendable {
  case child(Int)
  case row(Int, Int)
  case advance
}

typealias KeyPathChildReducer = Reduce<KeyPathChild, Int, Never>
typealias PlainStatePath<Value> = WritableKeyPath<KeyPathState, Value>

func keyPathChildReducer() -> KeyPathChildReducer {
  Reduce { state, amount in
    state.count += amount
    return .none
  }
}

func keyPathParentReducer() -> Reduce<KeyPathState, KeyPathAction, Never> {
  Reduce { _, _ in .none }
}

let keyPathAction = CasePath<KeyPathAction, Int>(
  embed: { .child($0) },
  extract: { if case .child(let value) = $0 { value } else { nil } })
let keyPathRowAction = CollectionActionPath<KeyPathAction, Int, Int>(
  embed: { .row($0, $1) },
  extract: { if case .row(let id, let value) = $0 { (id, value) } else { nil } })
