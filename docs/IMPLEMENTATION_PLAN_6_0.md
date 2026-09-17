# InnoFlow 6.0.0 — 1~7단계 코드 작업 계획

- 상태: **1~7 implementation complete · local RC verification complete** · 작성 기준: 2026-09-05 로컬 소스
- 대상: `release/6.0.0-local`의 현재 변경분을 보존한 Swift 6.0.0 후보
- 요청 범위: 1~7단계 로컬 구현과 검증. 커밋, 푸시, 태그, 공개 배포 승인은 아니다.
- 결정권자: 프로젝트 소유자. 기술 검토자·최종 승인자 및 승인일: 미기록.
- 순서: **1 → 2 → 3 → 4 → 5 → 6 → 7**. 단계별 테스트를 해당 단계에서 수행하고, 통과한 뒤 다음 단계로 진행한다.
- 아래 API와 테스트 이름은 최종 로컬 후보에 구현된 이름이다. 공개 배포 전에는 원격 tag에서 사용할 수 있는 API로 소개하지 않는다.

## 목표와 경계

실제 소비자가 반복 작성하는 실행 제어와 테스트 코드를 줄이되, 취소·출력·상태 전이의 의미를 약화하지 않는다. 기능 개수 대신 다음 결과로 완료를 판단한다.

- 실행 정책을 사용해도 중복 실행, 대기 작업 유실, 취소 뒤 상태 변경, 영구적인 로딩 상태가 생기지 않는다.
- 화면 또는 코디네이터가 소유한 dispatch를 정확히 정리하고, 별도 소유자의 저장 작업까지 취소하지 않는다.
- 실패를 요청 단위로 추적하고 동일한 테스트 시나리오로 재현할 수 있다.
- 물별의 실제 기능과 선언한 Apple 플랫폼에서 기존 사용자 동작이 유지된다.

비목표: 저장소·네트워크·재시도·트랜잭션·라우팅 프레임워크 추가, 비협조적 외부 작업 강제 중단, exactly-once 저장 보장, 프로덕션 상태 전체 녹화/재생, DevTools UI 신설. 기존 `State`, typed ephemeral `Output`, `PhaseMap`의 post-reduce 소유권을 바꾸지 않는다.

### 확인된 현재 상태

| 확인 사항 | 현재 근거 | 계획에 미치는 영향 |
| --- | --- | --- |
| latest 취소, debounce, throttle, 단일 effect tree의 concatenate가 있다. 독립 dispatch 사이의 일반적인 직렬 큐는 없다. | [EffectTask.swift](../Sources/InnoFlowCore/EffectTask.swift), [EffectWalker.swift](../Sources/InnoFlowCore/EffectWalker.swift) | 기존 latest를 재사용하며, concatenate를 전역 직렬 실행으로 오해하지 않는다. |
| Store와 TestStore가 공통 walker/driver 계약을 사용한다. | [EffectDriver.swift](../Sources/InnoFlowCore/EffectDriver.swift), [StoreEffectBridge.swift](../Sources/InnoFlowCore/StoreEffectBridge.swift) | admission 상태 기계도 공유하고 구현 두 벌을 만들지 않는다. |
| dispatch별 FlowTask와 captured output이 있다. | [FlowTask.swift](../Sources/InnoFlowCore/FlowTask.swift), [CLAUDE.md](../CLAUDE.md) | scope와 진단은 기존 dispatch 수명에 연결한다. |
| output의 exact/predicate/CasePath 테스트가 이미 있다. | [TestStore+Output.swift](../Sources/InnoFlowTesting/TestStore+Output.swift) | 새 매칭 엔진 대신 scoped 전달과 매크로 작성을 보완한다. |
| ScopedTestStore는 ChildOutput 형식이나 원본 child reducer를 보유하지 않는다. | [ScopedTestStore.swift](../Sources/InnoFlowTesting/ScopedTestStore.swift) | 원본 child output을 자동 복원한다고 약속하지 않는다. |
| 물별은 persistence revision/FIFO와 busy guard를 직접 관리한다. | [Settings queue](../../Projects/Mulbyul/Apple/Features/Settings/Logics/SettingsPreferencesPersistenceQueue.swift), [Settings reducer](../../Projects/Mulbyul/Apple/Features/Settings/Logics/SettingsFeatureReducer+Preferences.swift), [TrainingRecords](../../Projects/Mulbyul/Apple/Features/TrainingRecords/UIs/Shared/TrainingRecordsFeature.swift), [Routine editor](../../Projects/Mulbyul/Apple/Features/Training/UIs/Shared/TrainingRoutineEditorFeature.swift) | 공통 실행 제어와 앱의 저장 순서·롤백 정책을 분리해서 파일럿한다. |
| 현재 패키지는 Swift tools 6.3, iOS 18/macOS 15/tvOS 18/watchOS 11/visionOS 2 이상이다. | [Package.swift](../Package.swift) | 5개 Apple SDK를 필수 검증하고 Core의 SwiftUI·매크로 독립성을 유지한다. |

이 계획은 구현과 검증 결과에 맞춰 갱신했다. 현재 체크아웃에는 기존 tracked/untracked 변경이 많으므로 로컬 후보는 baseline HEAD가 아니라 아래 품질 문서에 기록한 working-tree snapshot과 검증 증거의 조합으로 식별한다.

## 요구사항과 작업 추적

각 AC는 해당 FR의 완료 기준이다. 대표 검증 증거는 실제 테스트 파일 또는 그 안의 suite 이름이다.

| 요구사항 | 완료 기준 | 작업 | 대표 검증 증거 |
| --- | --- | --- | --- |
| FR-001: 실행·취소·완료·진단의 공통 계약을 명시한다. | AC-001: 정책별 상태 전이, 소유권, 경합/실패 사례, API 호환성 판단을 ADR과 테스트 명세로 고정한다. | IF6-01A~C | ADR, 계약 시나리오 목록, 후보 스냅샷 |
| FR-002: latest/busy-ignore/bounded-serial 실행을 지원한다. | AC-002: FIFO·상한·취소·실패·출력·finish 테스트가 Store/TestStore에서 같은 의미로 통과한다. | IF6-02A~C | EffectRunSchedulerTests, Store/TestStore runtime tests |
| FR-003: 여러 dispatch의 수명을 명시적으로 소유한다. | AC-003: 정상/throw/cancel 종료 시 미완료 작업을 정리하고, 완료 작업·형제 scope에 영향이 없다. | IF6-03A~C | FlowScopeTests, FlowTask tests |
| FR-004: 한 요청의 실행 이력을 연결해서 진단한다. | AC-004: root/descendant 상관관계, 제한된 기록, 누락 표시, 기본 비식별 진단을 검증한다. | IF6-04A~C | DispatchDiagnosticsTests, EffectTimingRecorderTests |
| FR-005: 모든 테스트 상태 전이에 불변식을 적용하고 시나리오를 재현한다. | AC-005: exhaustive/scoped/자동 소비 경로에서 정확히 1회 검사하고, 같은 시나리오의 의미적 결과와 실패 위치가 재현된다. | IF6-05A~C | TestStoreInvariantTests.swift의 invariant/scenario suites |
| FR-006: Output 작성·scoped 검증의 반복 코드를 줄인다. | AC-006: 공개/제네릭/충돌 매크로 계약과 root output 큐의 순서·exhaustivity·단일 deadline을 유지한다. | IF6-06A~C | OutputCasePathTests, TestStoreOutputMatchingTests, macro tests |
| FR-007: 실제 소비자와 지원 플랫폼에서 통합 검증한다. | AC-007: 물별 파일럿·5 SDK·런타임 시나리오·품질/배포 게이트의 증거와 미검증 경계가 동일 후보에 연결된다. | IF6-07A~D | 소비자 diff/테스트, SDK 로그, QA 표, 릴리스 체크리스트 |

공통 제약:

- NFR-001: 기존 작업을 보존한다. 원본 물별과 별도 Kotlin/TypeScript 후보를 묵시적으로 덮어쓰거나 병합하지 않는다.
- NFR-002: 취소는 협조적이다. 취소 요청과 실제 종료를 구분하며, 취소가 이미 수행된 상태 변경/외부 저장을 되돌렸다고 표시하지 않는다.
- NFR-003: 테스트는 ManualTestClock과 명시적 동기화 지점을 사용한다. 긴 sleep, 무작위 타이밍, 횟수 증가만으로 경합 검증을 대체하지 않는다.
- NFR-004: 무한 대기열·완료 task 보관·기본 payload 녹화를 추가하지 않는다. Core에는 SwiftUI, 컴파일러 플러그인, 앱 서비스 의존성을 추가하지 않는다.
- NFR-005: 기능별 계약·테스트·문서·관련 CI 게이트를 같은 작업 묶음에서 갱신한다. 문서 갱신을 모두 7단계로 미루지 않는다.

## 1. 공통 계약 설계

목적: 이후 2~6단계가 서로 다른 취소·완료 개념을 만들지 않도록 먼저 설계 기준을 잠근다.

### 작업 순서

- [x] **IF6-01A — 기준선 보존.** 현재 branch/HEAD, tracked diff, untracked 소스, 의존성/toolchain, 기존 검증 로그를 기록한다. 기존 변경을 포함한 명시적 후보 스냅샷을 사용하고 `git add -A`, 원본 정리, 자동 stash를 하지 않는다. 기존 핵심 테스트의 baseline 실패와 신규 작업으로 인한 실패를 구분한다.
- [x] **IF6-01B — 계약 ADR.** 신규 `docs/adr/ADR-effect-admission-and-flow-lifetime.md`에 아래 계약과 반례를 기록한다. `ARCHITECTURE_CONTRACT.md`, `CLAUDE.md`, `docs/API_BREAKAGE_6_0.md`의 영향을 목록화한다.
- [x] **IF6-01C — API/테스트 명세 확정.** 정책 표, dispatch ID와 admission sequence의 구분, 종료 상태를 컴파일 fixture 및 테스트 시나리오로 분해한다. 기존 공개 API와 충돌하는 overload/enum 변경을 분류하고 2단계 구현 입력으로 확정한다. 미구현 stub을 공개 라이브러리에 먼저 넣지 않는다.

### 잠글 계약

| 항목 | 설계안 |
| --- | --- |
| 요청 정체성 | root dispatch ID는 전체 descendant에 전파한다. action의 admission sequence, 개별 run token, cancellation ID와 다른 값이다. |
| 실행 lane | Store별 typed EffectID 영역. 다른 Store와 공유하지 않는다. child별 독립성이 필요하면 기존 취소 ID처럼 명시적으로 namespace한다. Scope가 임의로 독립 lane을 만들어준다고 가정하지 않는다. |
| 순서 | async Task가 CPU를 얻은 순서가 아니라 Store가 효과를 접수한 순서로 입장시킨다. |
| 상태/결과 | queued → running → physically terminated. rejected와 시작 전 cancelled도 종료 경로다. 실행 종료/실패/취소 요청/입장 거부를 진단에서 구분한다. 도메인 성공·실패는 기존 Action/Output가 표현한다. |
| 취소 소유권 | dispatch, effect ID, lexical scope가 취소 가능한 범위를 정의한다. scope 종료에 Store 전역 cancel을 사용하지 않는다. |
| 완료 | 대기 중인 scheduled run도 FlowTask 활동으로 계산한다. `finish()`와 captured stream은 해당 작업이 제거/종료되기 전에 완료되지 않는다. |
| 직렬성 | 한 lane의 이전 run closure가 실제 종료된 뒤 다음 closure를 시작한다. 취소 신호만으로 slot을 넘기지 않는다. descendant 전체의 종료를 slot 조건으로 삼지 않아 같은 lane 재진입 교착을 방지한다. |
| 상태 복구 | admission 결과는 명시적으로 Action에 연결한다. cancelled dispatch에서 뒤늦은 cleanup Action을 자동 방출하지 않는다. 화면의 취소 의도와 로딩 상태 복구는 reducer에 명시한다. |
| 정책 충돌 | 살아 있는 같은 lane에 상충하는 정책/상한을 적용하면 명시적으로 거부·진단한다. 기존 대기 작업의 정책을 조용히 바꾸지 않는다. |

단계 종료: AC-001의 모든 행에 정상·실패·취소 예시가 있고 의미상의 미결정이 없다. API 이름 같은 구현 결정은 담당 구현자가 ADR에 남길 수 있지만, 저장/취소 소유권이나 사용자 동작 변경은 프로젝트 소유자의 판단 없이 확장하지 않는다.

## 2. 동시 실행 정책

목적: 서로 다른 send에서 발생한 작업에 공통 실행 제어를 적용한다.

### 코드 변경 묶음

- [x] **IF6-02A — 정책과 공유 scheduler.** 신규 `Sources/InnoFlowCore/EffectExecutionPolicy.swift`, `EffectRunScheduler.swift`. `latest`, `dropWhileRunning`, `serial(maxPending:)` 정책과 입장 결과 형식을 추가한다. Store와 TestStore가 사용하는 하나의 `@MainActor` 상태 기계를 만들고, 대기 노드에는 실행에 필요한 최소 정보와 원래 dispatch 문맥만 저장한다.
- [x] **IF6-02B — effect 해석/수명 연결.** `EffectTask.swift`, `EffectWalker.swift`, `EffectDriver.swift`, `StoreEffectBridge.swift`, `Store+EffectDriver.swift`, `EffectExecutionContext.swift`를 수정한다. 새 scheduled-run operation의 action/output map, cancellation-ID 탐색, await/concatenate, 활동 등록/해제를 빠짐없이 연결한다. `TestStore+EffectDriver.swift`, `TestStore+EffectLifecycle.swift`, `TestStore+Finish.swift`도 같은 상태 기계에 연결한다.
- [x] **IF6-02C — 통합 회귀와 사용 예.** 신규 scheduler/통합 테스트와 `OrchestrationDemo.swift` 예제를 추가한다. 기존 `StoreEffectRuntimeTests`, `TestStoreEffectAlgebraTests`, `FlowTaskCancellationBoundaryTests`, `ReducerOutputTests`를 확장한다. 실행 정책 ADR·DocC를 함께 갱신한다.

API 방향: 임의의 effect tree 전체에 정책 wrapper를 씌우기보다 **run 하나의 실행을 예약하는 overload**를 우선한다. 후보 시그니처는 `.run(id:policy:onAdmission:operation:)`이며 실제 인자/closure 형식은 IF6-01C에서 정한다. `ReducerEffect<Action, Output>`에 구현하여 `EffectTask<Action>`뿐 아니라 typed output 효과도 지원한다.

정책별 동작:

- `latest`: 기존 cancel-in-flight 의미와 stale emission 차단을 재사용한다. 비협조적인 이전 외부 작업과의 물리적 중첩까지 막는다고 약속하지 않는다.
- `dropWhileRunning`: 실행 중이면 새 run을 수행하지 않고 busy 거부 결과를 알린다. 거부된 요청은 FlowTask를 남기지 않는다.
- `serial(maxPending:)`: 1개 실행 + 최대 N개 대기. N=0, 음수 등 경계의 허용/거부 형식을 1단계에서 고정한다. 초과 시 새 요청을 명시적으로 거부한다. 대기 취소는 노드를 제거해 즉시 용량을 돌려준다.
- `onAdmission`: queued/started/rejected를 명시적 Action으로 연결할 수 있게 한다. 요청 Action에서 무조건 loading=true로 바꾸는 예제는 피하고, request identity를 보존해 오래된 admission 결과가 새 화면 상태를 덮지 않도록 한다.
- 실패한 run이 끝나면 다음 독립 요청을 진행한다. 전체 큐 중단, retry, 저장 rollback이 필요하면 앱이 명시적으로 제어한다.
- 직렬 예약은 외부 작업의 실행 순서 계약이지 domain revision 순서, 트랜잭션, descendant 전체의 완료 순서 보장이 아니다. 실제 저장을 detached task로 넘기고 closure가 먼저 반환하면 직렬 저장이 보장되지 않는다.

필수 테스트:

1. Task 시작 순서를 의도적으로 뒤집어도 admission FIFO가 유지된다.
2. lane/Store 간 독립성, typed ID 충돌 방지, 같은 lane 정책 충돌, queue overflow가 명확하다.
3. 대기 취소·현재 작업 취소·실패 후 다음 실행·오래된 완료 callback·deinit 경합을 검증한다.
4. 취소를 무시하는 가짜 저장을 latch로 붙잡고, 실제 반환 전에 다음 저장이 시작되지 않음을 증명한다.
5. queued run을 포함한 FlowTask.finish, captured output, concatenate와 action/output mapping을 검증한다.
6. 같은 lane에 descendant가 재입장해도 scheduler 내부 await 때문에 교착하지 않는다. 앱 closure가 자신의 후속 작업을 순환 대기하는 경우는 지원 불가 사례로 문서화한다.
7. 입장 거부·취소 후 UI 상태가 영구 loading에 남지 않는 reducer 예제와 Store/TestStore 이벤트 비교 테스트를 통과한다.

단계 종료: AC-002 통과. 대기 노드/활동/취소 핸들이 모두 해제되고, queue와 최신 요청의 결과가 섞이지 않는 증거를 남긴다.

## 3. 작업 수명 관리

목적: 한 화면·코디네이터가 시작한 여러 dispatch를 하나의 명시적 수명으로 묶는다.

- [x] **IF6-03A — scope 원시 기능.** 신규 `Sources/InnoFlowCore/FlowScope.swift`. `withFlowScope { scope in ... }`와 `scope.track(...)` 형태의 MainActor lexical API를 설계한다. FlowTask와 OutputFlowTask를 모두 받되 원래 핸들/stream을 유지한다. Core에서 SwiftUI view modifier를 만들지 않는다.
- [x] **IF6-03B — 종료/등록 경합과 보관 해제.** `FlowTask.swift`의 tracker에 내부 완료 알림을 추가하고 완료된 핸들을 scope에서 즉시 제거한다. 이미 완료된 task 등록, scope 닫힘과 등록의 경합, 재진입 callback을 처리한다. dispatch마다 영구 watcher Task를 생성하지 않는다. 닫힌 scope에 늦게 등록한 작업은 취소하고 진단한다.
- [x] **IF6-03C — 소비 예와 수명 테스트.** `OrchestrationDemo.swift`에서 SwiftUI `.task`/coordinator 소유 예제를 추가했다. `FlowScopeTests.swift`와 기존 FlowTask 테스트를 보강했다.

종료 계약:

- 정상 반환·throw·부모 Task 취소 모두 남아 있는 작업에 취소를 요청하고 협조적인 종료를 기다린다. 완료된 작업을 뒤늦게 cancelled로 바꾸지 않는다.
- 등록된 작업만 소유한다. 형제 scope, 다른 Store, scope 밖의 앱 소유 저장 작업은 취소하지 않는다. nested scope 간 소유 관계도 명시적 등록에 따른다.
- output 순회 중 `break`만으로 남은 작업이 정리된다고 가정하지 않는다. scope를 벗어나는 시점의 cleanup을 검증한다.
- 비협조적 작업 때문에 종료가 지연되면 미종료 상태가 관찰되어야 한다. timeout이 발생했다고 실제 완료로 위장하거나 임의로 task를 분리하지 않는다.

필수 테스트: 정상 종료/throw/취소 전파, body 진입 전 취소, 등록-종료 경합, output early break, 완료 task의 isCancelled 유지, nested/sibling 격리, 다량 반복 후 보관 수 0, Store/observer 해제. 부모 취소된 문맥에서도 cleanup이 대기 중인 작업을 제대로 join하는지 별도 검증한다.

단계 종료: AC-003 통과. 앱이 의도한 화면 밖 지속 작업과 화면 종속 작업을 각각 예제로 설명할 수 있다.

## 4. 요청 단위 통합 진단

목적: 한 번의 send에서 파생된 admission/action/run/output/cancel 흐름을 연결하고 멈춘 작업의 위치를 알 수 있게 한다.

- [x] **IF6-04A — dispatch context 전파.** 신규 `Sources/InnoFlowCore/DispatchContext.swift`에 필요한 최소 ID/context를 정의한다. `FlowTask.swift`, `Store.swift`, `StoreActionQueue.swift`, `EffectExecutionContext.swift`, runtime/bridge의 후속 action·output 경로에 전파한다. 1단계 계약에 따라 root identity와 action sequence를 분리한다.
- [x] **IF6-04B — 제한된 trace와 active snapshot.** `StoreInstrumentation.swift`, `StoreInstrumentation+Metrics.swift`를 확장한다. 신규 `StoreDiagnostics.swift`에는 opt-in ring buffer, 초과/잘림 카운트, queued/running/cancellation-requested 상태 snapshot을 둔다. 완료 이력은 용량 제한을 적용하고 active 작업 수는 실제 live 작업을 반영한다. snapshot 반환 개수도 제한 가능하게 한다.
- [x] **IF6-04C — 기존 export/adapter 통합.** `EffectTimingRecorder.swift`와 기존 JSONL·OSLog/signpost 경로를 확장한다. `DispatchDiagnosticsTests.swift`, 기존 `StoreInstrumentationTests`, `StoreInstrumentationMetricsTests`, `EffectTimingRecorderTests` 및 instrumentation cookbook을 갱신한다.

필수 제약/검증:

- 기존 instrumentation callback 자체를 없애거나 의미를 바꾸지 않는다. 진단 기록은 기본적으로 Action/State/Output 값과 원문 effect ID를 저장하지 않고 metadata만 사용한다. 명시적으로 허용한 payload도 redaction 경계를 테스트한다.
- initializer에 context를 추가할 때 기본값/기존 overload를 보존한다. 공개 event enum case 추가는 외부 exhaustive switch에 영향을 줄 수 있으므로 무조건 source-compatible이라고 표시하지 않는다.
- 두 Store의 동일 Action, 병렬 root, descendant, 지연 callback 사이에 상관관계가 섞이지 않는다. cancel 요청과 실제 run 종료를 별개로 표시한다.
- diagnostics 비활성화 시 추가 history buffer가 할당되지 않는다. trace가 꽉 차도 runtime 의미와 admission 정책이 바뀌지 않는다. 출력은 유실/잘림을 숨기지 않는다.
- recorder/observer가 Store를 붙잡지 않는다. 활성 작업이 해제되면 진단 registry에서도 제거된다.
- 성능은 기존 [PERFORMANCE_BASELINES.md](PERFORMANCE_BASELINES.md)의 workload로 변경 전후를 비교한다. 기존 timing trend를 임의로 blocking threshold로 바꾸거나 baseline을 느슨하게 갱신하지 않는다. 추가 workload/메모리 예산은 구현 시 근거와 함께 기록한다.

단계 종료: AC-004 통과. 한 요청의 대기 원인·취소 소유자·실제 종료 여부를 payload 노출 없이 테스트 증거에서 구분할 수 있다.

## 5. 불변식·시나리오 테스트

목적: 선택한 assertion뿐 아니라 모든 실제 상태 전이를 검사하고, 복잡한 실패를 짧고 재현 가능한 테스트로 표현한다.

- [x] **IF6-05A — reduce 단일 진입점.** `TestStore+Public.swift`의 send/applyReceivedAction/applyScopedAction과 `TestStore+Exhaustivity.swift`의 applyUnassertedAction을 공통 내부 reduction helper로 모은다. 먼저 기존 receive/finish/exhaustivity 의미가 그대로인지 회귀 테스트한다.
- [x] **IF6-05B — invariant hook.** 신규 `TestStoreInvariant.swift`, `TestStore+Invariants.swift`. 이름·소스 위치가 있는 순수 MainActor state predicate를 등록한다. 전체 reducer composition과 PhaseMap 처리 후, effect 해석 전의 최종 state를 정확히 한 번 검사한다. `.off`여도 명시적으로 등록한 invariant는 계속 검사한다.
- [x] **IF6-05C — scenario runner.** 신규 `TestStoreScenario.swift`와 테스트 전용 step/result 형식. send/receive/receiveOutput/clock advance/finish를 현재 TestStore API로 실행한다. ManualTestClock을 사용하고 step index, 선택적 seed, 실패 assertion을 기록한다. `TestStoreInvariantTests.swift`의 scenario suite와 Testing DocC를 추가했다.

필수 테스트:

- 직접 send, effect receive, scoped send, `.off`에서 건너뛴 action, finish의 자동 drain 모두 invariant 검사 대상이다.
- 중간 child reduce마다 중복 검사하지 않고 최종 합성 state만 검사한다. PhaseMap의 post-reduce 의미를 유지한다.
- 실패 메시지는 invariant 이름, step/action 식별, file/line, 크기 제한된 state diff를 제공한다. predicate 내부에서 effect 실행이나 재귀 send를 허용하지 않는다.
- 같은 script/seed/가짜 의존성/clock 진행에서 Action·State·Output의 의미적 결과와 실패 step이 같다. UUID·실제 소요 시간 등 비결정적 진단 값의 바이트 동일성은 요구하지 않는다.
- 취소, admission 거부, output mismatch, 이미 버퍼된 output과 timeout을 구분한다. 외부 시스템의 임의 응답까지 자동 재현한다고 약속하지 않는다.

첫 구현은 테스트 내 typed script 재실행까지다. 모든 Action/State에 Codable을 강제하거나 production trace를 실행 스크립트로 간주하지 않는다. 파일 저장이 필요한 feature만 명시적 codec을 제공하고, 자동 최소 반례 축소는 이번 필수 범위에 넣지 않는다.

단계 종료: AC-005 통과. 2~4단계의 대표 경합/취소 회귀를 새 불변식·시나리오 API로 다시 표현하되 기존 저수준 회귀도 유지한다.

## 6. 작성·테스트 편의성

목적: typed Output를 사용하는 기능의 수동 CasePath 및 scoped 테스트 반복 코드를 줄인다.

- [x] **IF6-06A — Output CasePath 합성.** `InnoFlowMacro.swift`, `InnoFlowMacro+OutputPathSynthesis.swift`, `Sources/InnoFlow/InnoFlow.swift`를 수정했다. 내부 Output-path attached macro와 plugin 등록을 추가하고 기존 합성 엔진을 역할별로 재사용했다. Action의 collection routing 최적화는 Output에 자동 적용하지 않는다.
- [x] **IF6-06B — scoped output 매칭.** `ScopedTestStore.swift`에 `CasePath<Root.Output, Value>`를 명시적으로 받는 receiveOutput overload를 추가했다. `TestStore+Output.swift`의 내부 매칭 helper를 공유했다. 기존 ScopedTestStore 공개 generic arity는 변경하지 않는다.
- [x] **IF6-06C — 외부 authoring/호환성 검증.** macro diagnostics/`CompileContractTests`를 보강하고 README의 typed Output 예제, DocC, `docs/MACRO_OPERATIONS.md`, migration/API breakage 문서를 갱신했다.

필수 테스트:

- payload 없음/단일 값/optional nil, 지원하는 labeled·복수 payload, public/private, generic/extension 선언을 다룬다. unsupported 형태는 진단·수동 경로를 명확히 제공한다.
- 사용자 수동 CasePath, 같은 이름의 member, opt-out, `Output == Never`, Output typealias가 중복 합성·애매한 진단을 만들지 않는다.
- Action의 `id:action:` collection 합성은 기존대로 유지한다. Output의 비슷한 payload를 routing ActionPath로 오인하지 않는다.
- scoped 테스트는 root output 큐를 그대로 소비한다. 별도 구독·복사 큐를 만들지 않는다. exhaustive 모드에서는 앞선 sibling output을 조용히 건너뛰지 않는다.
- optional nil 성공을 mismatch와 구분하고 부모 TestStore와 동일한 전체 deadline/취소 동작을 유지한다. collection ID별 검증은 ID가 보존된 root output path로 명시한다.
- parent mapOutput이 child 구분 정보를 지웠다면 자동 복원은 불가능하다. 필요한 식별자를 보존한 출력 설계를 문서와 테스트 예제로 제공한다.
- 별도 consumer module에서 생성된 API의 접근 수준과 overload 추론을 컴파일 검증한다. Core-only 사용은 plugin 없이 계속 가능해야 한다.

단계 종료: AC-006 통과. 실제 부모/자식 출력 예제에서 수동 보일러플레이트가 줄고 출력 순서·소유권은 그대로여야 한다.

## 7. 소비자·플랫폼 검증

목적: 라이브러리 테스트 통과를 실제 프로덕션 사용 가능성과 혼동하지 않고, 같은 후보를 소비자/SDK/런타임/릴리스 단계까지 검증한다.

- [x] **IF6-07A — 물별 파일럿.** 기존 작업을 보존한 명시적 로컬 소비자 후보에 연결했다. 필요한 `Reducer<State, Action, Output>` 마이그레이션을 분리했고 TrainingRecords 중복 load와 RoutineEditor 중복 저장을 공통 admission 정책으로 차단했다. Settings 저장은 revision/FIFO/rollback/retry 도메인 계약 때문에 기존 큐를 유지하고 회귀 테스트로 비교했다.
- [x] **IF6-07B — 전체 라이브러리 검증.** Debug/Release, TSan/ASan, macro/compile contracts, sample package, API compatibility, principle/static/release-sync 게이트를 동일 소스에서 실행했다. 5개 Apple SDK를 `InnoFlow-Package` scheme, 고유 DerivedData, `-jobs 1`, 서명 비활성화로 검증했다.
- [x] **IF6-07C — 런타임·사용성 검증.** 아래 플랫폼/실패 행렬을 실행하고 시뮬레이터/실기기/미실행을 구분해 기록했다. library build 실패, 소비자 source/API 오류, 기능 동작 오류를 별도 분류했으며 제공되지 않는 제품 표면은 검증했다고 확대 해석하지 않는다.
- [x] **IF6-07D — 로컬 릴리스 증거 정리.** `docs/QUALITY_REVIEW_6_0.md`, `RELEASING.md`, `RELEASE_NOTES.md`, `CHANGELOG.md`, `MIGRATION.md`, README 번역본, DocC, CI 및 principle gates를 최종 대조했다. 후보 hash/toolchain/명령/종료 코드/결과 경로를 묶고 로컬 준비 상태와 외부 게이트를 분리했다.

### 물별 적용 기준

| 소비자 파일/영역 | 적용 후보 | 반드시 유지할 계약 |
| --- | --- | --- |
| `Apple/Features/TrainingRecords/UIs/Shared/TrainingRecordsFeature.swift` | dropWhileRunning, 요청 진단, loading invariant | 중복 조회 차단, 재시도 가능, 화면 종료 후 stale 결과 차단, 오류 후 로딩 해제 |
| `Apple/Features/Training/UIs/Shared/TrainingRoutineEditorFeature.swift` | 저장 admission, 화면 소유 scope, 실패 scenario | canSave의 입력 검증과 편집 제한은 유지. 저장 중 닫기/취소 정책은 기존 제품 동작과 비교해 결정 |
| `Apple/Features/Settings/Logics/SettingsFeatureReducer+Preferences.swift` | 직렬 실행 파일럿, revision별 trace, invariant | revision 순서, 실패 결과 처리, 최신 값 rollback, 다시 열었을 때 실제 저장값 일치 |
| `Apple/Features/Settings/Logics/SettingsPreferencesPersistenceQueue.swift` | scheduler로 대체 가능한 부분의 비교 대상 | 여러 Store/생명주기 밖 저장까지 담당하면 큐를 유지. Store-local 실행 큐만으로 동일 계약이라 주장하지 않음 |

관련 `SettingsFeatureTests`, `SettingsFeatureContainerTests`, `SettingsSceneTests`, `TrainingRecordsFeatureTests`와 RoutineEditor 기존 테스트를 먼저 재사용한다. 단순히 guard/queue를 제거한 줄 수로 성공을 판단하지 않는다. 제거해도 된다고 입증된 중복만 줄이고, 도메인 규칙은 남긴다.

### 검증 행렬

| 영역 | 최소 검증 | 통과/미검증 판단 |
| --- | --- | --- |
| macOS / iOS / tvOS / watchOS / visionOS | 선언한 최소 OS 설정으로 각 SDK build, 사용 가능한 지원 runtime에서 smoke | SDK build와 실제 runtime 결과를 별도 기록. simulator가 없으면 성공으로 처리하지 않음 |
| 사용자 입력 | 빠른 연타, 중복 저장, 연속 새로고침, 서로 다른 화면의 동시 작업 | 정책별 실행 횟수, busy 상태, 최종 저장값, output 순서가 예상과 일치 |
| 수명 | 화면 재진입, dismiss, scene/background 전환, 취소, Store 해제 | stale 업데이트 없음, 로딩 복구, 정리 후 active/observer 수 기준선 복귀 |
| 플랫폼 입력/표면 | 터치, macOS 키보드/복수 창, tvOS 포커스, watchOS 짧은 세션, visionOS scene | 해당 제품이 제공하는 표면에서 수행. 제공하지 않는 표면은 N/A 사유 기록 |
| 실패/회복 | offline/timeout/서비스 throw, queue full, 비협조적 작업, 일부 저장 실패 | 교착/조용한 손실 없음, 실패 분류·재시도 가능성·저장 상태 일관성 확인 |
| 내구성/자원 | 고정 workload 반복, 장시간 stream/대기, cancel 반복 | 수치와 환경 기록, 무한 큐·완료 핸들 누적·Store retention 없음 |
| 소비 설치 | 별도 consumer에서 정확한 로컬 후보를 의존해 Core-only/매크로 경로 build | 로컬 path 설치 증거와 원격 tag 설치 증거를 구분 |

멀티플랫폼 범위: 이번 6.0.0의 직접 변경 대상은 현재 Swift 패키지의 5개 Apple 플랫폼이다. 별도 Kotlin/TypeScript 후보는 자동 병합하지 않는다. 해당 후보의 공통 semantics와 비교해 실행 정책·수명·출력 차이를 명시하며, Android/Web까지 새 기능의 동등 구현·배포가 완료됐다고 표시하지 않는다. 동일 버전으로 동시 출시를 요구한다면 포팅 범위와 버전 정책을 별도로 확정해야 한다.

### 실행할 검증과 증거 관리

아래 명령/게이트를 실제 실행했으며, 상세 결과와 증거 경로는 `docs/QUALITY_REVIEW_6_0.md`에 기록한다. task별 고유 build path를 사용한다.

- `swift test --jobs 1 --no-parallel -Xswiftc -warnings-as-errors`
- `swift test -c release --jobs 1 --no-parallel -Xswiftc -warnings-as-errors`
- `swift test --jobs 1 --no-parallel --sanitize=thread` 및 `--sanitize=address`를 별도 build path에서 순차 실행
- sample package의 `swift test --package-path Examples/InnoFlowSampleApp/InnoFlowSampleAppPackage --jobs 1 -Xswiftc -warnings-as-errors`
- `scripts/check-api-compatibility.sh`, `scripts/check-release-sync.sh`, `scripts/principle-gates-selftest.sh`, `scripts/principle-gates.sh`
- [ci.yml](../.github/workflows/ci.yml) 및 [RELEASING.md](../RELEASING.md)의 5 SDK/sample UI/macro fallback 검증. Xcode 전체 의존성에 전역 warnings-as-errors를 덧씌워 도구 경고 충돌을 만들지 않는다.

동일 `.build`/DerivedData를 공유하는 빌드를 동시에 실행하지 않는다. 실패는 원본 로그와 최소 재현을 남기고 수정 후 해당 단계 테스트 및 전체 영향 범위를 재검증한다. 실패를 숨기기 위한 gate 우회, 테스트 삭제, 성능 fixture 자동 완화는 하지 않는다.

단계 종료: AC-007 및 모든 FR/AC 통과. 로컬 완료는 **로컬 RC 준비 완료**로 보고한다. remote CI, 실제 원격 의존성 설치, tag/release/publication은 별도 증거·권한이 필요한 외부 게이트이며 이 문서만으로 완료 처리하지 않는다.

## 실행 운영과 남은 결정

1~7단계의 로컬 구현과 검증을 완료했다. 완료 표시는 현재 소스와 실제 테스트를 대조한 항목에만 적용하며, SDK 컴파일을 미실행 제품 UI의 성공으로 승계하지 않는다.

- 단계마다 `계약/구현 → 집중 테스트 → 영향 회귀 → 문서/게이트 갱신 → 증거 기록`의 묶음으로 닫는다. 단계 7만 테스트하는 방식은 사용하지 않는다.
- IF6-01부터 작업 ID 단위로 diff를 분리한다. 미래에 커밋을 승인받더라도 관련 경로만 명시적으로 stage한다. unrelated 변경을 함께 커밋하지 않는다.
- 단계별 보고: 수정 파일, 달성한 AC, 실제 테스트 수/명령, 실패·미검증, 다음 단계. 예상 시간보다 완료 증거를 우선한다.
- 다음 단계에서 선행 계약의 오류가 드러나면 해당 ADR/AC를 다시 검토하고 관련 회귀를 재실행한다. 순서를 지키기 위해 잘못된 계약을 유지하지 않는다.

| 결정/미확인 | 처리 책임과 시점 |
| --- | --- |
| 정책/FlowScope API 최종 철자, queue capacity 검증 방식, admission event 전달 순서 | 구현 담당자가 IF6-01C에서 현재 호출 경로와 컴파일 fixture로 확정. 사용자 동작을 바꾸는 의미 변경은 소유자 검토 |
| 비협조적 작업이 scope 종료를 지연하는 경우의 앱 UX | IF6-03 계약을 유지하고 IF6-07A에서 기존 물별 소유권과 대조. 강제 완료/자동 롤백을 임의 추가하지 않음 |
| 물별 저장 수명이 화면 밖으로 이어져야 하는 정확한 범위 | IF6-07A에서 소비자 코드·테스트 기준으로 확인. 기존 제품 정책과 다른 결론이 필요하면 소유자 결정 |
| 최소 OS/실기기/특정 scene의 실제 실행 환경 가용성 | IF6-01A에서 inventory, IF6-07C에서 증거 수집. 확보하지 못한 조합은 release gate 미통과로 남김 |
| Android/Web의 6.0 동시 기능 동등성 및 버전 정책 | Swift 작업과 별도 경계로 기록. 포팅·동시 배포를 요구하는 경우 프로젝트 소유자가 범위 확정 |
| 공개 배포 시점과 remote 실행 권한 | 로컬 증거가 완성된 뒤 별도 요청/승인. 현재 계획에는 외부 mutation 없음 |

### 반례 점검: 테스트는 통과했는데 제품은 잘못될 수 있는가?

| 반례 | 막는 계약/게이트 |
| --- | --- |
| 취소 테스트만 통과하고 실제 저장은 두 개가 겹친다. | FR-002/AC-002, NFR-002: 비협조적 run의 실제 반환 전 다음 저장 시작 금지 테스트 |
| dispatch.finish가 queued run을 빼먹고 먼저 끝난다. | FR-001/FR-002: enqueue 시 활동 등록과 captured stream 종료 테스트 |
| busy 요청을 버렸는데 화면은 계속 loading이다. | FR-002 + FR-005 + 물별 파일럿: admission identity, 명시적 상태 복구, invariant |
| scope 정리가 다른 화면의 저장까지 취소한다. | FR-003/AC-003: 소유권/형제 scope/앱 수명 저장 분리 테스트 |
| `.off`에서 잘못된 상태를 지나가도 invariant가 실행되지 않는다. | FR-005/AC-005: 네 가지 reduction 진입 경로를 공통 helper로 검증 |
| scoped output 검사가 sibling 이벤트를 몰래 버린다. | FR-006/AC-006: root 큐·exhaustivity·정보 손실 경계 유지 |
| 5 SDK 컴파일을 5 플랫폼 프로덕션 동작으로 보고한다. | FR-007/AC-007: SDK/runtime/소비자 실패/외부 release 증거 분리 |
| 기능을 추가하면서 privacy 또는 메모리 사용이 악화된다. | NFR-004 + FR-004: opt-in metadata 기록, 제한된 history, 해제/반복 workload 증거 |

이 반례 목록과 실제 구현을 대조한 검토가 끝나기 전에는 문서를 Reviewed/Approved로 올리지 않는다. 구현 이후 명세 충족 검증은 실제 코드와 증거를 기준으로 수행하고, 실패한 구현에 맞춰 AC를 조용히 완화하지 않는다.

## 2026-09-06 F1~F7 remediation follow-up

후속 재검토에서 발견한 seven counterexamples는
`docs/REMEDIATION_PLAN_6_0.md`의 R01~R07로 순서대로 수정했다. scheduler의
latest 세대 전이와 상속 cancellation ID, TrainingRecords admission 소유권,
FlowScope caller cancellation, 종료 diagnostics, Output availability 및 조건부
case synthesis를 정식 회귀로 고정했다.

동일 로컬 후보에서 full principle gate, Debug/Release 각 772 tests, full
TSan/ASan, sample tests, 5 Apple SDK builds, device-platform targeted runtime,
외부 compile consumer 및 Mulbyul TrainingRecords integration을 다시 검증했다.
이 후속 완료는 로컬 working-tree 후보에 한정한다. 공개 baseline tag, remote
CI, commit/push/tag/release 및 확보하지 못한 최소 OS 실기기 조합은 별도
release evidence로 남는다.
