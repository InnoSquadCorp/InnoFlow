import InnoFlowCore

@main struct PreviousAdmissionSwitch {
  static func main() { print(describe(.started)) }
  static func describe(_ admission: EffectAdmission) -> String {
    switch admission {
    case .started: "started"
    case .queued: "queued"
    case .rejected: "rejected"
    }
  }
}
