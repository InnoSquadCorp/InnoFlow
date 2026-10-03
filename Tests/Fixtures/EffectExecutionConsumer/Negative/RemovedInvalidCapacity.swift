import InnoFlowCore
@main struct RemovedInvalidCapacity {
  static func main() {
    let reason: EffectAdmissionRejection = .invalidCapacity(-1)
    print(reason)
  }
}
