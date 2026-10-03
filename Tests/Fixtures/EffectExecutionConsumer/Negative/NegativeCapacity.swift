import InnoFlowCore
@main struct NegativeCapacity {
  static func main() {
    let policy: EffectExecutionPolicy = .serial(maxPending: -1)
    print(policy)
  }
}
