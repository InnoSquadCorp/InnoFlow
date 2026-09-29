# InnoFlow 6.0.0 — 취소·진단·매크로 계약 후속 수정 계획

- 문서 상태: **Draft**, 작성일 2026-09-07, 실행 기록 갱신 2026-09-08.
- 구현 상태: **R16~R22 구현·집중 검증 통과, R23 실패·열림, R24 부분 통과**. 전체 로컬 검증 상태: **미완료**.
- 결정권자: 프로젝트 소유자. 구현 담당: 후속 실행 담당자. 리뷰 담당자·승인일: 미기록.
- 근거: [2026-09-07 재검토 보고서](/tmp/innoflow-followup-review-20260907.RQym7k/REVIEW.md)의 F1~F7 및 G1~G2. 이 문서의 발견 번호는 해당 보고서에 한정한다.
- 관계: [기존 구현 계획](IMPLEMENTATION_PLAN_6_0.md)의 FR-001~007/NFR-001~005와 [첫 후속 계획](REMEDIATION_FOLLOWUP_PLAN_6_0.md)의 FR-008을 유지한다. 이전 IF6-R01~R15는 재번호 부여하지 않으며 새 작업은 **IF6-R16~R24**다.
- 현재 판정: 기존 통과 이력은 보존하지만, 새 반례와 미실행 필수 검증이 있으므로 이전의 “로컬 구현 및 검증 완료”를 현재 상태로 사용하지 않는다.

## 1. 목표, 사실, 범위

목표는 기존 6.0 기능을 더 늘리는 것이 아니라 약속한 취소·상태 복구·대기 진단·조건부 합성 계약을 실제 소비자와 지원 환경에서 충족하는 것이다. 주요 사용자는 InnoFlow를 사용하는 개발자와 물별 기록을 조회·재시도·편집하는 사용자다.

### 확인한 사실

- 직전 검토는 새 결함 6건과 기존 직접 취소 반례의 미해결 1건을 재현했다. 기존 집중 테스트 51개와 관련 macro 테스트 1개가 통과해도 이 반례들은 실패한다.
- InnoFlow 기준은 `release/6.0.0-local`, HEAD `00a73ed2d2cb94114b0be5c9fbd59c187a4b67c7`와 미커밋 변경이다. 물별 기준은 `main`, HEAD `092ff9514695ceae5cfd490388e017fac331e30a`와 미커밋 변경이다.
- 직전 검토의 237개 파일 manifest는 SHA-256 `69ebfde89345b4f21df0f9c16e66ebb34d3a1c38c578981542837ffeafb152d5`이며 당시 현재 파일과 불일치가 없었다. 구현 시작 때 다시 확인한다. 이 해시는 저장소 전체나 배포 SHA가 아니다.
- 계획 작성 시작 시 Git 상태 항목은 InnoFlow 154개, 물별 24개다. 기존 작업을 보존한다.
- [Package.swift](/Users/changwooson/Developer/InnoSquad/InnoFlow/Package.swift)는 Swift tools 6.3, iOS 18/macOS 15/tvOS 18/watchOS 11/visionOS 2를 선언한다. [물별 Package.swift](/Users/changwooson/Developer/InnoSquad/Projects/Mulbyul/Apple/Package.swift)는 로컬 InnoFlow 경로를 사용한다.
- 직전 검토 환경은 Swift 6.4/Xcode 27이다. 설치 runtime 목록에는 iOS/tvOS 18.5, watchOS 11.5, visionOS 2.5 및 각각 27.0이 있었다. 목록 존재와 실행 가능성·합격은 다르다. 정확한 Swift 6.3 실행 증거는 없다.
- 이번 계획 작성에서는 테스트·UI를 재실행하지 않았다. 위 실행 결과는 링크된 직전 검토의 기록이다.

### 작업 범위와 제약

포함: InnoFlow Core/Testing/Output 매크로, 관련 회귀·CI·검증 스크립트·계약 문서, 물별 Apple TrainingRecords 조회 수명/상태 및 직접 관련 접근성·UI 테스트.

제외: 새 제품 기능, 새 실행 정책, 데이터 저장 방식·스키마 변경, 다른 프레임워크나 물별 Settings 전체 개선, Kotlin/Android·TypeScript/React 별도 후보 병합, 의존성·최소 OS·Swift 버전 상향. 인접 영역 변경이 필요하면 영향과 승인 필요 여부를 먼저 보고한다.

커밋·푸시·원격 workflow 실행·태그·서명·공개 배포는 이 계획 작성이나 향후 로컬 구현의 자동 승인 범위가 아니다. 검증 실패를 피하려고 테스트/플랫폼을 제거하거나 macro trust·sandbox 보안을 낮추지 않는다.

## 2. 작업 순서와 추적표

실행 순서는 **준비 → R16 → R17 → R18 → R19 → R20 → R21 → R22 → R23 → R24**다. 각 단계는 실패 회귀 편입, 구현, 집중 검증, 영향 검증, 문서 기록 순서로 진행한다. 단계를 넘어가더라도 선행 단계의 열린 검증은 완료로 바꾸지 않는다.

| 작업 | 발견 / 기존 요구 | 추가 완료 기준 | 필수 검증 증거 |
| --- | --- | --- | --- |
| IF6-R16 | F1 / FR-003,007, AC-R008 | AC-R016: 실제 앱 owner가 제공하는 핸들 취소·caller 취소·화면 이탈 뒤 정리까지 await 가능하고 이전 종료가 새 요청을 지우지 않는다. | owner/feature 통합, 직접 취소 및 caller 취소 후 재조회 |
| IF6-R17 | F2 / FR-002,003,007, AC-R008 | AC-R017: 같은 요청의 queued→started가 이전 확정 상태를 덮어쓰지 않고 취소 시 idle/loaded/failed를 정확히 복원한다. | 세 초기 상태 × queued/started 취소 및 실제 Store 전이 |
| IF6-R18 | F3 / FR-004, NFR-004, AC-R013 | AC-R018: 다른 lane·dispatch의 시작/취소와 무관하게 scheduled request별 실제 pending과 진단 수치가 일치한다. | token별 집계, sibling 생존 중 검증, 해제/반복 회귀 |
| IF6-R19 | F4 / FR-006,007, AC-R010 | AC-R019: !/&&/||/괄호의 의미를 보존해 수동 helper 조건의 여집합에서 canonical helper를 제공한다. | 2개 flag 전 4조합, bounded 3개 flag 전 8조합, 실제 compiler 대조 |
| IF6-R20 | F5 / FR-006,007, AC-R009 | AC-R020: 동치·배타 조건에는 거짓 오류가 없고 실제 동시 활성 충돌은 계속 컴파일 실패한다. | 괄호/독립/중첩 조건 성공군과 활성 충돌 실패군 |
| IF6-R21 | F6 / FR-006,007, AC-R012 | AC-R021: 가용성 키워드와 문자열을 구분해 유효한 case/helper를 보존하고 실제 금지 사용은 거절한다. | message/renamed/인수 순서/플랫폼 가용성 compiler 대조 |
| IF6-R22 | F7 / FR-006,007, AC-R011 | AC-R022: 조건부 availability와 opt-out 범위를 구분하며 제어 attribute를 generated property에 복제하지 않는다. | 혼합 attribute/flag on·off/public·package·generic |
| IF6-R23 | G1 / FR-008,007, AC-R014 | AC-R023: 지정 대비 5건과 44pt 조작 검증을 대상 issue 마스킹 없이 수행하고 관련 VoiceOver/표시 환경 증거를 확보한다. | 대상 전용 audit, 실제 완전 노출·조작·읽기 순서 |
| IF6-R24 | G2 / FR-001,007, NFR-005, AC-R015 | AC-R024: 최종 후보의 필수 검증과 결과가 연결되고 실패·미실행·skip은 완료로 승격되지 않는다. | 재현 가능한 matrix·manifest·로그, 보고 상태 일치 |

새 성공 기준:

- **SC-FU004:** F1~F7 모두 원인에 맞는 실패 증거와 정식 회귀가 있고, 수정 후 실제 소비자 경로에서 통과한다. F1은 아래에서 구분하는 앱 owner 계약을 대상으로 하며 raw FlowTask rollback을 새 계약으로 만들지 않는다.
- **SC-FU005:** R19~R22는 snapshot만이 아니라 plain/매크로 소비자의 허용·금지 compiler 결과를 보유한다. 단순한 nonzero exit를 합격으로 세지 않고 의도한 진단을 확인한다.
- **SC-FU006:** 대상 접근성 경고를 무시하지 않는 R23 결과와 R24의 모든 필수 행이 같은 최종 후보에 연결돼야 전체 로컬 검증 완료다. 미실행은 0점도 합격도 아닌 열린 gate다.

## 3. 준비 — 이력 보존과 재현 기반

- [ ] branch/HEAD/status, 실제 물별 의존성 해석 경로, Swift/Xcode/SDK/runtime·여유 디스크를 기록한다. 저장소 이름·오래된 build cache만으로 후보를 판단하지 않는다.
- [ ] 직전 임시 probe의 최소 재현을 정식 테스트 fixture로 옮긴다. `/tmp` 파일을 CI 입력이나 유일한 회귀 근거로 두지 않는다.
- [ ] F1의 raw 호출 반례와 실제 앱 owner의 계약 테스트를 분리한다. F2/F3는 명시적 signal로 작업 순서를 고정한다. 실제 runtime 도달 경로가 입증되지 않은 stale-admission 수동 주입은 보조 테스트이지 제품 결함 증거로 세지 않는다.
- [ ] F4~F7 plain 선언이 먼저 컴파일되는지 확인한다. Swift 언어가 금지한 선언, plugin 로딩/툴체인 오류, 의도한 합성 오류를 구분한다.
- [ ] build/test 경로를 툴체인·구성·플랫폼별로 분리한다. 무거운 빌드는 jobs 1 기준으로 실행하고 다른 작업의 활성 build/cache를 지우지 않는다.
- [ ] 이후 각 단계의 결과 표를 `미착수/진행 중/수정 완료·검증 대기/검증 통과/실패/환경 대기`로 기록한다. 문서 리뷰 상태 Draft/Reviewed/Approved와 혼용하지 않는다.

## 4. R16 — 조회 owner의 종료·취소 계약 완성

변경 대상:

- 신규 후보: `/Users/changwooson/Developer/InnoSquad/Projects/Mulbyul/Apple/Features/TrainingRecords/UIs/Shared/TrainingRecordsLoadLifecycle.swift`
- [TrainingRecordsFeature.swift](/Users/changwooson/Developer/InnoSquad/Projects/Mulbyul/Apple/Features/TrainingRecords/UIs/Shared/TrainingRecordsFeature.swift)
- [iOS scene](/Users/changwooson/Developer/InnoSquad/Projects/Mulbyul/Apple/Features/TrainingRecords/UIs/iOS/TrainingRecordsCurrentExperienceScene.swift), [shared scene](/Users/changwooson/Developer/InnoSquad/Projects/Mulbyul/Apple/Features/TrainingRecords/UIs/Shared/TrainingRecordsScene.swift)
- [feature tests](/Users/changwooson/Developer/InnoSquad/Projects/Mulbyul/Apple/Features/TrainingRecords/Tests/TrainingRecordsFeatureTests.swift), 신규 owner tests, [navigation UI tests](/Users/changwooson/Developer/InnoSquad/Projects/Mulbyul/Apple/App/UITests/Sources/TrainingRecordsNavigationUITests.swift)

설계안은 **앱 내부 MainActor owner + await 가능한 소유 요청 핸들**이다. 기존 raw FlowTask와 domain rollback을 결합하는 프레임워크 변경안은 제외한다. 단순 onDisappear 정리만으로 유지하는 안은 caller/직접 핸들 취소를 커버하지 못한다.

1. 최초 로드·재시도·저장/삭제 후 갱신 등 실제 조회 호출부를 조사하고 하나의 owner 경로로 모은다. repository 호출과 business state는 계속 reducer에 둔다.
2. owner가 요청 ID, 내부 FlowTask, 종료 관찰과 정리 작업을 소유한다. 호출자에게 raw FlowTask를 정리 책임 없이 노출하지 않는다. 실제 사용 가능한 surface와 테스트가 같은 경로를 사용해야 한다.
3. 직접 취소·caller 취소·화면 이탈은 해당 ID의 물리 작업에 취소를 전달하고, 살아 있는 owner가 새 root 정리 action을 보낸다. UI 상태 복구는 비협조적 repository의 실제 반환까지 늦추지 않는다.
4. `finish/close`에 해당하는 awaitable 경계는 실제 작업 종료와 정리 action 처리 **둘 다** 기다린다. 중복 취소/종료는 같은 정리 작업에 합류하고, 취소된 caller가 정리 작업 자체를 다시 취소하지 않게 한다. MainActor를 막는 대기는 금지한다.
5. 정상 완료에도 owner의 완료 핸들을 해제한다. 이전 요청의 observer/cleanup이 새 owner를 비우지 못하도록 ID를 재확인한다. 임시 Task를 쓸 경우 명시적으로 보관·join·제거하며 deinit의 비동기 정리에만 의존하지 않는다.
6. 화면 이탈은 취소를 시작하는 동기 bridge가 될 수 있지만, 그 bridge가 작업 종료 완료를 뜻하지 않게 한다. 관찰/정리가 화면 수명보다 길어져도 Store·뷰를 불필요하게 순환 보관하지 않는지 검증한다.

필수 회귀: 실행 전/중/대기 중 취소, 직접 소유 핸들 취소, finish를 기다리는 caller 취소, 성공/실패 종료, 종료 직후 재시도, 빠른 3회 교체, 중복 close, stale cleanup, 무의존성, sibling 저장/조회 생존, owner 해제. 종료 후 loading/request ID가 없고 재조회가 실제 repository에 도달해야 한다.

**계약 주의:** 앱 owner를 우회한 raw `store.send(...).cancel()`은 원래 state rollback을 보장하지 않는다. raw 대조군이 자동 복구된다고 주장하지 않는다. 이 점은 기존 요구를 축소하는 대신 호출부를 실제 소유 경로로 전환하고 그 경로를 증명하는 것으로 해결한다. 소유권 범위를 확대해야 한다면 구현 전에 결정권자에게 경계를 제시한다.

## 5. R17 — 취소 복구 스냅샷의 요청별 보존

변경 대상은 R16의 feature/state, PhaseMap 연결, feature/owner tests다.

1. 최초 `.queued` 또는 최초 `.started`에서만 이전 `hasLoaded/didFailToLoad`를 저장한다. 같은 ID의 queued→started는 저장된 스냅샷을 유지한다.
2. 확정 표시 상태와 일시적인 loading 표시를 분리한다. 작은 내부 snapshot 값으로 묶는 안을 우선 검토하되 불필요한 public API는 추가하지 않는다.
3. 성공/실패/취소/거절의 terminal 처리를 ID 기준으로 통일한다. 무조건적인 새 admission 덮어쓰기나 stale completion 적용을 막는다. phase 변경은 PhaseMap이 계속 소유한다.
4. 선행 비협조적 작업이 반환되기 전에는 새 물리 작업을 시작하지 않으며 후속 요청을 유실하지 않는다.

필수 회귀: 초기 idle/loaded/failed × 직접 started/queued→started × queued 취소/실행 중 취소, 기존 logs 보존, 동일 admission 중복, 다른 ID의 늦은 이벤트. F2의 실제 Store 재현에서 `failed → queued → started → cancel → failed`를 검증한다. R16/R17을 합쳐 기존 AC-R008을 다시 닫는다.

## 6. R18 — scheduled token 기준 진단 집계

변경 대상:

- [EffectRunScheduler.swift](/Users/changwooson/Developer/InnoSquad/InnoFlow/Sources/InnoFlowCore/EffectRunScheduler.swift)
- [Store+EffectDriver.swift](/Users/changwooson/Developer/InnoSquad/InnoFlow/Sources/InnoFlowCore/Store+EffectDriver.swift), [StoreDiagnostics.swift](/Users/changwooson/Developer/InnoSquad/InnoFlow/Sources/InnoFlowCore/StoreDiagnostics.swift)
- [TestStore scheduler adapter](/Users/changwooson/Developer/InnoSquad/InnoFlow/Sources/InnoFlowTesting/TestStore+EffectRunScheduler.swift)
- [DispatchDiagnosticsTests.swift](/Users/changwooson/Developer/InnoSquad/InnoFlow/Tests/InnoFlowTests/DispatchDiagnosticsTests.swift), [EffectRunSchedulerTests.swift](/Users/changwooson/Developer/InnoSquad/InnoFlow/Tests/InnoFlowTests/EffectRunSchedulerTests.swift)

1. pending 진입/시작/취소/교체/종료 callback에 같은 scheduled token을 연결한다. 물리 run token과 dispatch ID는 대체 식별자로 사용하지 않는다.
2. diagnostics는 live queued token 집합 또는 동등한 멱등 상태를 기준으로 count를 산출한다. 단순 dispatch 정수 증감은 같은 dispatch의 여러 lane을 구분하지 못하므로 유지하지 않는다.
3. 실제 queued였던 token만 started에서 제거한다. 즉시 started인 sibling은 다른 pending 수치를 건드리지 않는다. 중복 callback, late callback은 no-op이며 종료 dispatch를 재생성하지 않는다.
4. pending 취소·상속 effect ID 취소·cancelAll·Store 해제에서 보관 구조를 정리한다. 종료 token tombstone을 무한 보관하지 않는다. diagnostics 비활성 시 진단용 보관 비용을 만들지 않는다.
5. 공개 diagnostic enum 확장 없이 package 내부 경로를 우선한다. 공개 호환성 변경이 불가피하면 별도 검토 후 결정한다. Store/TestStore의 실제 scheduler 의미는 동일하게 유지한다.

필수 회귀: F3 그대로 재현, pending 둘 중 하나 취소, 여러 lane/dispatch/Store, started→cancel 및 cancel→started, 중복 통지, history capacity 0/1/N, sibling 생존 중 실제 pending과 snapshot 대조, 1,000회 유한 반복 후 live 저장 구조 기준선 복귀. 해당 경계에 TSan/ASan을 적용한다.

## 7. R19 — 복합 조건의 의미 보존

변경 대상은 [Output 합성기](/Users/changwooson/Developer/InnoSquad/InnoFlow/Sources/InnoFlowMacros/InnoFlowMacro+OutputPathSynthesis.swift), 신규 작은 조건 표현 helper, [macro tests](/Users/changwooson/Developer/InnoSquad/InnoFlow/Tests/InnoFlowMacrosTests/InnoFlowMacrosTests.swift), [compile contracts](/Users/changwooson/Developer/InnoSquad/InnoFlow/Tests/InnoFlowTests/CompileContractTests.swift)와 신규 fixture다.

1. SwiftSyntax의 조건 expression tree에서 괄호, prefix not, and/or의 범위를 구분한다. 문자열 맨 앞 `!`를 잘라 전체 식의 부정으로 바꾸지 않는다.
2. 원래 조건 source를 보존하고 필요한 경우 `!(원래 전체 식)`처럼 명시적인 괄호로 여집합을 만든다. 단순 문자열 조작안 대신 작은 내부 조건 표현을 사용하되 범용 SAT solver나 새 외부 의존성은 도입하지 않는다.
3. manual helper 여러 개가 커버하는 조건의 합집합과 자동 생성할 여집합을 같은 표현으로 처리한다. 이름 수집/marker 생성에 적용되는 범위도 일치시킨다.
4. 알려지지 않은 compiler predicate는 원래 source를 가진 atom으로 보존한다. 현재 호스트 결과로 비활성 분기를 제거하지 않는다.

필수 회귀: `!A && B`, `!(A && B)`, `!A || B`, 이중 부정, 괄호·중첩 if/elseif/else, 두 flag 전 4조합. 고정된 작은 3-flag 표현 집합은 전 8조합으로 확장한다. 같은 문법에서 plain 선언과 macro helper round-trip/identity를 비교한다. 내부 parser만의 truth table을 독립 compiler 검증 대신 사용하지 않는다.

## 8. R20 — 배타 조건과 실제 충돌 진단

R19의 조건 helper를 재사용한다. 추가 검증 대상은 [OutputCasePathTests.swift](/Users/changwooson/Developer/InnoSquad/InnoFlow/Tests/InnoFlowTests/OutputCasePathTests.swift)와 macro/compile contracts다.

1. 의미 없는 바깥 괄호를 syntax 기준으로 정규화한다. `P`/`(P)`/`!P`/`!(P)`의 명백한 관계와 상호 배타적 `os(...)` atom을 구분한다. 복합 `os(...) || ...` 전체를 단일 플랫폼 atom으로 오인하지 않는다.
2. 겹침을 확정하지 못했다는 이유만으로 비활성 선언에 무조건 macro 오류를 내지 않는다. 원래 조건 아래 선언을 생성하거나 조건부 진단을 구성해 실제 활성 충돌을 compiler가 거절하게 한다. 구체적인 생성 형태는 작은 compile fixture에서 먼저 확인한다.
3. 충돌 검사를 전부 끄는 해결은 금지한다. 같은 조건의 중복, underscore 정규화 충돌, 기존 static member 및 generic identity marker 충돌을 계속 검증한다.

완료 증거: `os(macOS)`/`!(os(macOS))` 성공, 독립/중첩/elseif 배타 성공, flag on/off 성공, 동시 활성 helper 중복 실패. 하나의 OS에서만 유효한 타입이 다른 플랫폼 생성 코드로 새지 않아야 한다.

## 9. R21 — availability 인수의 구조적 처리

변경 대상은 Output availability 수집 helper와 macro/compile contracts다.

1. SwiftSyntax availability argument의 실제 키워드/플랫폼/버전을 읽는다. 전체 문자열의 `contains("unavailable")` 및 인수 순서에 의존하는 prefix 검색을 제거한다.
2. message/renamed 문자열과 주석은 가용성 조건으로 해석하지 않는다. 원본 attribute의 조건과 의미는 유지한다.
3. introduced/deprecated/unavailable/obsoleted 및 플랫폼별 도메인을 plain compiler 대조군으로 검사한다. 모르는 도메인 때문에 무조건 모든 helper를 제거하지 않는다. 지원 판단이 불명확하면 반례와 함께 명시적 결정 항목으로 남긴다.
4. 현재 문서화된 unavailable 합성 제외 정책은 보존하되, 정상 deprecated case까지 제외하는 과잉 판정을 고친다. Swift 자체가 금지하는 declaration shape와 합성기 결함을 구분한다.

필수 회귀: 설명문에 unavailable 포함/미포함, 유효한 인수 순서 변화, 실제 unavailable, payload 유/무, public/package/generic, 최소 배포 타깃의 허용 사용과 금지 사용. F6는 canonical helper가 존재하고 round-trip이 성공해야 한다.

## 10. R22 — 조건부 attribute와 opt-out 분리

R19의 조건 표현과 R21의 availability 구조를 재사용한다. 변경 대상은 Output 합성기·attribute helper, marker 처리, macro/compile tests다.

1. attribute list의 IfConfig를 재귀 순회해 availability만 필요한 조건 구조와 함께 복사한다. `@available` 문자열이 있으면 블록 전체를 복사하는 방식은 없앤다.
2. `@InnoFlowCasePathIgnored`는 선언 복사용 attribute가 아니라 해당 조건에서 합성을 억제하는 제어 정보로 처리한다. 조건부 ignore의 밖에서는 정상 자동 helper를 제공한다.
3. manual helper, ignore, unavailable이 함께 존재할 때 각 제외 조건의 합집합 밖에서만 생성한다. ignore된 조건에서 property나 identity marker에 제어 attribute가 붙지 않게 한다.
4. 공유 코드를 바꾸면 Action macro 진단/기존 opt-out 회귀도 확인한다. Action의 무관한 authoring 정책을 바꾸지 않는다.

필수 회귀: F7의 payload 없는 유효 case, availability+ignore 혼합, ignore-only 조건부 블록, 중첩/elseif, 수동 helper와 조합, flag on/off, 접근 수준·generic. 허용 조건의 helper는 사용 가능하고 제외 조건은 생성되지 않아야 한다. negative fixture는 예상한 `no member` 등 해당 계약 진단으로 실패하는지 확인한다.

## 11. R23 — 접근성 검증의 마스킹 제거와 실제 흐름 확인

변경 대상:

- [AccessibilityAuditUITests.swift](/Users/changwooson/Developer/InnoSquad/Projects/Mulbyul/Apple/App/UITests/Sources/AccessibilityAuditUITests.swift), 신규 대상 전용 audit fixture/테스트
- [TrainingRecordsNavigationUITests.swift](/Users/changwooson/Developer/InnoSquad/Projects/Mulbyul/Apple/App/UITests/Sources/TrainingRecordsNavigationUITests.swift)
- [TrainingRecords QA 문서](/Users/changwooson/Developer/InnoSquad/Projects/Mulbyul/Apple/docs/TRAINING_RECORDS_QA.md)
- 실제 실패를 재현한 경우에만 관련 TrainingRecords 화면/semantic text 사용부

1. root `100%`, row `01:30`, row `4/4`, detail summary `4/4`, set status `성공`과 More/편집 Save를 안정된 식별자로 추적한다. 각 항목의 실제 포함 화면과 검사 결과를 별도로 기록한다.
2. 새 clipped-status contrast 제외 규칙으로 대상 완료를 판정하지 않는다. 대상만 검사하는 경로에서는 기존 identifier/nil allowance를 포함해 대상 issue가 무시되지 않도록 한다. 무관한 화면의 기존 예외를 일괄 삭제하지 않는다.
3. 대상 텍스트가 scroll viewport와 safe visible region에 완전히 들어왔음을 확인한 뒤 audit한다. `isHittable` 또는 앱 전체 프레임과 일부 교차만으로 완전 노출을 대체하지 않는다. 미노출·미발견은 실패로 처리한다.
4. target audit를 Settings와 분리 실행할 수 있게 하되 기존 전체 앱 audit는 유지한다. 두 결과를 별도로 보고한다. 대상 밖 기존 실패를 고치거나 숨기기 위해 범위를 넓히지 않는다.
5. 실제 대비 실패가 남으면 먼저 렌더링 상태를 재현하고 관련 제품 코드를 수정한다. 일반 텍스트는 4.5:1 계획 기준과 렌더링 audit를 함께 확인한다. More/Save는 실제 44×44pt hit area와 메뉴/편집/저장/삭제/복귀 조작을 검증한다.
6. light/dark × 기본/최대 지원 글자 크기 × 한국어/영어/긴 Arabic RTL 조합을 iPhone/iPad에서 확인한다. 작은 화면·iPad 좁은 창의 긴 제목 회귀도 포함한다. macOS는 관련 공유 표면의 지원 글자 설정/좁은 창/키보드 조작을 확인하고 적용되지 않는 축은 이유와 함께 N/A로 기록한다.
7. VoiceOver는 대상의 라벨·값·상태·읽기 순서, 상세 진입/닫기·More·편집 후 포커스 복귀를 실제 탐색으로 확인한다. 자동 audit나 스크린샷을 VoiceOver 실행 증거로 대체하지 않는다.

완료 조건: 지정 대상은 예외 마스킹 없이 통과하고 조작 결과가 확인돼야 한다. 시스템 false positive를 독립 재현하더라도 자동 합격시키지 않는다. 좁은 예외를 유지해야 한다면 근거·적용 환경·재검증 조건을 정리해 결정권자의 별도 승인을 받고 기존 금지 조건의 변경 이력을 남긴다.

## 12. R24 — 동일 후보의 통합 검증과 완료 판정

변경 후보: [CI](/Users/changwooson/Developer/InnoSquad/InnoFlow/.github/workflows/ci.yml), [CD](/Users/changwooson/Developer/InnoSquad/InnoFlow/.github/workflows/cd.yml), [principle gate](/Users/changwooson/Developer/InnoSquad/InnoFlow/scripts/principle-gates.sh)와 [구현부](/Users/changwooson/Developer/InnoSquad/InnoFlow/scripts/principle-gates-lib.sh), 해당 self-test, MACRO_OPERATIONS/QUALITY_REVIEW/실행 정책 ADR/기존 계획의 후속 실행 기록. 배포 동작 자체는 실행하지 않는다.

### 검증 행렬

| 묶음 | 필수 실행과 합격 조건 |
| --- | --- |
| 정적/문서 | format lint, 두 저장소 diff check, static principle gate, 경로/ID/문서·CI 계약 정합성 |
| 전체 Core/Testing | 최종 소스에서 full principle gate의 Debug/Release·성능 기준·canonical sample. 새 테스트가 discovery에 포함됐는지 확인 |
| 메모리/동시성 | 별도 경로 TSan/ASan: scheduler/diagnostics/FlowTask/FlowScope 및 가능한 실제 consumer owner 경계. 실행하지 못한 consumer sanitizer는 별도 미검증 |
| 매크로 소비자 | 일반 public/package/generic 외부 소비자, 2-flag/3-flag 조합, 허용·금지 대조군, 5 SDK의 최소 deployment target과 실제 활성 조건. compiler-plugin-free Core도 독립 빌드 |
| 툴체인 | 정확한 Swift 6.3 및 현재 6.4로 최소 package/macro consumer/집중 runtime 검증. 6.4의 language mode 6을 6.3 compiler 실행으로 표기하지 않음 |
| SDK | iOS 18/macOS 15/tvOS 18/watchOS 11/visionOS 2 deployment target의 실제 SDK 빌드. 타깃 버전을 올려 통과시키지 않음 |
| Apple runtime | 현재 macOS와 가용 iOS/tvOS/watchOS/visionOS 27.0에서 scheduler/scope/diagnostics/Output 집중 실행. 설치된 18.5/11.5/2.5 계열도 호환성 집중 실행; 최소 patch/실기기 결과와 구분 |
| 물별 feature/owner | 공식 workspace의 TrainingRecords scheme에서 iOS/macOS 실제 feature 및 owner 통합. 로컬 후보 의존성 경로를 증거에 포함 |
| 물별 UI | iPhone/iPad/macOS 이탈·복귀·실패·재시도·성공 후 갱신, 기록 표시/empty CTA/상세/편집/저장/삭제/복귀, R23 접근성 조합 |
| CI 통합 | 새 fixture·flags matrix·runtime 검사가 로컬 스크립트 및 CI에서 discovery/실패 전파됨. 원격 runner 결과는 승인 후 별도 확인 |

### 실행 경로와 증거

1. 시작 시 scheme/destination을 조회한다. `InnoFlow-Package`가 없는 환경은 SDK product 빌드와 runtime harness를 구분해 지원 경로를 만든다. scheme 실패를 runtime 검증 삭제로 우회하지 않는다. 새로운 harness/스크립트는 정식 repository·CI에 보존한다.
2. 물별 unit/feature는 공식 workspace의 `TrainingRecords`, UI는 실제 노출된 UI-test scheme을 확인해 사용한다. generated project를 손으로 수정하지 않는다. 프로젝트 정의를 바꾼 경우에만 공식 생성 절차를 따른다.
3. 최종 manifest에는 Sources/Tests/샘플뿐 아니라 결과에 영향을 주는 manifest/resolved·빌드 정의·테스트 설정·검증 스크립트·workflow·소비자 파일도 포함한다. 생성 결과물·비밀값은 제외한다. 파일 범위와 제외 이유를 명시한다.
4. 각 실행에 candidate hash, branch/HEAD+dirty 여부, 의존성 경로, toolchain/OS/SDK/device, 실행 명령, 종료 코드, 테스트 수, 실패/skip/N/A, 로그/xcresult 위치를 기록한다. 스킵이 필수 시나리오를 가리면 해당 행은 열린 상태다.
5. 결과 파일이 누락되거나 후보 hash가 달라지거나 필수 행이 pass가 아니면 검증 summary가 완료를 출력하지 못하게 한다. 이를 위한 작은 evidence 검사 도구/정식 테스트를 추가하고 누락·실패·stale hash·필수 skip 입력의 negative self-test를 둔다. 기존 문서 텍스트만 검색하는 방식으로 대신하지 않는다.
6. 소스/검증 설정 변경 후 영향 행을 다시 실행한다. 모든 변경이 끝난 후보에서 마지막 통합 gate를 돌린다. 이유 없는 동일 검사 반복은 피하되 이전 성공 로그로 새 후보 검사를 대체하지 않는다.
7. 로컬에서 확보한 결과를 지속 가능한 문서 요약과 fixture에 남긴다. 대용량 로그는 지정 artifact 위치에 보존하며 `/tmp` 링크만으로 완료 근거를 유지하지 않는다.

### 미확인 환경과 중단 조건

| 미확인/차단 항목 | 담당 | 처리와 다음 gate |
| --- | --- | --- |
| 정확한 Swift 6.3 실행 환경 | 구현 담당 확인, 프로젝트 소유자 환경 제공/설치 결정 | 설치된 toolchain부터 조회. 없으면 해당 compiler가 있는 환경을 확보할 때까지 미검증. 무단 대용량 설치나 최소 버전 상향 금지 |
| 설치 runtime의 실제 호환성/boot 여부 | 구현 담당 | 독립 destination에서 실행; runtime 목록만으로 환경 부재/합격을 추정하지 않음. 실패 원인·필요 환경·다음 명령 기록 |
| VoiceOver 또는 macOS 실제 UI 증거 수집 불가 | 구현 담당 확인, 필요한 경우 소유자 확인 | 가능한 자동/수동 조작 도구를 확인하되 screenshot으로 대체하지 않음. 실제 탐색이 없으면 R23 열린 상태 |
| 시스템 audit false positive의 예외 필요 | 소유자 판단 | 최소 독립 재현과 대상 영향 제시 후 별도 결정. 자동 ignore 추가 금지 |
| 원격 CI/정확한 원격 SHA 소비자/태그/API baseline/배포 | 소유자 승인 후 실행 | 로컬 검증과 별도 release gate. 현재 계획의 로컬 실행 완료가 공개 배포 승인이 아님 |

환경이 없더라도 수행 가능한 다른 로컬 작업은 진행한다. 다만 미실행 필수 행은 전체 검증 완료로 바꾸지 않고 정확한 잔여 항목과 필요한 결정을 보고한다.

## 13. 완료 판정과 반례 검토

완료 상태를 세 단계로 나눈다.

1. **코드 수정 완료:** R16~R22의 정식 회귀·실제 소비자 경로 및 인접 영향 검사가 통과하고 R23의 필요한 제품 수정이 검증됨.
2. **로컬 검증 완료:** SC-FU004~006과 R24의 모든 필수 로컬 행이 같은 후보에서 통과함. 외부 승인 gate와 장치 범위는 명시적으로 분리함.
3. **릴리스 준비 완료/공개 배포 완료:** 승인된 별도 원격/설치/API baseline/태그·배포 검증이 있을 때만 해당 이름을 사용함.

최종 self-review에서는 다음 반례가 모두 부정돼야 한다.

- 앱 owner 테스트만 새 helper를 쓰고 실제 화면은 raw FlowTask를 계속 쓰는가?
- caller 종료가 상태 정리 전에 반환하거나, 비협조적 작업을 물리 종료됐다고 표시하는가?
- queued→started를 각각 신규 요청으로 처리해 이전 상태를 지우는가?
- token 없이 dispatch 수치만 줄여 sibling pending을 잃는가?
- 내부 조건 evaluator와 같은 오해를 가진 테스트끼리만 통과하는가?
- macOS의 활성 분기만 보고 다른 SDK의 payload/availability를 누락하는가?
- 모든 충돌을 허용하거나, 불명확한 availability에서 helper를 전부 없애는가?
- 대상 audit issue를 ignore하거나, 찾지 못한 요소를 skip으로 통과시키는가?
- VoiceOver/실기기/최소 toolchain 결과를 build나 screenshot으로 대체하는가?
- 마지막 코드 변경 이전의 결과를 최종 후보 검증으로 사용하는가?

하나라도 해당하면 관련 AC를 다시 연다. 원래 계약을 약화해서 테스트를 통과시키는 결정은 자동으로 하지 않는다. 문서 상태는 승인 기록 없이는 Draft를 유지한다.

## 14. 2026-09-08 실행 결과

이 절은 위 계획의 실제 로컬 실행 결과이며, Draft 승인 상태나 공개 배포 승인을 뜻하지 않는다.

| 작업 | 상태 | 같은 후보에서 확인한 결과 |
| --- | --- | --- |
| 준비 | 검증 통과 | 두 저장소의 branch/HEAD/dirty 상태, 로컬 package 의존성, Xcode 27.0/Swift 6.4, 설치 SDK/runtime과 디스크를 기록했다. 정확한 Swift 6.3은 설치되지 않아 별도 열린 gate다. |
| IF6-R16 | 검증 통과 | TrainingRecords 실제 scene이 `TrainingRecordsLoadLifecycle`을 사용하고 직접 핸들 취소, caller 취소, 화면 이탈, 중복 종료, stale cleanup 뒤 재조회 계약을 owner 테스트로 고정했다. |
| IF6-R17 | 검증 통과 | 요청별 확정 상태 snapshot을 queued→started 동안 보존하고 idle/loaded/failed 복구, 이전 ID의 늦은 이벤트 차단, 비협조적 선행 요청과 후속 요청의 비중첩을 검증했다. |
| IF6-R18 | 검증 통과 | scheduled token별 pending 집계와 취소/시작/종료의 멱등 정리를 구현했다. 1,000회 lifecycle 회귀와 sibling 생존 대조가 통과했다. |
| IF6-R19~R22 | 검증 통과 | Boolean 조건 AST, 배타/활성 충돌, 구조적 availability, 조건부 ignore/manual helper 합성을 구현했다. public/package/generic 외부 소비자의 3개 flag 전 8조합이 모두 통과했다. |
| IF6-R23 | 실패·열림 | iPhone/iPad 10개 구성 모두 기록 상세까지 도달했고 대상 요소 누락·부분 노출 오류는 0이었으나 시스템 audit은 10/10 실패했다. raw issue 151건(대비 76, Dynamic Type 63, clipped text 12)이 남았다. 대상 매핑 106건은 예외로 숨기지 않았다. 실제 VoiceOver 탐색도 미실행이므로 AC-R023은 닫지 않는다. |
| IF6-R24 | 부분 통과 | 최종 full principle gate에서 Debug/Release 각각 runtime 711/711과 macro 66/66, 격리 성능 기준 1/1, sample package와 canonical sample app build가 통과했다. TSan/ASan 각 67/67, 5개 generic SDK build, iOS/tvOS/watchOS/visionOS 구·신 runtime 8조합 각 53/53(총 424)도 통과했다. 패키지 workspace 충돌과 visionOS 2.5 기종 호환 폴백을 검증 스크립트에 보강했다. 정확한 Swift 6.3, R23, 실제 VoiceOver, 원격 CI/태그/API baseline/서명/공개 설치는 열려 있다. |

Mulbyul 공식 workspace의 최신 기능 증거는 iOS 집중 24/24와 macOS 전체 37/37이다. 내비게이션 UI는 iPhone/iPad에서 각각 적용 가능한 4개가 통과했고 폼팩터 전용 2개씩만 의도적으로 skip됐다. 접근성 canonical 결과, 요약, 로그와 스크린샷은 `.build/release-evidence-r24/mulbyul-a11y-final/verified-final`에 보존한다. 최종 full principle gate 로그는 `.build/release-evidence-r24/final-gates/principle-full.log`이며 후보 해시는 모든 문서 수정 뒤 별도 evidence 파일에 고정한다.

따라서 현재 이름은 **R16~R22 코드 수정 및 로컬 검증 완료**다. R23이 실패했고 R24 필수 행이 열려 있으므로 **전체 로컬 검증 완료**, **릴리스 준비 완료**, **공개 배포 완료**라는 이름은 사용하지 않는다. 커밋·푸시·태그·릴리스·publication은 수행하지 않았다.
