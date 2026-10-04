# Mutation 이후 비어 있는 projection registry 경계

> **2026-10-04 기능 통합 상태:** 이 문서는 보존된 성능 trial의 역사적
> 소스·가설·검증 기록이다. S/I2/D2 최적화는 채택하지 않았으며 기능 후보의
> 전체 `Sources/`는 e15dfac8e0c97edb4706ac35595f22fc2cff5c1d와 동일하다.
> 후속 A-only 3,312개 수집은 완료됐고 69개 비교 중 3개 동등·66개 미입증이다.
> 이 결과는 후보 성능 채택 증거가 아니며 자동 표본 확대를 허용하지 않는다.
> 아래의 “현재 후보”, 미실행 상태와 예정 단계는 각 기록 시점에 해당한다.
> 최신 통합 경계는 [기능·CI 통합 기록](../reviews/FUNCTIONAL-CI-INTEGRATION-2026-10-04.md)을 따른다.

현재 후보는 **reducer 이후 현재 State의 불필요한 값 전달용 copy/destroy와 registry refresh 진입**만 줄이는 가설이다. reducer 이전 snapshot은 모든 action에서 e15와 동일하게 유지한다. 일반 no-observer State의 pre-mutation COW 제거 및 큰 배열 5% 개선 목표를 해결했다고 주장하지 않는다. 새 timing은 실행하지 않았다.

## 기준과 이전 후보 보존

- Source 기준: e15dfac8e0c97edb4706ac35595f22fc2cff5c1d
- 분리 계획: d6b3c6de6c54d9529da373c1f9ada7e787ecc424
- 이전 후보 329c9e279de2c8df74d177c6816139d8c33103ec는 공개 late-registration 회귀 때문에 미채택이다. 기존 worktree, patch/bundle, Library 복구본과 진단 증거를 보존한다
- 새 worktree: `snapshot-refresh-e15`, 증거: `evidence/snapshot-refresh-20261004/`
- e15 대비 제품 diff는 Store.swift 및 ProjectionObserverRegistry.swift 두 파일, +21/-2줄이다. 다른 109개 추적 Sources는 기준과 동일하다

## 확정된 회귀

이전 후보는 state getter를 읽은 적이 없고 registry가 비었으면 reducer 전 snapshot을 생략했다. “공개 projection 생성은 반드시 state getter를 읽는다”는 전제가 틀렸다.

공개 variadic `select(dependingOnAll: repeat ...)`은 빈 parameter pack을 허용한다. `store.select { () -> Int in counter.next() }`는 state getter 없이 생성되고 `.alwaysRefresh`로 등록된다. 첫 reducer 안에서 이 선택을 생성하면 e15는 selector 호출/반환값이 2/2인 반면 이전 후보는 1/1이다. State 변경 여부와 무관하다.

`PublicEmptyPackConsumer.swift`는 public API만 사용하며 `@testable` 또는 package 접근이 없다. Swift 6.4 `-O` 외부 소비자에서 독립 검토가 이 회귀를 재현했다. 새 후보와 e15를 동일한 외부 소비자로 다시 실행해 변경/불변 두 경우 모두 2/2로 복원됨을 확인했다. 빈 pack을 사후 비지원으로 분류하거나 강제로 state를 읽게 하지 않는다. 후자는 reducer의 active inout 접근과 충돌할 수 있다.

## Always와 arbitrary dependency의 차이

늦게 등록한 always-refresh observer는 action 끝의 refresh로 복구할 수 있다. 그러나 arbitrary dependency에는 실제 이전 State가 필요하다. package 등록도 기존 접근범위와 호출 의미를 보존한다.

구체 대조는 초기 State가 각각 0과 1인 두 Store다. reducer가 둘 다 0으로 덮은 뒤 같은 `old != new` dependency를 등록한다.

| 초기 State | 최종 State | e15 comparator 인자 | 필요한 refresh |
| --- | --- | --- | --- |
| 0 | 0 | (0, 0) | 0회 |
| 1 | 0 | (1, 0) | 1회 |

현재 State와 새 registration은 같아도 필요한 결과는 다르다. 이전 값을 이미 버린 뒤 current State만으로 이를 구분할 수 없다. 모든 late observer를 refreshAll하면 첫 경우가 틀리고, current State를 old와 new에 모두 넘기면 둘째 경우가 틀린다. 현재 generic 계약에서 과거 값을 복원할 추가 정보 없이 일반 preimage를 생략한다는 주장은 성립하지 않는다. 이번 변경은 계약을 제한하거나 selector purity를 가정하지 않는다.

## 새 경계

`@Observable`, 원래 state getter, 이전 snapshot의 위치/수명, `withMutation`, reducer 본문과 lifetime preparation, effect 실행 순서를 e15 그대로 유지한다. ever-read flag와 reducer helper는 제거했다.

일반/animated mutation이 모두 완료되고 root didSet callback까지 반환한 **후** registry를 검사한다.

- registration이 있으면 기존 `refresh(from: previousState, to: storedState)`를 수행한다. reducer나 Observation callback에서 추가된 always/single/multiple dependency도 같은 실제 old/new State를 받는다
- registry가 비었을 때만 현재 State를 refresh에 넘기지 않고 기존 refresh-pass counter를 한 번 증가시킨다
- 약한 stale entry가 남으면 보수적으로 기존 refresh/compaction 경로로 들어간다. 등록/해제나 미래 callback을 추측하지 않는다
- reducer 전에 registry를 검사해 이전 State를 생략하지 않는다. Optional snapshot, pending snapshot, unsafe pointer, unchecked storage를 추가하지 않는다

검사를 helper에 두었던 초기 형태는 empty 경로에도 추가 generic metadata 준비가 남았다. 최종 형태는 기존 두 mutation 지점에 guard를 직접 배치해 그 추가 helper를 제거했다.

## 정확성 및 음성 대조

새 `ProjectionRegistrationBoundaryTests`는 다음을 실제 Store를 통해 검증한다.

- always/single dependency/multiple dependencies, State 변경/불변
- mutation 전/후의 늦은 package 등록, 일반/animated 경로
- 공개 빈 parameter pack selector의 호출 횟수와 반환값
- 같은 최종 State를 가진 0/1→0 preimage 대조
- 실제 comparator 인자와 observer refresh 횟수, action당 registry pass count

기존 SnapshotBoundaryConsistencyTests의 public didSet selector 호출/반환값, root willSet/didSet 순서, Optional nil, read-once/observer 해제·후발 생성, selected/scoped 값 보존, 재진입과 함께 실행했다. 기존 optional/collection lifetime, owned synchronous effect, cancellation/physical completion도 포함한다.

동일 테스트를 적용한 e15와 최종 후보는 Swift 6.3에서 각각 62개, Swift 6.4에서 각각 65개 테스트를 통과했다. current State를 old 대신 전달하는 음성 대조는 같은 새 suite에서 18개 assertion을 실패했다. 이 대조는 always-refresh 공개 사례는 유지하면서 변경된 dependency와 preimage 구별을 잃으므로, 단순 “refresh를 호출했는지”만 확인하는 테스트가 아니다.

Swift 6.4의 `withObservationTracking(options:)`는 public API이며 SPI를 import하지 않는다. Apple 27.0 availability와 `#if compiler(>=6.4)`로 제한해 6.3에서는 해당 기존 3개 선언을 조건부 제외한다.

## 정적 비용 및 범위

Swift 6.4 optimized machine code의 일반/animated 두 경로 모두에서 `hasRegistrations == false` 분기는 현재 State의 initialize-with-copy, destroy witness 및 `ProjectionObserverRegistry.refresh` 진입을 건너뛰고 counter만 증가시킨다. 정적 callsite가 삭제됐다는 주장과 실제 빈 registry 경로가 해당 호출을 실행하지 않는다는 사실은 구별한다. 기존 State metadata/stack 준비, reducer 전 snapshot 및 lifecycle 비용은 남는다.

관찰자가 있는 경로에는 registry 존재 검사가 하나 추가된다. 따라서 시간 개선이나 비회귀는 이 정적 결과로 판단하지 않는다. 새 사전 승인 cohort에서 확인해야 한다.

별도의 checked-Sendable 사용자 COW 저장소를 사용하는 외부 소비자로 10회 append를 검사했다. never-read, read-once/no-observer, observer 해제, observer 유지 네 경우 모두 e15와 후보의 clone은 **10회**이고 최종 전체 원소가 동일하다. 이 후보가 pre-mutation COW를 제거하지 않는다는 대조다. clone 수는 프로세스 전체 allocation 수나 시간 측정이 아니다.

## 남은 검증

- 최종 source SHA의 독립 safety 재검토와 결합 검사
- 새 사전 승인 timing 및 observed 경로의 추가 검사 비용 평가
- 중앙 test source/ID inventory 및 release-policy count/hash 갱신. e15 대비 신규 선언은 12개이며 6.3에서는 9개가 활성이다
- Apple 원본 lock, SwiftUI/Bindable rendering, Apple runtime matrix와 CI-only Release Preflight
- 일반 pre-mutation State copy 제거는 미해결. 이번 후단 후보와 별개의 계약/구조 판단이 필요하다

Linux 검증은 checked Mutex adapter와 OSLog guard만 적용한 별도 mirror, build 및 module cache를 사용한다. 기존 timing 원자료/바이너리/기준과 원격 상태를 변경하지 않는다.
