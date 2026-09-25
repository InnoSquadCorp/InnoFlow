# InnoFlow 6.0.0 — 재검토 7건 수정 실행 계획

> 2026-09-06 후속 검토: 아래 실행 결과는 당시의 증거 기록이다. 추가 반례로
> R03의 취소 경계와 R06/R07의 일부 조건부·가용성 계약이 미충족임을 확인했다.
> 현재 남은 작업과 완료 판정은 [후속 수정 계획](REMEDIATION_FOLLOWUP_PLAN_6_0.md)의
> IF6-R08~R15를 함께 적용한다. 기존 R01/R02/R04 및 R05의 late-event 수정은 유지한다.

- 문서 상태: **Executed, owner review pending**, 2026-09-06. `Reviewed`/`Approved`로 자동 승격하지 않았다.
- 요청: 재검토에서 발견한 F1~F7의 실제 코드 작업을 순서대로 수행하고 로컬 후보를 검증한다.
- 결정권자: 프로젝트 소유자. 구현 담당: 후속 실행을 맡은 Codex. 검토자/최종 승인자와 승인일: 미기록.
- 관계: [기존 1~7단계 계획](/Users/changwooson/Developer/InnoSquad/InnoFlow/docs/IMPLEMENTATION_PLAN_6_0.md)의 FR/AC를 폐기하거나 재번호화하지 않는 보완 계획이다. 기존 완료 기록을 새 반례까지 통과한 증거로 사용하지 않는다.
- 실행 순서: **준비 → R01 → R02 → R03 → R04 → R05 → R06 → R07 → 통합 검증 → 완료 판정**. 2026-09-06에 이 순서로 로컬 실행을 완료했다.

## 1. 목표·범위·확인된 기준선

목표는 기능 수를 늘리는 것이 아니라, 이미 약속한 완료·취소·진단·플랫폼 계약을 실제 소비자까지 지키는 것이다. 직접 영향을 받는 사용자는 InnoFlow를 사용하는 개발자와 물별의 기록 조회 사용자다.

### 확인된 사실

- InnoFlow 브랜치 `release/6.0.0-local`, HEAD `00a73ed2d2cb94114b0be5c9fbd59c187a4b67c7`.
- 이 HEAD에 미커밋 구현이 더해진 후보를 대상으로 한다. 계획 작성 전 tracked diff SHA-256은 `2c9a6b66bf648b0d6c49391034fdd605a149eba4f88670dc5dc8e844a9418656`으로 직전 검토와 동일했다.
- 직전 검토에서 관련 테스트 93개는 통과했으나 F1~F7 반례가 남았다. 반례를 정식 회귀 테스트로 옮긴 뒤 수정 후보에서 다시 검증했다.
- [검토 보고서](/tmp/innoflow-review-20260906.Kx33EF/REVIEW.md)에 재현 소스와 Debug/Release 로그가 있다. 임시 경로이므로 후속 구현에서 재현을 정식 테스트로 옮겨 보존한다.
- 현 manifest는 Swift tools 6.3, iOS 18/macOS 15/tvOS 18/watchOS 11/visionOS 2 이상이다. 점검 환경은 Xcode 27/Swift 6.4였다. 툴체인 실행 결과와 선언된 최소 지원 계약을 구분한다.
- 물별의 실제 `TrainingRecordsFeature`는 요청 시 loading을 켜고, busy 거절은 상태를 유지하며, PhaseMap은 onAppear를 loading 전이로 취급한다. 따라서 bool만 고치면 충분하지 않다.

### 작업 경계와 가정

- InnoFlow Core/Testing/매크로, 해당 테스트/문서/로컬 검증 게이트, 물별 기록 조회와 직접 연결된 테스트를 수정 대상으로 한다.
- public API·정책 이름·지원 최소 OS·Swift tools·의존성 버전을 유지하는 내부 수정이 기본 방향이다. 호환성 파괴가 필요해지면 별도 결정 대상으로 올린다.
- `.latest`는 이전 비협조적 외부 작업의 강제 중단을 보장하지 않는다. `.serial`/`.dropWhileRunning`의 실행 슬롯은 실제 operation 반환 전에 해제하지 않는다.
- 저장 완료의 exactly-once, rollback, 자동 retry, 새 실행 정책, 새로운 앱 기능은 추가하지 않는다.
- Kotlin/Android·TypeScript/React 별도 후보를 병합하거나 동작을 바꾸지 않는다. 이번 수정의 멀티플랫폼 범위는 Swift 패키지가 선언한 5개 Apple 플랫폼이다.
- 원본 dirty 변경을 정리·덮어쓰기·자동 stash하지 않는다. 커밋·푸시·태그·공개 배포는 이 계획의 실행 범위가 아니다.

## 2. 추적표와 완료 기준

F 번호는 검토 보고서의 발견 항목, FR/NFR은 기존 계획의 요구사항이다. 아래 AC-R은 이를 보완하는 수정 완료 기준이다. 표의 테스트 이름은 기존 suite 또는 앞으로 추가할 **계획된** 테스트 묶음이며 현재 커버리지로 주장하지 않는다.

| 작업 | 우선순위/발견 | 연결 요구사항 | 완료 기준 | 증거 위치 |
| --- | --- | --- | --- | --- |
| IF6-R01 | P1/F1 latest 고립 | FR-002, NFR-002 | AC-R001: 3-way 경합과 stale attach/finish에도 모든 dispatch가 Store 해제 없이 완료되고 예약이 남지 않는다. | EffectRunSchedulerTests, Store/TestStore runtime, FlowTask/output capture 테스트 |
| IF6-R02 | P1/F2 pending 취소 누락 | FR-002, NFR-002 | AC-R002: 상속 ID로 pending을 취소하면 첫 run의 반환을 기다리지 않고 용량을 돌려주며 Store/TestStore 결과가 같다. | EffectRunSchedulerTests, StoreEffectRuntimeTests, TestStoreEffectAlgebraTests |
| IF6-R03 | P1/F3 물별 loading 고착 | FR-007, FR-002 | AC-R003: 완료 경계 재진입·busy·오류·누락 의존성 뒤 loading과 phase가 일치하며, 수락되지 않은 요청이 기존 요청 상태를 훼손하지 않는다. | TrainingRecordsFeatureTests, TrainingRecordsNavigationUITests, 실제 consumer 재현 |
| IF6-R04 | P2/F4 scope 취소 지연 | FR-003, NFR-002 | AC-R004: body가 별도 대기 중이어도 부모 취소가 소유 effect에 전달되고 함수 반환 전 정리되며 형제 작업은 유지된다. | FlowScopeTests, FlowTaskCancellationBoundaryTests |
| IF6-R05 | P2/F5 진단 재활성화 | FR-004, NFR-004 | AC-R005: 완료 후 late send는 기록만 남기며 active 항목을 재생성하지 않고 보관량이 누적되지 않는다. | DispatchDiagnosticsTests |
| IF6-R06 | P2/F6 availability 누락 | FR-006, FR-007 | AC-R006: 유효한 가용성 제한 Output과 생성 helper가 최소 배포 타깃에서 컴파일되고 원래 제한이 유지된다. | macro expansion, OutputCasePathTests, CompileContractTests |
| IF6-R07 | P2/F7 조건부 case 누락 | FR-006, FR-007 | AC-R007: 활성 조건부 case의 helper만 같은 조건에서 생성되고 분기별 타입/충돌/수동 path 규칙이 유지된다. | macro expansion, CompileContractTests, 5 SDK 소비자 fixture |

공통 성공 기준 SC-R001: F1~F7 각각에 수정 전 실패와 수정 후 성공 증거가 있고 미해결 반례가 0건이다. SC-R002: 최종 동일 후보의 필수 검증 게이트가 모두 통과한다. 실행 불가 항목이 있으면 전체 완료로 표시하지 않고 부분 완료와 차단 사유를 분리한다.

## 3. 준비 — 기준선 보존과 실패 테스트 고정

- [x] InnoFlow와 물별 각각의 branch/HEAD/status, tracked diff, 관련 파일과 실제 로컬 의존성 해석 경로를 기록했다.
- [x] Xcode/Swift/SDK/Simulator 목록을 확인하고 빌드마다 전용 DerivedData 또는 scratch 경로와 직렬 job을 사용했다.
- [x] 임시 probe의 반례를 기존 테스트 구성에 옮기고 수정 후 집중·인접·전체 회귀를 순서대로 통과했다.
- [x] 경합 순서를 gate/latch/명시적 이벤트로 고정하고 sleep 기반 성공 판정을 사용하지 않았다.
- [x] hang 경로에 명시적 해제를 두고 Store deinit이나 강제 취소를 정상 완료 증거로 세지 않았다.
- [x] 테스트 전용 public hook이나 새 외부 의존성을 추가하지 않았다.

## 4. R01 — latest 예약 상태 전이 원자성 복구

변경 대상: `Sources/InnoFlowCore/EffectRunScheduler.swift`, 필요 시 `Store+EffectDriver.swift`, `StoreEffectBridge.swift`, `Sources/InnoFlowTesting/TestStore+EffectDriver.swift`; 위 추적표의 scheduler/runtime/FlowTask 테스트.

1. lane 교체와 displaced request 제거를 **suspension 없는 MainActor 상태 변경 구간**에서 완료한다. 이후 gate 거부 및 필요한 비동기 정리를 수행한다.
2. 지연된 attach/finish가 현재 lane을 덮어쓰거나 시작하지 못하도록 token 소유권을 검사한다. 오래된 callback은 자기 request만 정리하며 새 lane을 건드리지 않는다.
3. admission이 먼저 끝나고 attach가 늦는 경우에도 stale ticket의 gate와 dispatch 활동이 정리되는지 검증한다.
4. 기존 latest 취소·stale emission 차단, serial FIFO, 정책 충돌 의미를 유지한다. merge 형제의 실행 순서를 숫자 순서라고 가정하지 않는다.

필수 테스트: 동일 ID의 3개 merge, 독립 dispatch의 3-way 재진입, 서로 다른 lane 독립성, 교체와 cancel 교차, stale attach/finish, typed output/captured stream 종료. 마지막에는 scheduler request 수 0, 실제 handle 완료, 중복 출력/잘못된 상태 변경 0을 확인한다. Store/TestStore 양쪽을 검증한다.

## 5. R02 — 상속 cancellation ID와 예약 수명 연결

변경 대상: `EffectRunScheduler.swift`, `EffectExecutionContext.swift`, `Store+EffectDriver.swift`, `StoreEffectBridge.swift`, `TestStore+EffectDriver.swift`, `TestStore+EffectLifecycle.swift`. public 시그니처 변경 없이 공통 scheduler의 내부 예약 문맥에 필요한 ID 정보를 전달한다.

1. request에 lane ID와 상속된 cancellation IDs를 함께 연결한다. ID→token 역인덱스를 두어 lane 전체가 아닌 해당 예약을 찾는다.
2. pending 취소는 request/pending/인덱스를 먼저 제거한 뒤 gate와 wrapper를 정리한다. 제거된 노드는 즉시 대기 용량에서 제외한다.
3. running serial/drop 취소는 취소를 요청하되 **operation의 실제 반환까지 슬롯을 유지**한다. 이후 finish에서 인덱스와 lane을 정확히 정리한다.
4. sequence cutoff를 유지해 오래된 취소가 같은 ID의 새 요청을 취소하지 못하게 한다. finish/교체/deinit/정책 거절도 같은 인덱스 정리 계약을 따른다.
5. Store와 TestStore의 wrapper 소유권 차이로 의미가 달라지지 않게 취소 판정은 공통화한다. 테스트 전용 즉시 취소 우회로로 가리지 않는다.

필수 테스트: 첫 run을 계속 막아 둔 상태에서 두 번째 pending 취소·handle 완료·세 번째 수락, 중첩 ID, typed ID 독립성, 같은 ID 재사용/오래된 sequence, attach 전 취소, running 취소 후 비중첩, output/concatenate 완료. AC-R002가 통과하기 전 R03으로 넘어가지 않는다.

## 6. R03 — 물별 기록 조회의 admission·상태 소유권 일치

변경 대상:

- [TrainingRecordsFeature.swift](/Users/changwooson/Developer/InnoSquad/Projects/Mulbyul/Apple/Features/TrainingRecords/UIs/Shared/TrainingRecordsFeature.swift)
- [TrainingRecordsFeatureTests.swift](/Users/changwooson/Developer/InnoSquad/Projects/Mulbyul/Apple/Features/TrainingRecords/Tests/TrainingRecordsFeatureTests.swift)
- [TrainingRecordsNavigationUITests.swift](/Users/changwooson/Developer/InnoSquad/Projects/Mulbyul/Apple/App/UITests/Sources/TrainingRecordsNavigationUITests.swift)

1. 요청 Action 수신과 실제 admission 수락을 구분한다. `.onAppear`만으로 loading/phase를 먼저 켜지 않고 **수락된 조회**가 loading을 소유하도록 한다.
2. 필요한 내부 요청 ID를 admission/완료/실패에 함께 전달하고 오래된 결과가 새 소유자를 덮지 않게 한다. 거절된 요청의 ID를 현재 실행 소유자로 교체하지 않는다.
3. PhaseMap도 admission 및 결과 Action에 맞춰 전이한다. reducer에서 phase를 직접 고치지 않는다. busy는 이미 완료된 loaded/failed 상태 또는 여전히 진행 중인 기존 loading을 그대로 유지한다.
4. 누락 의존성, 기타 admission 거절, 실패, 취소 경계의 표시를 명시한다. 새 자동 재시도나 queue 정책으로 바꾸지 않는다. busy 요청은 현재 drop 정책대로 버려지며, 슬롯 해제 후 사용자의 다음 요청은 정상 수락돼야 한다.
5. 실제 기록 조회 소스를 사용하는 이전 onChange 재진입 반례를 회귀 테스트로 보존한다. 동일한 busy/loading 가정이 있는 `TrainingRoutineEditorFeature`는 인접 회귀 대상으로 확인하되, 다른 제품 동작 변경은 묵시적으로 확대하지 않는다.

필수 테스트: 즉시 성공/지연 성공/빈 목록/실패/의존성 없음, 진행 중 연속 요청, 성공·실패 직후 재진입, 오래된 admission/완료, 화면 이탈과 복귀. state.isLoading와 PhaseMap 결과를 함께 검사한다. 가짜 repository의 실행 횟수로 중복 호출과 조용히 유실된 수락 요청도 확인한다. 실제 iOS/macOS UI 검증에서는 재진입·기록 표시·오류 후 재요청을 별도로 기록한다.

## 7. R04 — 부모 취소를 scope 정리와 연결

변경 대상: `Sources/InnoFlowCore/FlowScope.swift`, `Tests/InnoFlowTests/FlowScopeTests.swift`, 관련 FlowTask 경계 테스트.

1. `withFlowScope`의 부모 cancellation handler가 body 반환과 독립적으로 소유 dispatch 취소를 요청하도록 한다.
2. nonisolated cancellation callback→MainActor 전달을 안전하게 구성한다. 전달용 task를 쓰면 scope가 수명을 소유하고 정상/오류 반환 경로에서 정리를 합류한다. fire-and-forget 정리가 남지 않게 한다.
3. 취소 신호와 track의 교차를 처리한다. 이미 취소된 호출자, 취소와 동시에 등록된 task, 닫힌 scope에 늦게 등록된 task를 빠뜨리지 않는다.
4. 기존 `rethrows` 계약과 결과/오류를 유지한다. 중복 close는 안전하며 완료한 task를 뒤늦게 cancelled로 바꾸지 않는다.

필수 테스트: body는 별도 task.value에서 계속 대기하지만 소유 effect는 취소 신호를 받음, body 해제 후 모든 join 완료, 정상/throw/선행 취소/동시 close/late track, 형제 scope와 untracked 작업 유지, OutputFlowTask 취소·종료. 비협조적인 body 자체의 강제 종료를 성공 기준으로 삼지 않는다.

## 8. R05 — 진단의 완료 수명과 late event 분리

변경 대상: `Sources/InnoFlowCore/StoreDiagnostics.swift`, 필요 시 진단 호출 지점, `Tests/InnoFlowTests/DispatchDiagnosticsTests.swift`.

1. active 상태 생성은 유효한 시작 이벤트로 제한한다. 없는 dispatch에 late actionDropped 등을 기록해도 active를 만들지 않는다.
2. 활성 dispatch의 counter 갱신과 종료 후 history 기록을 분리한다. 중복/늦은 종료 이벤트도 안전하게 처리한다.
3. payload 비저장·옵트인 계약을 유지한다. 해결책으로 종료 ID를 영구 보관하는 tombstone 집합을 추가하지 않는다.

필수 테스트: 정상 finish와 취소 finish 후 saved Send, 중복 late callback, history capacity 0/1/N, 기존 활성 요청과 late 이벤트 혼합, snapshot 표시 제한과 내부 저장량 구분. history 용량보다 많은 완료 요청을 반복한 뒤 active 0 및 각 저장 구조의 비누적을 확인한다. 반복은 용량 경계 검사이며 타이밍 경합의 유일한 증거로 사용하지 않는다.

## 9. R06 — Output CasePath의 availability 보존

변경 대상: `Sources/InnoFlowMacros/InnoFlowMacro+OutputPathSynthesis.swift`, `Tests/InnoFlowMacrosTests/InnoFlowMacrosTests.swift`, `Tests/InnoFlowTests/OutputCasePathTests.swift`, `CompileContractTests.swift`.

1. case element만 넘기는 생성 경로에 부모 case 선언의 availability 정보를 전달한다. 관련 attribute만 전달하며 ignore marker 등 매크로 제어 attribute를 무조건 복사하지 않는다.
2. static let 경로와 generic computed property 경로, identity marker 등 보조 선언의 유효한 가용성 문맥을 보존한다.
3. 유효한 introduced/deprecated/obsoleted/unavailable 선언의 처리 계약을 컴파일러 대조군으로 확정한다. 최신 API를 일반 타깃에서 무조건 사용 가능하게 만드는 방향으로 우회하지 않는다.

필수 테스트: payload 없는 신규 OS case, 부모 enum 가용성, 여러 availability attribute, public/package/generic Output, 접근 허용 문맥의 성공과 금지 문맥의 의도된 실패. 매크로 expansion 문자열 비교만으로 끝내지 않고 실제 최소 배포 타깃 소비자 컴파일로 확인한다. Swift 언어 자체가 허용하지 않는 enum 선언은 매크로 회귀 실패로 세지 않는다.

## 10. R07 — 조건부 Output case 생성과 충돌 검사 보완

변경 대상: R06과 같은 Output 생성기·macro/compile contract 테스트, 필요 시 조건부 member 수집 내부 helper.

1. IfConfigDeclSyntax를 재귀 순회하고 생성 선언을 원본과 같은 `#if/#elseif/#else` 조건 안에 둔다. 현재 호스트의 조건을 수동 평가해 한 분기만 평탄화하지 않는다.
2. 이름 수집/수동 path 감지/ignore/충돌 검사에도 조건 문맥을 반영한다. 상호 배타적인 분기의 같은 helper 이름을 거짓 충돌로 처리하지 않고, 같은 활성 문맥의 실제 충돌은 진단한다.
3. R06 availability 정보를 조건부 case에서도 유지한다. generic marker와 플랫폼 전용 payload 타입이 조건 밖으로 새지 않게 한다.

필수 테스트: macOS/iOS 및 나머지 지원 플랫폼 분기, 중첩 조건, 사용자 `-D` flag의 on/off, 비활성 분기에만 존재하는 타입, 서로 배타적인 동명 case, 수동 helper/ignore, 활성 분기의 실제 충돌, availability와 조건문의 조합. Action 생성기를 전면 재작성하는 별도 확장은 하지 않으며 공유 helper 변경이 Action 동작에 영향을 주면 기존 Action suite를 회귀 검증한다.

## 11. 최종 통합 검증과 후보 식별

각 단계의 테스트 통과만으로 최종 완료하지 않는다. 수정이 끝난 하나의 working-tree snapshot에 다음 증거를 연결한다.

| 게이트 | 실행 범위 | 통과 기준 |
| --- | --- | --- |
| G1 계약·정적 검사 | format lint, diff check, `scripts/principle-gates.sh --static`, 문서/매크로/샘플 계약 | 위반 0. 필요한 계약 변경은 CLAUDE/ADR/문서/테스트/CI에 함께 반영 |
| G2 전체 테스트 | `swift test --jobs 1 --no-parallel -Xswiftc -warnings-as-errors`와 같은 명령의 `-c release` 실행, 샘플 패키지 테스트 | 기존/신규 실패 0, 테스트 수와 로그 기록 |
| G3 메모리·동시성 | TSan/ASan을 별도 빌드 경로로 순차 실행, 신규 scheduler/scope/diagnostics 회귀 포함 | 미해결 sanitizer 보고 0, timeout으로 종료된 테스트 없음 |
| G4 툴체인·플랫폼 | 실제 가용한 최소 지원 toolchain과 현재 toolchain, `InnoFlow-Package`의 iOS/macOS/tvOS/watchOS/visionOS 빌드 | 최소 OS를 유지한 컴파일 성공, 버전/SDK/target/로그 기록 |
| G5 매크로 소비자 | R06/R07의 최소 배포 타깃 compile fixture, 5 SDK 활성 분기, plugin-free Core 계약 | 허용 선언 성공·금지 선언 의도된 진단, Core에 매크로 의존성 없음 |
| G6 물별 통합 | 실제 후보를 해석하도록 한 비커밋 로컬 검증 설정으로 feature 테스트와 iOS/macOS UI 실행 | loading/phase 일치, 연속 요청/재진입/오류 복구 성공, 실행한 화면/플랫폼 증거 |
| G7 배포 준비 문서 | 기존 release/API compatibility gates, 품질 검토·기존 구현 계획·수정 계획의 증거 대조 | 후보 hash·consumer 소스/해석 경로·의존성·실행일 일치, F1~F7 미해결 0 |

실행 중 테스트를 위해 원본 Package.resolved나 물별의 배포용 의존성 선언을 영구 변경하지 않는다. 현재 로컬 검증 절차를 먼저 재사용하고, 필요하면 별도 임시 검증 복사본/override에 후보를 연결한 뒤 실제 resolution을 기록한다. 소스를 재구현한 가짜 consumer만으로 G6를 통과시키지 않는다.

최신 SDK로 최소 OS 타깃을 빌드한 결과는 구형 OS 실제 런타임 실행과 다르다. 설치 가능한 runtime과 실제 기기 범위를 먼저 확인하고, 사용할 수 없는 최소 OS/기기 검증은 미검증으로 남긴다. 지원 최소 Swift toolchain을 사용할 수 없으면 현재 toolchain 통과만으로 그 호환성을 완료 처리하지 않는다.

현재 `.github/workflows/ci.yml`의 tests/TSan/ASan/package-build/consumer 관련 job에 새 회귀가 실제 포함되는지 확인한다. 로컬 계획 실행에서 원격 CI의 성공이나 공개 배포 완료를 대신 주장하지 않는다.

## 12. 문서 갱신·검토·중단 조건

- 각 수정의 로그/테스트 이름/변경 파일/잔여 사항을 해당 IF6-R 행에 연결한다. 이전 검토의 실패 근거를 지우지 않고 수정 후 증거를 추가한다.
- `docs/QUALITY_REVIEW_6_0.md`, 기존 구현 계획, 실행 정책 ADR, 필요한 DocC/매크로 운영 문서를 실제 결과에 맞춰 갱신한다. 구현이 끝났다는 이유만으로 이 Draft 문서의 상태를 Reviewed/Approved로 자동 승격하지 않는다.
- 최종 검토에서 **기준을 모두 충족하는 것처럼 보이지만 사용자 의도를 위반하는 반례**를 다시 찾는다. 예: Store deinit으로 finish 통과시키기, 취소 플래그만 켜고 큐 잔류시키기, busy마다 loading을 끄기, active 표시만 잘라 내부 누적 숨기기, 호스트 분기만 컴파일하기. 발견하면 AC 보완 후 다시 검증한다.
- 기존 파일의 다른 작업과 겹쳐 안전하게 분리할 수 없으면 해당 항목을 멈추고 정확한 충돌을 보고한다. 관련 없는 선행 빌드 실패를 무시하거나 이번 수정 성공으로 계산하지 않는다.
- 미확정 기술 선택(취소 bridge 구현, 조건부 충돌 문맥 표현)은 구현 담당이 위 AC로 비교해 결정하고 ADR에 근거를 남긴다. 외부 환경/실기기 가용성은 실행 시작 시 확인하고 사용자 조치가 필요한 경우에만 별도 요청한다.
- 완료 보고에는 수정 7건의 결과, 최종 검증 수/로그, 후보 식별자, 실제 검증 플랫폼, 남은 외부 게이트를 구분한다. 기능 확장이나 원격 게시 없이 **로컬 수정·검증 완료 여부**를 먼저 판정한다.

## 13. 2026-09-06 실행 결과

| 작업 | 결과 | 고정된 회귀 증거 |
| --- | --- | --- |
| R01 | 완료 | Store/TestStore의 3-way `latest`가 stale attach/finish에도 예약을 고립시키지 않고 종료한다. |
| R02 | 완료 | 상속 cancellation ID로 pending을 제거하면 즉시 용량이 반환되고 running serial/drop의 물리 슬롯은 실제 반환까지 유지된다. |
| R03 | 완료 | 물별 TrainingRecords의 admission request ID가 loading/phase를 소유하며 busy·stale completion·`onChange` 재진입이 새 상태를 덮지 않는다. |
| R04 | 완료 | caller 취소가 별도 body 대기 중에도 scope 소유 작업에 전달되고 반환 경로는 동일 close 상태를 join한다. |
| R05 | 완료 | 종료 뒤 late nonterminal 진단은 history에만 남고 active dispatch를 재생성하지 않는다. |
| R06 | 완료 | Output helper가 `@available`을 보존하며 실제 외부 package compile contract를 통과한다. |
| R07 | 완료 | 중첩 `#if/#elseif/#else`를 재귀적으로 반영하고 상호 배타적 동명 case와 실제 충돌을 구분한다. |

최종 동일 소스 후보에서 format lint, diff check, static/full principle gate,
Debug/Release 각 707 runtime + 65 macro tests, TSan, ASan, sample 43 tests,
5개 Apple SDK build, 외부 package compile contract, 물별 TrainingRecords
feature tests와 실제 iOS UI 시나리오를 실행했다. 상세 로그·플랫폼 및 미검증
경계는 `docs/QUALITY_REVIEW_6_0.md`에 기록한다.

로컬 수정·검증은 완료했다. 공개 6.0.0 baseline tag가 아직 없으므로 API
compatibility gate는 의도대로 staged이며, remote CI·commit·push·tag·release와
최소 OS 실기기 조합은 수행하지 않았다. 이는 로컬 수정 실패가 아니라 별도
권한·환경이 필요한 외부 release gate다.
