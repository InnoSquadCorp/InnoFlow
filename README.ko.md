# InnoFlow

[![Release](https://img.shields.io/github/v/release/InnoSquadCorp/InnoFlow)](https://github.com/InnoSquadCorp/InnoFlow/releases) [![License](https://img.shields.io/github/license/InnoSquadCorp/InnoFlow)](LICENSE) [Swift Package Index](https://swiftpackageindex.com/InnoSquadCorp/InnoFlow) · [CI and public operations](docs/automation-policy.md)

[English](README.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Deutsch](README.de.md) | [简体中文](README.zh-Hans.md) | [日本語](README.ja.md) | [Русский](README.ru.md)

SwiftUI를 중심으로 비즈니스·도메인 상태 전이를 다루는 단방향 상태 관리 프레임워크입니다. 리듀서, Store, 결정적인 테스트로 시작하고 기능에 필요할 때 오케스트레이션을 추가하세요.

## InnoFlow 6.0.2

이 README는 **2026-10-08**에 `1176de1e4783b638c03a9334f43cc49378957148`에서 배포된 **6.0.2 API**를 설명합니다. [버전별 소스](https://github.com/InnoSquadCorp/InnoFlow/tree/6.0.2) · [릴리스 노트](RELEASE_NOTES.md) · [마이그레이션](MIGRATION.md).

개발 브랜치에는 이후 CI, 테스트 구성, 검증 도구, 문서 변경이 있습니다. 이번 갱신 시점의 `Sources/`는 6.0.2와 같으며 이후 도구 변경은 미배포 상태입니다. 개발 브랜치의 `STABLE_VERSION`은 6.0.2이고 불변 태그는 당시 후보 메타데이터를 보존합니다. 호스팅 DocC는 배포된 리비전을 따르므로 설치 버전 확인에는 태그 소스를 쓰세요. 일곱 README는 같은 입문 내용을 다루며 상세 가이드는 영어입니다.

## 설치

Swift **6.3+**, Swift **6 언어 모드**가 필요합니다. 지원 하한은 iOS **18+**, macOS **15+**, tvOS **18+**, watchOS **11+**, visionOS **2+**입니다. SwiftSyntax 범위는 `>=603.0.0, <605.0.0`이며 저장소 잠금 파일은 604.0.0을 사용합니다. 대상에 맞는 Xcode/SDK를 선택하세요. 선언된 배포 하한이 모든 구형 런타임의 실행 검증을 뜻하지는 않습니다.

패키지를 추가한 뒤 제품을 명시적으로 선택하세요. `from:`은 이후 호환 버전을 허용하므로 실제 `Package.resolved`를 확인해야 합니다. 이 릴리스를 재현할 때는 `exact: "6.0.2"`를 사용하세요.

```swift
dependencies: [
  .package(url: "https://github.com/InnoSquadCorp/InnoFlow.git", from: "6.0.2")
]
```

```swift
.target(
  name: "YourDomain",
  dependencies: [.product(name: "InnoFlowCore", package: "InnoFlow")]
),
.target(
  name: "YourSwiftUIApp",
  dependencies: [
    .product(name: "InnoFlow", package: "InnoFlow"),
    .product(name: "InnoFlowSwiftUI", package: "InnoFlow")
  ]
),
.testTarget(
  name: "YourAppTests",
  dependencies: [
    .product(name: "InnoFlowCore", package: "InnoFlow"),
    .product(name: "InnoFlowTesting", package: "InnoFlow")
  ]
)
```

| 제품 | 용도 |
| --- | --- |
| `InnoFlowCore` | 플러그인이 없는 런타임과 의도적인 복구 경로. SwiftUI 의존성이 없습니다. |
| `InnoFlow` | 매크로 작성 파사드이며 Core를 재노출합니다. `@InnoFlow`에는 직접 import가 필요합니다. |
| `InnoFlowSwiftUI` | 선택적 바인딩·미리보기·프레젠테이션·뷰 소유 작업 도우미. Core를 재노출합니다. |
| `InnoFlowInspector` | 선택적 진단 UI이며 Core에만 의존합니다. DEBUG에서 사용하는 구성을 권장합니다. |
| `InnoFlowTesting` | 테스트 전용 하네스와 수동 시계. Core를 재노출하며 배포 타깃에는 넣지 마세요. |


## 카운터 기능

매크로 사용자는 중첩 `State`, `Action`, `body`를 선언합니다. 세 번째 리듀서 제네릭은 출력이 없으면 `Never`, 있으면 타입이 지정된 `Output`입니다. `Reduce`, `CombineReducers`, `Scope`, `IfLet`, `IfCaseLet`, `ForEachReducer`, `ForEachIdentifiedReducer`로 조합하세요. 매크로가 `reduce`를 생성하므로 일반 공개 기능에서는 직접 구현하지 않습니다.

레이블 없는 단일 자식 payload는 `<caseName>CasePath`, 컬렉션 `id:action:`은 `CollectionActionPath`를 생성합니다. 지원되지 않는 레이블·다중 Action payload는 `Action` 내부에 표준 정적 경로를 선언하세요. 경로가 필요 없거나 extension에 있을 때는 `@InnoFlowCasePathIgnored`를 사용합니다.

```swift
import InnoFlow

@InnoFlow
struct CounterFeature {
  struct State: Equatable, Sendable, DefaultInitializable {
    var count = 0
    @BindableField var step = 1
  }

  enum Action: Equatable, Sendable {
    case increment
    case decrement
    case setStep(Int)
  }

  var body: some Reducer<State, Action, Never> {
    Reduce { state, action in
      switch action {
      case .increment:
        state.count += state.step
        return .none

      case .decrement:
        state.count -= state.step
        return .none

      case .setStep(let step):
        state.step = max(1, step)
        return .none
      }
    }
  }
}
```

두 선언을 앱 타깃에 넣으세요. `@BindableField`와 `store.binding(\.$step, to:)`가 권장 표기입니다. `send:`와 후행 클로저 바인딩도 deprecated 없이 지원합니다. `BindableProperty`는 저수준 저장 타입입니다. `@Environment`는 뷰에서 해석하고 의존성은 기능에 주입하세요.

```swift
import InnoFlow
import InnoFlowSwiftUI
import SwiftUI

struct CounterView: View {
  @State private var store: Store<CounterFeature>

  init(store: Store<CounterFeature> = Store(reducer: CounterFeature())) {
    _store = State(initialValue: store)
  }

  var body: some View {
    VStack(spacing: 20) {
      Text("Count: \(store.count)")
        .font(.largeTitle)

      HStack(spacing: 24) {
        Button("−") { store.send(.decrement) }
        Button("+") { store.send(.increment) }
      }

      Stepper(
        "Step: \(store.step)",
        value: store.binding(\.$step, to: CounterFeature.Action.setStep)
      )
    }
  }
}
```

## 테스트

`TestStore.exhaustivity`의 기본값은 `.on`입니다. 모든 상태 변경을 단언하고 모든 effect 액션과 타입이 지정된 출력을 수신한 뒤 `await store.finish()`를 호출하세요. 단언 클로저를 생략하면 상태가 바뀌지 않는다는 뜻입니다. `.off`는 의도적으로 부분 검증할 때만 쓰며 런타임 effect 오류는 여전히 실패합니다. `assertNoBufferedActions()`는 중간 큐 검사이고 `assertNoMoreActions()`는 6.0에서 제거됐습니다.

아래 카운터와 테스트는 실행 가능한 문서 하네스에 연결되어 있으며 설치 조각은 manifest로 조립해 파싱합니다. 번역은 동일한 코드를 공유합니다. [상세 가이드](docs/USER_GUIDE.md)는 문맥이 필요한 예제와 완전한 코드를 구분하고 [코드 블록 원장](docs/contracts/doc-swift-fence-review.tsv)은 검사 연결을 기록합니다. 통과 결과가 기기 UI 동작까지 증명하지는 않습니다.

Effect 액션은 `receive(...)`, 출력은 `receiveOutput(...)`으로 수신하세요.

위 manifest는 제품 선택을 보여줍니다. 이 카운터를 앱 테스트에서 검증하려면 테스트 의존성에 앱 타깃도 추가하고 `@testable import YourSwiftUIApp`으로 `CounterFeature`를 가져오세요. 문서 하네스는 기능과 테스트를 하나의 테스트 타깃에서 함께 컴파일합니다.

```swift
import InnoFlowTesting
import Testing

@Test
@MainActor
func readmeCounter() async {
  let store = TestStore(reducer: CounterFeature())
  await store.send(.setStep(2)) { $0.step = 2 }
  await store.send(.increment) { $0.count = 2 }
  await store.send(.decrement) { $0.count = 0 }
  await store.finish()
}
```

## 단계별 기능 도입

- **Level 1:** `Reduce`, `Store`, `@BindableField`, `TestStore`. 카운터나 폼에는 phase graph나 run lane이 필요하지 않습니다.
- **Level 2:** 자식 조합, 식별 컬렉션, `SelectedStore`, 타입이 지정된 일회성 `Output`. `mapOutput(_:)`으로 명시적으로 변환하고 `promoteOutput(to:)`는 `Never`에만 쓰세요. `outputs()`는 실시간이며 재생하지 않으므로 dispatch 전에 구독하세요. 원자적 단일 소비자 캡처에는 명시적 버퍼 정책으로 `send(_:capturingOutputs:)`를 사용합니다.
- **Level 3:** `FlowTask`, `withFlowScope`, 선택적 자식 수명, 실행 승인, `PhaseMap`, 진단과 Inspector. `.latest`, `.dropWhileRunning`, 제한된 `.serial(maxPending:)`는 Store 내부 승인을 관리합니다. 거부를 처리하세요. 직렬 실행은 트랜잭션·재시도·롤백·정확히 한 번 실행을 보장하지 않습니다.

선택은 한 조각에 `select(dependingOn:)`, 여러 조각에 `select(dependingOnAll:)`, 일반 클로저에는 always-refresh fallback을 사용합니다. `select(memoize: true)`는 Equatable 부모 전체 스냅샷이 같을 때만 갱신을 건너뛰며 세부 의존성을 추론하지 않습니다. 살아 있는 클로저 투영을 재사용할 semantic `id`에는 캡처 입력을 포함하세요. 만료된 투영은 `optionalState` / `optionalValue`, 엄격한 전제조건은 `requireAlive()`로 읽습니다.

`@InnoFlow(phaseManaged: true)`는 리듀싱 뒤 `PhaseMap`을 적용하고 phase 키 경로를 소유합니다. 기본적으로 일치하지 않는 phase/액션은 허용된 무동작입니다. `strictPhaseTotality: true`는 직접 선언된 phase를 확인하고 `requireComplete(...)`는 지정한 샘플 트리거를 검증합니다. 임의 술어나 payload 영역 전체를 증명하지는 않습니다. `PhaseTransitionGraph`는 토폴로지만 검증하며 내비게이션·전송을 소유하지 않습니다.

## 소유권과 수명

리듀서는 도메인 상태를 소유합니다. 앱·코디네이터는 실제 내비게이션 스택, 전송·세션 수명, 의존성 그래프 구성을 소유합니다. Sendable 의존성 번들을 명시적으로 주입하세요. Flow는 DI 컨테이너·네트워크 클라이언트·라우터를 제공하지 않습니다. [의존성 패턴](docs/DEPENDENCY_PATTERNS.md)과 [프레임워크 간 경계](docs/CROSS_FRAMEWORK.md)를 참고하세요.

`Store.send(_:)`는 해당 dispatch와 후손의 `FlowTask`를 반환합니다. `finish()`는 완료를 기다리고 `cancel()`은 그 트리만 취소하며 이미 반영된 상태를 되돌리지 않습니다. 핸들을 버리는 것은 취소가 아닙니다. `withFlowScope`는 추적한 dispatch만 소유합니다. Effect 취소는 협력적이므로 `EffectContext`와 주입한 시계를 쓰세요. `ManualTestClock`은 결정적인 시간 테스트를 지원합니다.

SwiftUI 도우미는 sheet, navigation destination, alert, confirmation dialog, 지원되는 플랫폼의 popover를 다룹니다. full-screen cover는 macOS에서 사용할 수 없습니다. `innoFlowTask`는 뷰의 사라짐·ID 변경에 dispatch 수명을 연결합니다. Inspector와 `StoreDiagnostics`는 선택적이며 크기가 제한되고 payload를 담지 않습니다. 진단 레이블에 도메인 payload를 추가하지 마세요. 렌더링·내비게이션·공간 창과 immersive 오케스트레이션은 앱 책임입니다.

## 공식 샘플

[공식 샘플](Examples/InnoFlowSampleApp/README.md)은 열 가지 데모를 제공하고 로컬 경로로 현재 checkout을 사용합니다. 대화형 앱 셸은 iOS 우선이며 다른 플랫폼 빌드가 immersive 샘플이나 UI 완전 동등성을 뜻하지는 않습니다. [설정](Examples/SETUP_GUIDE.md).

시스템 컨트롤, Dynamic Type, VoiceOver 레이블, 안정적인 `accessibilityIdentifier`를 사용하세요. 스모크 테스트는 다음 식별자를 다루며 전체 접근성 감사는 아닙니다.

`sample.basics`, `sample.orchestration`, `sample.phase-driven-fsm`, `sample.router-composition`, `sample.authentication-flow`, `sample.list-detail-pagination`, `sample.offline-first`, `sample.realtime-stream`, `sample.form-validation`, `sample.bidirectional-websocket`.

## 문서와 Flow 선택

- [상세 사용자 가이드](docs/USER_GUIDE.md), [문서 색인과 버전 경계](docs/DOCUMENTATION.md)
- [시작하기와 API](https://innosquadcorp.github.io/InnoFlow/documentation/innoflow/), [테스트 API](https://innosquadcorp.github.io/InnoFlow/testing/documentation/innoflowtesting/)
- [Phase 모델링](PHASE_DRIVEN_MODELING.md), [SwiftUI 플랫폼 제약](docs/SWIFTUI_DX_6_0.md), [계측](docs/INSTRUMENTATION_COOKBOOK.md)
- [아키텍처 계약](ARCHITECTURE_CONTRACT.md), [마이그레이션](MIGRATION.md), [매크로 신뢰와 복구](docs/MACRO_OPERATIONS.md)
- [AI skill](skills/README.md): 정확한 6.0.2 소비자 기준입니다. SwiftPM 설치와 AI skill 설치는 별개입니다.

작은 도메인 상태 경계와 생성자 의존성 주입이 앱에 맞을 때 Flow를 선택하세요. TCA는 더 넓은 통합 앱 아키텍처와 생태계를 제공합니다. [프레임워크 비교](docs/FRAMEWORK_COMPARISON.md)는 포지셔닝이며 보편적 성능 우위를 주장하지 않습니다.

## 개발과 검증

격리된 checkout과 Swift 6.3+를 사용하고 [기여 안내](CONTRIBUTING.md)와 [저장소 규칙](CLAUDE.md)을 읽으세요. 로컬 정적 검사·집중 테스트·소비자 fixture는 허용됩니다. 네 가지 OS 27 런타임을 포함한 전체 **28개 필수** 릴리스 프리플라이트는 CI에서만 실행합니다. 구형 iOS 18.5 / tvOS 18.5 / watchOS 11.5 / visionOS 2.5 런타임 검사는 선택적이며 자동 실행하지 않습니다. 사용할 수 없었던 증거는 PASS가 아니며 배포 하한은 그대로입니다. [릴리스 절차](RELEASING.md).

Swift 6.3의 Store/TestStore 소멸자에는 release 모드 컴파일러 우회가 있습니다. [툴체인 추적](docs/SWIFT_TOOLCHAIN_TRACKING.md)을 참고하세요. 로컬 통과는 릴리스 인증이나 모든 플랫폼 검증이 아닙니다.

```bash
./scripts/principle-gates.sh --static
./scripts/check-doc-copyable-examples.rb
python3 skills/innoflow/scripts/validate_consumer.py --scratch-path /tmp/innoflow-skill-validation
```

## 지원

[지원](SUPPORT.md) · [기여](CONTRIBUTING.md) · [거버넌스](GOVERNANCE.md) · [행동 강령](CODE_OF_CONDUCT.md) · [보안](SECURITY.md) · [MIT 라이선스](LICENSE).

[GitHub Sponsors](https://github.com/sponsors/InnoSquadCorp) 또는 [Patreon](https://www.patreon.com/15188938/join)으로 개발을 후원할 수 있습니다.
