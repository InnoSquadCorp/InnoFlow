import InnoFlowCore

@main struct Consumer {
  static func main() {
    #if NEGATIVE_CAPTURE
      let index = MutableIndex()
    #endif

    #if NEGATIVE_SCOPE
      #if NEGATIVE_ERASED
        let path: PlainStatePath<KeyPathChild> = \.child
      #else
        let path = \KeyPathState.[index].child
      #endif
      _ = Scope(state: path, action: keyPathAction, reducer: keyPathChildReducer())
    #elseif NEGATIVE_IFLET
      #if NEGATIVE_ERASED
        let path: PlainStatePath<KeyPathChild?> = \.optional
      #else
        let path = \KeyPathState.[index].optional
      #endif
      _ = IfLet(state: path, action: keyPathAction, reducer: keyPathChildReducer())
    #elseif NEGATIVE_FOREACH
      #if NEGATIVE_ERASED
        let path: PlainStatePath<[KeyPathChild]> = \.rows
      #else
        let path = \KeyPathState.[index].rows
      #endif
      _ = ForEachReducer(state: path, action: keyPathRowAction, reducer: keyPathChildReducer())
    #elseif NEGATIVE_IDENTIFIED
      #if NEGATIVE_ERASED
        let path: PlainStatePath<IdentifiedArray<Int, KeyPathChild>> = \.identified
      #else
        let path = \KeyPathState.[index].identified
      #endif
      _ = ForEachIdentifiedReducer(
        state: path, action: keyPathRowAction, reducer: keyPathChildReducer())
    #elseif NEGATIVE_OPTIONAL
      #if NEGATIVE_ERASED
        let path: PlainStatePath<KeyPathChild?> = \.optional
      #else
        let path = \KeyPathState.[index].optional
      #endif
      _ = keyPathParentReducer().optionalChild(
        state: path, action: keyPathAction, instanceID: { $0.id }, reducer: keyPathChildReducer())
    #elseif NEGATIVE_PHASE
      #if NEGATIVE_ERASED
        let path: PlainStatePath<Int> = \.phase
      #else
        let path = \KeyPathState.[index].phase
      #endif
      _ = PhaseMap<KeyPathState, KeyPathAction, Int>(path) { From(0) { On(.advance, to: 1) } }
    #else
      #error("Choose one negative API boundary")
    #endif
  }
}
