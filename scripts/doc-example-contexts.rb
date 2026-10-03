# frozen_string_literal: true

# Digest-pinned fragments are inserted only at explicit declaration/expression
# boundaries. Missing application types are fixtures; InnoFlow APIs are real
# external products. Sample-specific recipes use the actual candidate sources.
module DocExampleContexts
  SAMPLE_FENCES = %w[
    6dbfbdd6350adb29b8db7d13b0371a064856893d8646106d68c9b5ae057ea241
    6661228456c622277cfbe0af566e73f18cacf06f3d7d21474194051c82d7fd6f
    2d5c19bb7a67bd7b09d94eaa659c60301a081bfdcfcee3e2a1f56d1a926fa0e4
    f335acc6031828a423b8cd79d198f2b03172824a01fa13f340483195ace3f73d
    7cee953eb63a188c659392505d93de7fde7594cbbc6317d7ab77ae5241c08fbd
    bb0c32e1cd20a4428ea162be6e1a55aa15155b5e7af704c875bee6e4e2948bf9
  ].freeze
  EXAMPLES = {
    "SearchTutorial" => [
      ["Sources/InnoFlow/InnoFlow.docc/SearchFeatureTutorial.md", "c1b3adcc39fee5d2158ff9371e4c5d22a30930bb6201f891b0de811a7ad69a88"],
      ["Sources/InnoFlow/InnoFlow.docc/SearchFeatureTutorial.md", "31e684074ea0990c8653675636583aff714a8be0b72a878f8b16ae52d39ff1d6"],
      ["Sources/InnoFlow/InnoFlow.docc/SearchFeatureTutorial.md", "c06d00ef47661c4b40a20fbc3bd719b5b40e1ca7033699c72821dea9f5af8eb5"],
      ["Sources/InnoFlow/InnoFlow.docc/SearchFeatureTutorial.md", "9ffc339ab6a3e292910750cf8ae060363fa4cc15485728411990c7497071dd4b"],
      ["Sources/InnoFlow/InnoFlow.docc/SearchFeatureTutorial.md", "11ff189242790535c10fc7f9d337384fb48e180db5b49905e9f739edd11b9476"],
      ["Sources/InnoFlow/InnoFlow.docc/SearchFeatureTutorial.md", "af57cbba52804257e623d9bb2d1ba28ed253158f8e87bd970c9ac6126c9e9ebc"],
      ["Sources/InnoFlow/InnoFlow.docc/SearchFeatureTutorial.md", "aab46bc173360125c136f3600bdf2cb4b2f18cf3351072df4a606bcdb2fe89e6"],
      ["Sources/InnoFlow/InnoFlow.docc/SearchFeatureTutorial.md", "46b552d7f948b24f7c23cb56a30bfa53462584fd3b2f04b9d16b5915a4daf1a8"],
      ["Sources/InnoFlow/InnoFlow.docc/SearchFeatureTutorial.md", "c2a851f3a2532811846185f528f09fe743e15f21d73009a8ef3c2daaebeac82d"],
    ],
    "SearchTutorialView" => [
      ["Sources/InnoFlow/InnoFlow.docc/SearchFeatureTutorial.md", "c1b3adcc39fee5d2158ff9371e4c5d22a30930bb6201f891b0de811a7ad69a88"],
      ["Sources/InnoFlow/InnoFlow.docc/SearchFeatureTutorial.md", "c5810337b7b818be08769491fb252439a083fd202574e2a425c7e657b754b15d"],
    ],
    "RunLaneSnapshots" => [
      ["docs/RUN_LANE_SNAPSHOTS.md", "398b641760f834b47fc1e76c80d234b561c7976528a4178290db79eb48ef28b6"],
    ],
    "ReadmeComposition" => [
      ["README.md", "d9ce80e2c34c8b2cb09bd6902dd44d8eec1bc9ffb919e19e25419d6dc439862c"],
      ["README.md", "7621e28cbba9006155abace1eab761d5437340381f786cc46f6aaafe8812a86f"],
      ["README.md", "4c66336866f8dc185403711f0f008c981064797cce07ec0dfd61720c0f16064b"],
      ["README.md", "036cdda8739c9810817ec3f061a8856779810494c60d71ec923b5fde1a29e74c"],
      ["README.md", "371f53f2435769b3c8d56a6a68997e61711b18fca51ed9ef84fd29c218bfd571"],
      ["README.md", "a57876f31ca038115d48ac28bd44c84898130c15768c0e01bcc9fd3d393868dc"],
      ["README.md", "f3bce8422992d70f12bb51849eff9e59fae749a5f5de0c3b6f44907418b9e16e"],
    ],
    "ReadmeOutputs" => [
      ["README.md", "8fa94e26266f26cc01a8fd3694030ab13a5aff95bc05109c65fc60c8d61ade17"],
      ["README.md", "cdaf1cf4a09ac6643b8a444a0dfd85c23dbab598bd4530249cfb0c787135419e"],
    ],
    "ReadmeLifetimes" => [
      ["README.md", "22a67257dd1b1b4b8c7ce6320468d928ca91ca1bd8ac651a855dc7e703b4c04f"],
      ["README.md", "dd48d3fee228410a714c1e665953163637be53406a0174fa934c51a7c49a1279"],
      ["README.md", "9e424d842d8c98d8fd348735123d4c1a4332385c84c659c8b63c35fa1583a89c"],
      ["README.md", "f240ee0c39858a97b88112648f62a1c9e15c8b17495a48bcaae6b08456067700"],
      ["README.md", "44d8f2b61c537af524ecd0253e42549051af7e34e7629dcd08e24f0b20c0f559"],
      ["MIGRATION.md", "612d87e6293b78e18a3ae40681cd4fb98b828472c0d79c3477a864f8b56caf78"],
      ["MIGRATION.md", "d7eb8d01c91839a94c02a91640053875917139e81773fe3149c6d9f449dfa080"],
      ["MIGRATION.md", "52e76afe0875d9cb5c67da3712e7e69f1911f87d974ffb16a0ea1ae876fe5ffc"],
      ["docs/adr/ADR-effect-admission-and-flow-lifetime.md", "ff44610feac6207ec1ef7cc3c3940e42bfb8a934c65836f0983166e800789d80"],
    ],
    "ReadmeTesting" => [
      ["README.md", "f5cb012ad387665f2466f3671d0f6a5fd17e74f4d6827d565238b88edc8ca6c8"],
      ["README.md", "48cff019c6cedd08bb14028171b92ab3cc8dd8aab08863304a430c2e47de3835"],
      ["README.md", "55dfec2617229b9f6f07de41a4af7501edcf452d1b19fd9fe88997f919760381"],
      ["README.md", "ac2fa19ba8d17ec736df65ddb509a3d8a97af40216a5e30d7170856d28a72db8"],
      ["README.md", "9505c7e885a4ea55be904df38cf3c36b4754a377c892c11485ec408f924f8b0d"],
    ],
    "ReadmePreview" => [
      ["README.md", "a14d2c9dce587f7877a2a9b58820ffe2f45314e2ae4f35fe1a6a2ff7a5ac2399"],
      ["README.md", "bad2b5cb67df16db6252b825451065a2c0a6d1786ab4cdcef15ad6cffcd09475"],
      ["README.md", "c59889e5cb5259e9155cc6cc5df873955cf168ff82760be5c270fb1f521caee6"],
    ],
    "MigrationOutputs" => [
      ["MIGRATION.md", "8d1023b2a02459493babce279da1fad46387155b977a8d5c6b234dc8f713a4eb"],
      ["MIGRATION.md", "834b8028a79193f8f71c228acb59a2ecfbb00d211b5ee03b07814ab15d96a79b"],
      ["MIGRATION.md", "ed8f62dd418f599ad0618f566ab4d4d55054632b5ca3d1e75571d2cc7244a61c"],
    ],
    "StrictPhaseAttribute" => [
      ["README.md", "74e84070d7dfd0ec5d6d803dd3772ffa8a4d2f31f5401076ae779c125e9b68ff"],
      ["PHASE_DRIVEN_MODELING.md", "97ce1853a20819e7b4c28b4db4b30668d1efe2a0bd933ec4e0437a94b4ce825e"],
    ],
    "AdvancedAuthoring" => [
      ["docs/ADVANCED_AUTHORING.md", "78a726b834ee4d72b722ae7a1dc4d30511a6f376e6e055400b37c5313fac1430"],
      ["docs/ADVANCED_AUTHORING.md", "b881fc9b7ab3d76ad91e66b294ed195d8dffa243a7f51423bf9c2a08beca3152"],
    ],
    "CrossFrameworkCheckout" => [
      ["docs/CROSS_FRAMEWORK.md", "28004898259d26842f862c530f21c9a01f1a29c634effb27bca39ab8b44dea4e"],
    ],
    "CrossFrameworkAuthentication" => [
      ["docs/CROSS_FRAMEWORK.md", "46bcab2e84e8f4f483aee45eed000950b2aa3e98a43784d0615786955b57ade9"],
    ],
    "AsyncSequenceRecipes" => [
      ["Sources/InnoFlow/InnoFlow.docc/AsyncSequenceEffects.md", "3074038a7a7ba80be37db2d521a03d04ef3d84379e7b6cae9e6537803a6f7416"],
      ["Sources/InnoFlow/InnoFlow.docc/AsyncSequenceEffects.md", "7b4b0097001b58ec66ff25d91ddef4f77f9d6ad8d3a33586e0fa13981ed03b02"],
      ["Sources/InnoFlow/InnoFlow.docc/AsyncSequenceEffects.md", "5ba18c868c018c12616365a6ac92d4df53a41d427ddc989fed69cff7f2ef789c"],
      ["docs/adr/ADR-reducer-sendable-policy.md", "5fb717c6aa617d5d972397ec3594ad917d8ba6511f398a967a32176de526f50c"],
    ],
    "CookbookMetrics" => [
      ["docs/INSTRUMENTATION_COOKBOOK.md", "cda3f492b66c83b7a61cdbf58686b99accb00a4962c86aadad22980682061d59"],
      ["docs/INSTRUMENTATION_COOKBOOK.md", "dcba04b7fe94f9d799398359b8cf072cfb98cb65b6643e8d3f6ab97a3bdb4a75"],
      ["docs/INSTRUMENTATION_COOKBOOK.md", "2f2d6725308db760e0023673cb45875c0cc49ceda0a65003c4d59630039501c9"],
      ["docs/INSTRUMENTATION_COOKBOOK.md", "18ab346e44758e2aa0c6e6ae03ee1742efc3f58c6bab899e8e95548bfab09481"],
      ["docs/INSTRUMENTATION_COOKBOOK.md", "751f0e626b39d7b02e7f8a6987107a0dba8a25f1d2aa874aa9ec324fbaa47bcf"],
    ],
    "CookbookPhaseMap" => [
      ["docs/INSTRUMENTATION_COOKBOOK.md", "bde925ae1025b2a784d269d56887258f5424774172f6d3141cf10802aae24336"],
    ],
    "CookbookPhaseValidation" => [
      ["docs/INSTRUMENTATION_COOKBOOK.md", "0f1ad41a02934fd352e6dacc1914f43f3753b2ddcc6c68e3f64fd6fe04542ea5"],
    ],
    "DocCPhaseContracts" => [
      ["Sources/InnoFlow/InnoFlow.docc/PhaseDrivenModeling.md", "37aef6225e84c59299e8d44290b6ae2c47befee5ddf9457bb0681ddf7fc83552"],
      ["Sources/InnoFlow/InnoFlow.docc/PhaseDrivenModeling.md", "3c5f047d4ad85f203f27ebd74d07dfb0098adc5ac0999d66037349f6952cbf5b"],
["Sources/InnoFlow/InnoFlow.docc/PhaseDrivenModeling.md", "f5b895c5ea088ddb6e42ef69c307892348bed28f81a014bd471168eb25fa299b"],
      ["Sources/InnoFlow/InnoFlow.docc/PhaseDrivenModeling.md", "15c90a3a89e8587bab3ac75eed442b07dc5abb4530f334b7d4ef1e4f4d8c3be1"],
    ],
    "DocCTiming" => [
      ["Sources/InnoFlow/InnoFlow.docc/EffectTimingBaseline.md", "1aa75caff7bbe70e8a4117ae1e9a72a35ab509db9e25778630b7a865d0da3c7b"],
    ],
    "DocCWalkthrough" => [
      ["Sources/InnoFlow/InnoFlow.docc/PhaseDrivenWalkthrough.md", "37175ccc4318fe1250ab24743c167322192c63d070a2545787491b841cbb0b7e"],
      ["Sources/InnoFlow/InnoFlow.docc/PhaseDrivenWalkthrough.md", "eb83a030d293395b25ac41f200adef51770e0223878e5269ccf9c2e5d17d2754"],
      ["Sources/InnoFlow/InnoFlow.docc/PhaseDrivenWalkthrough.md", "512f4d6d89ceab420cec9917d0656318054b012a3564e94a4a551a6d79ac38d7"],
      ["Sources/InnoFlow/InnoFlow.docc/PhaseDrivenWalkthrough.md", "0b7cc499bdd446deaa29acdae697a4f531bf3878383c9f568fefbc9714f3dd98"],
      ["Sources/InnoFlow/InnoFlow.docc/PhaseDrivenWalkthrough.md", "c12f89f4e6ba28b29654f0bfdb0ca98fcb113bf607689e9f30d66faed3370989"],
      ["Sources/InnoFlow/InnoFlow.docc/PhaseDrivenWalkthrough.md", "2213269a02551ba3eb47bb4ba8d853093787af5e8400be2a0ed9ab4581467eec"],
      ["Sources/InnoFlow/InnoFlow.docc/PhaseDrivenWalkthrough.md", "f7d7e723a09b4f1ab91a462ae8efa5db40d2860062284837e073959365cc8dfb"],
      ["Sources/InnoFlow/InnoFlow.docc/PhaseDrivenWalkthrough.md", "4730b7fd7f0e4f5532407cb2a52c4478217eca6c4d1e6708f3712c056103c0ad"],
    ],
    "DependencyPatternA" => [
      ["docs/DEPENDENCY_PATTERNS.md", "43853959101f851757ee8f32e986ca452327e3197bb323783cec1d8e423f131f"],
    ],
    "DependencyPatternB" => [
      ["docs/DEPENDENCY_PATTERNS.md", "6db752e9f0e4c5006b034d35aa1ac25fcad8d4849ad0c098c15cd3718e1d0cd3"],
    ],
    "DependencyRealtime" => [
      ["docs/DEPENDENCY_PATTERNS.md", "0094d015ebf62b747b91babf2b712aa9b5bc5b5f5acfceec3439ec03549f0ea0"],
    ],
    "DependencySampleRecipes" => [
      ["docs/DEPENDENCY_PATTERNS.md", "8722d7817045957e8816ee0cec3f6fdac62cafebfe814c71ba9da13c7d6f860e"],
["docs/DEPENDENCY_PATTERNS.md", "13a1384018d4868c40115e45f3e11c95271ca056ed35ab175070d694d2025b09"],
      ["docs/DEPENDENCY_PATTERNS.md", "d734547bbeb9c1ad54f1bea808b1d20ae96fa4fb52b85636567a2fecdc74bc7b"],
      ["docs/DEPENDENCY_PATTERNS.md", "0400c696d0913927da1fa33c223a2d0f152da6de9b9162a4f1c5d2df5561f864"],
      ["docs/DEPENDENCY_PATTERNS.md", "ebf9ae03293a699c19ec8ef518085eb9c5fa91307529ee703317500cfb006716"],
    ],
  }.freeze

  TEST_NAMES = {
    "SearchTutorial" => %w[searchTutorialLevelOne() searchTutorialComposition() searchTutorialPhaseCoverage() searchTutorialDispatchOwnership() searchTutorialExploration()],
    "RunLaneSnapshots" => %w[runLaneSnapshotProvider()],
    "ReadmeComposition" => %w[readmeComposition()],
    "ReadmeOutputs" => %w[readmeOutputBroadcast() readmeOutputCapture()],
    "ReadmeLifetimes" => %w[readmeDispatchLifetime() migrationDispatchLifetime() migrationMethodValue() readmeFlowScope()],
    "ReadmeTesting" => %w[readmeReceiveMatchers() readmeCollectionScope() readmeSelections()],
    "MigrationOutputs" => %w[migrationOutputBroadcast() migrationOutputCapture()],
    "DocCPhaseContracts" => %w[docCGraphContract() docCTotalityContract()],
    "DocCTiming" => %w[docCTimingCapture()],
    "DocCWalkthrough" => %w[docCWalkthroughLoad() docCWalkthroughRow() docCWalkthroughGraph() docCWalkthroughTotality()],
    "DependencySampleRecipes" => %w[authenticationFlowSuccess() dependencyManualClock() dependencyMockBranches()],
  }.freeze

  def self.indent(source, spaces = 2)
    source.lines.map { |line| " " * spaces + line }.join.rstrip
  end

  def self.function(name, source, context: "", suffix: "", throwing: false)
    <<~SWIFT
      @Test @MainActor func #{name}() async#{throwing ? " throws" : ""} {
      #{indent(context)}
      #{indent(source)}
      #{indent(suffix)}
      }
    SWIFT
  end

  def self.feature(name = "Feature", actions: "case load", state: "var count = 0", body: "Reduce { _, _ in .none }")
    <<~SWIFT
      @InnoFlow
      struct #{name} {
        struct State: Equatable, Sendable, DefaultInitializable { #{state} }
        enum Action: Equatable, Sendable { #{actions} }
        var body: some Reducer<State, Action, Never> {
      #{indent(body, 4)}
        }
      }
    SWIFT
  end

  def self.child
    feature("ChildFeature", actions: "case start, finished", body: <<~SWIFT)
      Reduce { _, action in
        switch action {
        case .start: return .send(.finished)
        case .finished: return .none
        }
      }
    SWIFT
  end

  def self.sample(root, filename, feature_only: true)
    path = File.join(root, "Examples/InnoFlowSampleApp/InnoFlowSampleAppPackage/Sources/InnoFlowSampleAppFeature", filename)
    source = File.read(path)
    return source unless feature_only
    # These explicit marker boundaries are part of the sample's current layout.
    boundary = filename == "PhaseDrivenFSMDemo.swift" ?
      "\n@MainActor\nstruct PhaseDrivenFSMDemoView: View {\n" : "\n// MARK: - View\n"
    prefix, view = source.split(boundary, 2)
    abort "[doc-copyable] Missing sample view boundary: #{filename}" unless view
    prefix
  end

  def self.source(root, name, blocks)
    # Complete tutorial declarations/tests are the source of truth; keep the UI
    # target separate so non-UI consumer probes do not silently import SwiftUI.
    return blocks if %w[SearchTutorial SearchTutorialView].include?(name)

    header = "import Foundation\nimport InnoFlow\nimport InnoFlowSwiftUI\nimport SwiftUI\n"
    header += "import InnoFlowTesting\nimport Testing\n" if TEST_NAMES.key?(name)
    content = case name
    when "RunLaneSnapshots"
      feature + function("runLaneSnapshotProvider", blocks.fetch(0),
        context: <<~SWIFT, suffix: <<~SWIFT)
          var store: Store<Feature>? = Store(reducer: Feature())
          weak var weakStore = store
          let provider: @MainActor () -> [EffectRunLaneSnapshot] =
        SWIFT
          #expect(provider().isEmpty)
          store = nil
          #expect(weakStore == nil)
          #expect(provider().isEmpty)
          weakStore = nil
        SWIFT
    when "ReadmeComposition"
      reduce, combine, scope, parent, optional, enum_case, collection = blocks
      path, enum_reducer = enum_case.split("\nIfCaseLet(", 2)
      abort "[doc-copyable] Missing enum composition boundary" unless enum_reducer
      <<~SWIFT
        #{child}
        #{feature("DetailFeature", actions: "case done")}
        @InnoFlow struct TodoRowFeature {
          struct State: Identifiable, Equatable, Sendable { let id: Int; var isDone = false }
          enum Action: Equatable, Sendable { case setIsDone(Bool) }
          var body: some Reducer<State, Action, Never> {
            Reduce { state, action in
              if case .setIsDone(let value) = action { state.isDone = value }
              return .none
            }
          }
        }
        #{parent}
        struct AnalyticsReducer: Reducer {
          typealias State = ParentFeature.State
          typealias Action = ParentFeature.Action
          typealias Output = Never
          func reduce(into state: inout State, action: Action) -> EffectTask<Action> { .none }
        }
        struct ReduceExample {
          typealias State = ParentFeature.State
          typealias Action = ParentFeature.Action
          var body: some Reducer<State, Action, Never> {
        #{indent(reduce, 4)}
          }
        }
        struct CombineExample {
          typealias State = ParentFeature.State
          typealias Action = ParentFeature.Action
        #{indent(combine)}
        }
        @InnoFlow struct ScopeExample {
          struct State: Equatable, Sendable, DefaultInitializable {
            var child = ChildFeature.State(); var isLoading = false
          }
          enum Action: Equatable, Sendable { case load, child(ChildFeature.Action) }
        #{indent(scope)}
        }
        @InnoFlow struct OptionalExample {
          struct State: Equatable, Sendable, DefaultInitializable { var child: ChildFeature.State? = .init() }
          enum Action: Equatable, Sendable { case child(ChildFeature.Action) }
          var body: some Reducer<State, Action, Never> {
        #{indent(optional, 4)}
          }
        }
        @InnoFlow struct EnumExample {
          enum State: Equatable, Sendable { case detail(DetailFeature.State), other }
          enum Action: Equatable, Sendable { case child(DetailFeature.Action) }
        #{indent(path)}
          var body: some Reducer<State, Action, Never> {
            IfCaseLet(#{enum_reducer.rstrip}
          }
        }
        @InnoFlow struct CollectionExample {
          struct State: Equatable, Sendable, DefaultInitializable { var todos: [TodoRowFeature.State] = [] }
          enum Action: Equatable, Sendable { case todo(id: Int, action: TodoRowFeature.Action) }
          var body: some Reducer<State, Action, Never> {
        #{indent(collection, 4)}
          }
        }
        @Test @MainActor func readmeComposition() async {
          let store = Store(reducer: ScopeExample())
          await store.send(.load).finish()
          #expect(!store.state.isLoading)
          var state = CollectionExample.State(todos: [.init(id: 1)])
          _ = CollectionExample().reduce(into: &state, action: .todo(id: 1, action: .setIsDone(true)))
          #expect(state.todos[0].isDone)
        }
      SWIFT
    when "ReadmeOutputs"
      feature_source, usage = blocks.fetch(0).split("\nvar outputs = ", 2)
      abort "[doc-copyable] Missing output usage boundary" unless usage
      feature_source +
        function("readmeOutputBroadcast", "var outputs = " + usage, context: "let store = Store(reducer: DetailFeature())") +
        function("readmeOutputCapture", blocks.fetch(1), context: "let store = Store(reducer: DetailFeature())")
    when "ReadmeLifetimes"
      dispatch, ids, delayed, serial, scope, migration, method, drop, adr = blocks
      feature(actions: "case load, startSearch, search(String), finished, failed(String), loadProfile, loadPermissions, saveAdmission(EffectAdmission), loadAdmission(EffectAdmission)") +
        function("readmeDispatchLifetime", dispatch, context: 'let store = Store(reducer: Feature()); let query = "Ada"') +
        function("migrationDispatchLifetime", migration, context: "let store = Store(reducer: Feature())") +
        function("migrationMethodValue", method, context: "let store = Store(reducer: Feature())", suffix: "send(.load)") +
        function("readmeFlowScope", scope, context: "let store = Store(reducer: Feature())") + <<~SWIFT
          func effectIDs(session: Session) {
          #{indent(ids)}
            _ = refreshID; _ = sessionID
          }
          struct Session: Sendable { var uuid = UUID() }
          typealias Action = Feature.Action
          func delayedEffect() -> EffectTask<Action> {
          #{indent(delayed)}
          }
          func serialEffect() -> EffectTask<Action> {
          #{indent(serial)}
          }
          func dropEffect() -> EffectTask<Action> {
          #{indent(drop)}
          }
          func adrEffect() -> EffectTask<Action> {
            return #{adr}
          }
        SWIFT
    when "ReadmeTesting"
      off, receive, collection, phase, title = blocks
      child_feature = feature("TodoFeature", actions: "case setIsDone(Bool)", state: "var isDone = false", body: <<~SWIFT)
        Reduce { state, action in
          if case .setIsDone(let value) = action { state.isDone = value }
          return .none
        }
      SWIFT
      receive_feature = feature(actions: "case begin, finished, loaded(Int), successful", state: "enum Phase: Equatable, Sendable { case idle, finished }; var phase = Phase.idle; var value = 0", body: <<~SWIFT)
        Reduce { state, action in
          switch action {
          case .begin: return .concatenate(.send(.finished), .send(.loaded(42)), .send(.successful))
          case .finished, .successful: state.phase = .finished; return .none
          case .loaded(let value): state.value = value; return .none
          }
        }
      SWIFT
      receive_feature + child_feature + <<~SWIFT +
        extension Feature.Action {
          var isSuccessfulResponse: Bool { self == .successful }
        }
        @InnoFlow struct ParentFeature {
          struct Todo: Identifiable, Equatable, Sendable { let id: Int; var isDone = false }
          struct Child: Equatable, Sendable { var title = "Child" }
          struct State: Equatable, Sendable, DefaultInitializable {
            var todos: [TodoFeature.State] = []
          }
          enum Action: Equatable, Sendable { case todo(id: Int, action: TodoFeature.Action) }
          var body: some Reducer<State, Action, Never> {
            ForEachReducer(state: \\.todos, action: Action.todoActionPath, reducer: TodoFeature())
          }
        }
        extension TodoFeature.State: Identifiable { var id: Int { 1 } }
        @MainActor func partialExhaustivity(_ store: TestStore<Feature>) {
        #{indent(off)}
        }
      SWIFT
        function("readmeReceiveMatchers", receive,
          context: "let store = TestStore(reducer: Feature()); await store.send(.begin)",
          suffix: "#expect(payload == 42); #expect(action == .successful); await store.finish()") +
        function("readmeCollectionScope", collection,
          context: "let targetID = 1; let store = TestStore(reducer: ParentFeature(), initialState: .init(todos: [.init()]))",
          suffix: "await store.finish()") +
        feature("ProjectionFeature", state: 'enum Phase: Equatable, Sendable { case idle }; var phase = Phase.idle; struct Child: Equatable, Sendable { var title = "Child" }; var child = Child()') +
        function("readmeSelections", phase + title, context: "let store = Store(reducer: ProjectionFeature())")
    when "ReadmePreview"
      feature_source, view, preview = blocks
      # The minimum command-line SDK has no PreviewsMacros plugin. Typecheck
      # the exact preview expression through a ViewBuilder function instead.
      feature_source + view + preview.sub('#Preview("Counter") {',
        "@MainActor @ViewBuilder func readmePreview() -> some View {")
    when "MigrationOutputs"
      no_output, output = blocks.fetch(0).split("\n// Typed app-boundary output\n", 2)
      abort "[doc-copyable] Missing migration variant boundary" unless output
      output_feature, usage = blocks.fetch(1).split("\nvar outputs = ", 2)
      abort "[doc-copyable] Missing migration output usage" unless usage
      <<~SWIFT +
        @InnoFlow struct NoOutputFeature {
          struct State: Equatable, Sendable, DefaultInitializable {}
          enum Action: Equatable, Sendable { case load }
        #{indent(no_output)}
        }
        @InnoFlow struct WithOutputFeature {
          struct State: Equatable, Sendable, DefaultInitializable {}
          enum Action: Equatable, Sendable { case load }
        #{indent(output)}
        }
        #{output_feature}
      SWIFT
        function("migrationOutputBroadcast", "var outputs = " + usage, context: "let store = Store(reducer: Feature())", suffix: "#expect(output == .openDetail(42))") +
        function("migrationOutputCapture", blocks.fetch(2), context: "let store = Store(reducer: Feature())", suffix: "#expect(output == .openDetail(42)); #expect(await outputs.next() == nil)")
    when "StrictPhaseAttribute"
      full, skeleton = blocks
      interior = full.split("struct ProfileFeature {\n", 2).fetch(1).delete_suffix("}\n")
      marker = "  // State.Phase, Action, static phaseMap, and body\n"
      abort "[doc-copyable] Missing strict-phase contextual marker" unless skeleton.include?(marker)
      "struct UserProfile: Equatable, Sendable { static let fixture = Self() }\n" +
        skeleton.sub(marker, interior)
    when "AdvancedAuthoring"
      "protocol APIClient: Sendable {}\nprotocol Logger: Sendable {}\n" + blocks.join("\n")
    when "CrossFrameworkCheckout"
      <<~SWIFT + blocks.fetch(0)
        enum Route: Hashable { case receipt }
        struct ReceiptView: View {
          let route: Route
          var body: some View { Text("Receipt") }
        }
        struct CheckoutView: View {
          let store: Store<CheckoutFeature>
          let onCheckoutFinished: () -> Void
          var body: some View { Button("Checkout", action: onCheckoutFinished) }
        }
      SWIFT
    when "CrossFrameworkAuthentication"
      sample_types = sample(root, "AuthenticationFlowDemo.swift").split("@InnoFlow\nstruct AuthenticationFlowFeature", 2).fetch(0)
      source = blocks.fetch(0)
      insertion = feature("Temporary").split("struct Temporary {\n", 2).fetch(1).delete_suffix("}\n")
      sample_types + "typealias LiveAuthService = SampleAuthService\n" +
        source.sub("struct AuthenticationFeature {\n", "struct AuthenticationFeature {\n" + insertion)
    when "AsyncSequenceRecipes"
      header + <<~SWIFT + blocks.each_with_index.map { |block, i| "func recipe#{i}() -> EffectTask<Action> {\n#{indent(block)}\n}\n" }.join
        struct Event: Equatable, Sendable { let isRelevant: Bool }
        enum Action: Equatable, Sendable { case event(Event), eventReceived(Event) }
        struct Events<Element: Sendable>: AsyncSequence, Sendable {
          let values: [Element]
          struct AsyncIterator: AsyncIteratorProtocol, Sendable {
            var values: [Element]
            mutating func next() async -> Element? {
              values.isEmpty ? nil : values.removeFirst()
            }
          }
          func makeAsyncIterator() -> AsyncIterator { .init(values: values) }
        }
        struct WebSocket: Sendable {
          func messages(context: EffectContext) -> Events<Action> { .init(values: []) }
        }
        struct Notifications: Sendable {
          func events(context: EffectContext) -> Events<Event> { .init(values: []) }
        }
        struct Session: Sendable { let id = UUID() }
        struct Row: Sendable { let id = UUID() }
        let websocket = WebSocket()
        let notifications = Notifications()
        let connectionID = UUID()
        let session = Session()
        let row = Row()
        let makeEvents: @Sendable (EffectContext) -> Events<Event> = { _ in .init(values: []) }
      SWIFT
    when "CookbookMetrics"
      usages = blocks.map { |block| block.lines.reject { |line| line.start_with?("import ") }.join }
      feature + <<~SWIFT + usages.each_with_index.map { |block, i| <<~SWIFT }.join
        import OSLog
        import os
        struct Metrics: Sendable {
          func gauge(_ name: String, value: Int) {}
          func record(_ event: StoreInstrumentationEvent<Feature.Action>) {}
        }
        let metricsBackend = Metrics()
        let metrics = Metrics()
        let logger = Logger(subsystem: "app", category: "innoflow")
        let signposter = OSSignposter(logger: logger)
      SWIFT
        @MainActor func cookbook#{i}() async {
        #{indent(block)}
          #{i < 4 ? "_ = store" : "_ = instrumentation"}
          #{i == 3 ? "_ = snapshot" : ""}
        }
      SWIFT
    when "CookbookPhaseMap"
      source = blocks.fetch(0)
      state_action = <<~SWIFT
          struct State: Equatable, Sendable, DefaultInitializable {
            enum Phase: Hashable, Sendable { case idle }
            var phase = Phase.idle
          }
          enum Action: Equatable, Sendable { case load }
          var body: some Reducer<State, Action, Never> { Reduce { _, _ in .none } }
      SWIFT
      source = source.sub("  // ...\n", state_action)
      source = source.sub("      // ...\n", "      From(.idle) { On(.load, to: .idle) }\n")
      "import OSLog\nstruct Metrics: Sendable { func increment(_ name: String) {} }\nlet metrics = Metrics()\n" + source
    when "CookbookPhaseValidation"
      feature(state: "enum Phase: Hashable, Sendable { case idle }; var phase = Phase.idle") + <<~SWIFT
        import OSLog
        struct Metrics: Sendable { func increment(_ name: String) {} }
        let metrics = Metrics()
        extension Feature {
          static var graph: PhaseTransitionGraph<State.Phase> { [.idle: [.idle]] }
        }
        @MainActor func phaseValidationSetup() {
        #{indent(blocks.fetch(0))}
          _ = reducer
        }
      SWIFT
    when "DocCPhaseContracts"
      full, imports, graph, totality = blocks
      "struct Item: Equatable, Sendable {}\n" + imports + full +
        function("docCGraphContract", graph) +
        function("docCTotalityContract", totality, context: "let items: [Item] = []")
    when "DocCTiming"
      witness = File.read(File.join(root, "Tests/InnoFlowTests/EffectInstrumentationWitness.swift"))
        .sub("@testable import InnoFlowCore", "import InnoFlow")
      probe = File.read(File.join(root, "Tests/InnoFlowTests/EffectTimingBaselineGate.swift"))
        .split("// MARK: - Probe reducer\n", 2).fetch(1)
      body = blocks.fetch(0).sub(/\Aimport InnoFlow\nimport InnoFlowTesting\n\n/, "")
      witness + probe + function("docCTimingCapture", body,
        context: <<~SWIFT, suffix: <<~SWIFT, throwing: true)
          let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
          defer { try? FileManager.default.removeItem(at: outputURL) }
        SWIFT
          #expect(!entries.isEmpty)
          #expect(witness.snapshot().matchedRunPairs == 1)
          #expect(FileManager.default.fileExists(atPath: outputURL.path))
        SWIFT
    when "DocCWalkthrough"
      phase_map, body, collection, binding, load, row, graph, totality = blocks
      full = sample(root, "PhaseDrivenFSMDemo.swift")
      prefix, feature_source = full.split("  static var phaseMap:", 2)
      abort "[doc-copyable] Missing walkthrough feature boundary" unless feature_source
      feature_source = prefix + indent(phase_map) + "\n" + indent(body) + "\n}\n"
      row_view = <<~SWIFT
        @MainActor struct PhaseDrivenTodoRowView: View {
          let store: ScopedStore<PhaseDrivenTodoFeature, SampleTodo, PhaseDrivenTodoRowFeature.Action>
          var body: some View {
        #{indent(binding, 4)}
          }
        }
        @MainActor struct TodoListView: View {
          let store: Store<PhaseDrivenTodoFeature>
          var body: some View {
        #{indent(collection, 4)}
          }
        }
        struct MockTodoService: SampleTodoServiceProtocol {
          static let fixtures = [SampleTodo(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, title: "Fixture")]
          func loadTodos(shouldFail: Bool) async throws -> [SampleTodo] { Self.fixtures }
        }
      SWIFT
      feature_source + row_view +
        function("docCWalkthroughLoad", load,
          context: "let store = TestStore(reducer: PhaseDrivenTodoFeature(todoService: MockTodoService()))",
          suffix: "await store.finish()") +
        function("docCWalkthroughRow", row, context: <<~SWIFT) +
          let targetID = MockTodoService.fixtures[0].id
          let store = TestStore(reducer: PhaseDrivenTodoFeature(todoService: MockTodoService()),
            initialState: .init(phase: .loaded, todos: MockTodoService.fixtures))
        SWIFT
        function("docCWalkthroughGraph", graph) +
        function("docCWalkthroughTotality", totality)
    when "DependencyPatternA"
      full = sample(root, "PhaseDrivenFSMDemo.swift")
      prefix, feature_source = full.split("@InnoFlow(phaseManaged: true, strictPhaseTotality: true)\n", 2)
      state_actions = feature_source.split("  struct State:", 2).fetch(1).split("  let dependencies:", 2).fetch(0)
      source = blocks.fetch(0).sub("struct PhaseDrivenTodoFeature {\n",
        "struct PhaseDrivenTodoFeature {\n  struct State:" + state_actions)
      source = source.sub("      // ...\n", "      case ._loaded(let todos):\n        state.todos = todos\n        return .none\n      default:\n        return .none\n")
      prefix + source
    when "DependencyPatternB"
      full = sample(root, "OfflineFirstDemo.swift")
      prefix, feature_source = full.split("@InnoFlow\nstruct OfflineFirstFeature {\n", 2)
      state_actions = feature_source.split("  struct State:", 2).fetch(1).split("  let dependencies:", 2).fetch(0)
      source = blocks.fetch(0).sub("struct OfflineFirstFeature {\n",
        "struct OfflineFirstFeature {\n  struct State:" + state_actions)
      prefix + source.sub("  // ...\n", "  var body: some Reducer<State, Action, Never> { Reduce { _, _ in .none } }\n")
    when "DependencyRealtime"
      full = sample(root, "RealtimeStreamDemo.swift")
      start, tail = full.split("      case .subscribe:\n", 2)
      _old, rest = tail.split("      case .unsubscribe:\n", 2)
      abort "[doc-copyable] Missing realtime replacement boundaries" unless start && rest
      start + indent(blocks.fetch(0), 6) + "\n\n      case .unsubscribe:\n" + rest
    when "DependencySampleRecipes"
      auth, clock, repository, preview, injected_preview = blocks
      auth_source = sample(root, "AuthenticationFlowDemo.swift")
      realtime = sample(root, "RealtimeStreamDemo.swift")
      offline = sample(root, "OfflineFirstDemo.swift", feature_only: false).split("#if !INNOFLOW_DISABLE_PREVIEWS\n", 2).fetch(0)
      support = File.read(File.join(root, "Examples/InnoFlowSampleApp/InnoFlowSampleAppPackage/Sources/InnoFlowSampleAppFeature/InnoFlowSampleAppRootView.swift"))
        .split("\nstruct DemoCard: View {\n", 2).fetch(1)
      style = File.read(File.join(root, "Examples/InnoFlowSampleApp/InnoFlowSampleAppPackage/Sources/InnoFlowSampleAppFeature/SampleTextFieldStyle.swift"))
      # Preview bodies are separately checked without needing a previews macro
      # plugin in the minimum Swift 6.3 command-line SDK.
      previews = [preview, injected_preview].each_with_index.map do |block, i|
        body = block.lines.drop(1).join.delete_suffix("}\n")
        builder = body.match?(/^\s*return\b/) ? "" : "@ViewBuilder "
        <<~SWIFT
          @MainActor #{builder}func dependencyPreview#{i}() -> some View {
          #{body}
          }
        SWIFT
      end.join
      auth_source + realtime + offline + "\nstruct DemoCard: View {\n" + support + style +
        "typealias PreviewDraftRepository = SampleDraftRepository\n" + auth + repository + previews +
        function("dependencyManualClock", clock, throwing: true) + <<~SWIFT
          @Test @MainActor func dependencyMockBranches() async throws {
            let service = MockAuthService()
            #expect(try await service.submitCredentials(username: "mfa-user", password: "fixture") == .mfaRequired(challengeID: "challenge-mfa-user"))
            #expect(try await service.submitCredentials(username: "user", password: "fixture") == .authenticated(sessionID: "session-fixture"))
            await #expect(throws: AuthServiceError.self) {
              try await service.submitCredentials(username: "user", password: "wrong")
            }
            #expect(try await service.submitMFA(code: "123456") == .authenticated(sessionID: "session-mfa-123456"))
            await #expect(throws: AuthServiceError.self) { try await service.submitMFA(code: "000000") }
            let repository = MockDraftRepository()
            try await repository.save(id: UUID(), title: "fixture")
          }
        SWIFT
    else
      abort "[doc-copyable] Unknown contextual target: #{name}"
    end
    [header, content]
  end
end
