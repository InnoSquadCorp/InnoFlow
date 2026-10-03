import InnoFlowCore

@main
struct DirectFlowScopeInit {
  @MainActor
  static func main() async {
    _ = FlowScope()  // Expected compile failure: use withFlowScope.
  }
}
