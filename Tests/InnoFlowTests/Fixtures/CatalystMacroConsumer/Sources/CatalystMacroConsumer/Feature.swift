import InnoFlow

@InnoFlow
public struct CatalystFeature {
  public struct State: Equatable, Sendable, DefaultInitializable {
    public init() {}
  }

  public enum Action: Equatable, Sendable {
    case emit
  }

  public enum Output: Equatable, Sendable {
    @available(iOS, unavailable)
    @available(macCatalyst 13.0, *)
    case catalystOnly(Int)

    #if targetEnvironment(simulator)
      case targetSpecific(Int)
    #endif
    #if targetEnvironment(macCatalyst)
      case targetSpecific(String)
    #endif
  }

  public init() {}

  public var body: some Reducer<State, Action, Output> {
    Reduce { _, _ in .none }
  }
}

#if targetEnvironment(macCatalyst)
  public let catalystPath = CatalystFeature.Output.catalystOnlyCasePath
  public let targetPath = CatalystFeature.Output.targetSpecificCasePath
#endif

#if INNOFLOW_NEGATIVE_IOS_AVAILABILITY && os(iOS) && !targetEnvironment(macCatalyst)
  public let forbiddenIOSPath = CatalystFeature.Output.catalystOnlyCasePath
#endif
