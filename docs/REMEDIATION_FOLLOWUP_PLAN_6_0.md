# InnoFlow 6.0.0 — 추가 반례 6건과 소비자 품질 보완 계획

> 2026-09-07 후속 검토 정정: 아래의 “로컬 구현 및 검증 완료”는 당시 실행 기록으로 보존한다. 이후 새 결함 6건과 기존 미해결 1건, 검증 공백 2건이 확인돼 현재 판정은 **추가 수정·재검증 필요**다. [두 번째 후속 계획](REMEDIATION_SECOND_FOLLOWUP_PLAN_6_0.md)의 IF6-R16~R24로 이어 가며, 해당 계획은 Draft·미착수다.

- 문서 상태: **Draft**, 2026-09-06. 구현 상태: **로컬 구현 및 검증 완료** (2026-09-07).
- 요청: 재검토에서 재현한 추가 수정 사항의 실제 코드 작업 계획 수립.
- 결정권자: 프로젝트 소유자. 구현 담당: 후속 실행 담당자. 검토자·최종 승인일: 미기록.
- 관계: [기존 수정 계획](REMEDIATION_PLAN_6_0.md)의 R01~R07과 [구현 계획](IMPLEMENTATION_PLAN_6_0.md)의 FR/NFR을 유지한다. 후속 작업 ID는 **IF6-R08~R15**로 이어 간다.
- 근거: [수정 후 재검토 보고서](/tmp/innoflow-reaudit-20260906.O45hhU/REVIEW.md). 이 문서의 F1~F6은 해당 보고서의 번호이며 첫 검토의 F 번호와 다르다.
- 실행 순서: **준비 → R08 → R09 → R10 → R11 → R12 → R13 → R14 → R15**. 아래 실행 기록은 로컬 후보의 결과이며 리뷰 승인·커밋·푸시·태그·공개 배포를 뜻하지 않는다.

## 1. 목표와 범위

목표는 물별 조회의 취소·복구, 실제 대기 수와 진단 수치, 정상적인 멀티플랫폼
Output 선언의 컴파일, 기록 화면의 접근성을 보장하는 것이다.

확인한 사실:

- InnoFlow 후보는 `release/6.0.0-local`, HEAD `00a73ed2d2cb94114b0be5c9fbd59c187a4b67c7`에 미커밋 변경을 더한 상태다.
- 마지막 검토의 소스·테스트·샘플/물별 후보 해시는 `8adca5a31632cce1d60ed74c1f51a2b215934c4bd91abf12bcec492ac99aa14c`이다. 실행 시작 시 다시 산출한다.
- 기존 집중 테스트 50개와 매크로 테스트 1개는 통과했지만, 새 실행 반례 2개와 외부 매크로 소비자 4개가 실패했다.
- 매크로 대조군 plain enum 4개는 최소 macOS 15 타깃에서 컴파일됐고 `@InnoFlow` 적용 시 실패했다.
- 별도 물별 QA에서 기록 화면 대비 5건과 상세 메뉴의 작은 터치영역 1건을 발견했다. 이번 계획 작성에서 UI를 재실행하지 않았다.
- 최소 Swift tools는 6.3, 현재 검증 툴체인은 Swift 6.4/Xcode 27이며, 선언된 최소 OS는 iOS 18/macOS 15/tvOS 18/watchOS 11/visionOS 2다.

작업 범위는 InnoFlow Core/Testing/Output 매크로·회귀·문서·CI와 물별 Apple의
TrainingRecords feature/화면/직접 관련 테스트다. Kotlin/Android·TypeScript/React
후보의 병합이나 포팅은 포함하지 않는다. 지원 최소 버전·의존성 버전을 유지하고,
앱 저장·네트워크·새 실행 정책을 추가하지 않는다. 커밋·푸시·태그·공개 배포는
별도 실행 범위다. 기존 dirty 변경은 보존한다.

## 2. 요구사항과 완료 기준

기존 FR-001~007 및 NFR-001~005를 계승한다. 새 소비자 품질 요구사항은
**FR-008: TrainingRecords의 상태 텍스트와 상세 메뉴를 지원 표시 환경에서
읽고 조작할 수 있어야 한다**로 정의한다. 각 AC는 아래 요구사항에 연결된다.

| 순서/작업 | 발견/요구사항 | 완료 기준 | 예정 검증 |
| --- | --- | --- | --- |
| 1 / IF6-R08 | F1, FR-002/003/007 | AC-R008: 물별이 소유한 조회 취소·종료 뒤 loading/request 소유권이 남지 않으며 이전 취소가 새 요청을 지우지 않는다. | 실제 feature·수명 owner 테스트, iOS/macOS 이탈·복귀/실패 UI |
| 2 / IF6-R09 | F4, FR-006/007 | AC-R009: 독립적인 배타 조건문이 거짓 충돌을 내지 않고 활성 분기의 실제 충돌은 진단한다. | macro expansion, 외부 compile on/off 및 플랫폼 분기 |
| 3 / IF6-R10 | F3, FR-006/007 | AC-R010: 수동 helper가 있는 조건에서만 자동 생성을 억제하며 나머지 조건에서도 canonical helper를 쓸 수 있다. | `MANUAL_PATH` on/off, generic/public/package consumer |
| 4 / IF6-R11 | F5, FR-006/007 | AC-R011: 조건부 availability와 case 조건을 함께 보존해 유효한 선언은 컴파일되고 금지된 사용은 거절된다. | 최소 OS compile, 조건부 attribute expansion |
| 5 / IF6-R12 | F6, FR-006/007 | AC-R012: unavailable 등을 포함한 유효한 enum에 매크로를 적용해도 컴파일되고 가용성 제한은 약해지지 않는다. | Swift 대조군, stored/computed/generic 경로 |
| 6 / IF6-R13 | F2, FR-004, NFR-004 | AC-R013: sibling이 실행 중이어도 취소·시작·교체 후 queued 수가 실제 pending 수와 같고 중복 차감/보관 누적이 없다. | scheduler/diagnostics 통합 및 반복 경계 테스트 |
| 7 / IF6-R14 | 기존 접근성 6건, FR-008/007 | AC-R014: 지정한 대비 5건의 렌더링 audit가 통과하고 메뉴의 실제 터치영역이 44×44pt 이상이며 조작된다. | light/dark·Dynamic Type·VoiceOver·UI audit |
| 8 / IF6-R15 | 검증/문서 공백, FR-001/007, NFR-005 | AC-R015: 새 반례와 기존 계약의 증거가 동일 최종 후보에 연결되고 미실행 항목이 완료로 표시되지 않는다. | 통합 검증표, 후보 해시, 문서·CI 대조 |

SC-FU001: 새 반례 6건 각각에 수정 전 실패·수정 후 성공 로그와 정식 회귀 테스트가
있어야 한다. SC-FU002: 접근성 6건의 재검증 결과가 있어야 한다. SC-FU003:
필수 검증 중 실패·미실행이 남아 있으면 최종 전체 완료로 표시하지 않는다.

## 3. 준비 — 기준선과 실패 재현 고정

- [x] 두 저장소의 branch/HEAD/status, 관련 파일 해시, 현재 의존성 해석 경로와 가용 툴체인/runtime을 기록했다.
- [x] 임시 보고서/probe의 재현 내용을 정식 테스트 fixture로 보존했다. `/tmp` 로그는 실행 증거일 뿐 미래 회귀의 유일한 근거가 아니다.
- [x] F1/F2는 gate/signal로 경계를 고정하고 F3~F6은 plain enum과 일반 `@InnoFlow` 소비자 쌍으로 실패를 확인했다.
- [x] build/test마다 독립 scratch/DerivedData를 사용하고 무거운 작업은 직렬 job으로 수행했다.
- [x] 검증 환경 부족을 기록했다. 설치된 툴체인은 Swift 6.4/Xcode 27.0이며 별도 Swift 6.3 툴체인은 없어 정확한 6.3 실행을 완료로 표시하지 않는다.

## 4. R08 — 물별 조회 취소와 화면 수명 정리

변경 대상: 물별의 `TrainingRecordsFeature.swift`, `TrainingRecordsFeatureTests.swift`,
`TrainingRecordsCurrentExperienceScene.swift`, `TrainingRecordsScene.swift`,
`TrainingRecordsNavigationUITests.swift`. 필요하면 Shared 영역에
`TrainingRecordsLoadLifecycle.swift`와 그 테스트를 추가한다.

1. **앱 소유 조회 수명**을 한 경로로 모은다. 최초 로드·재시도·수정/삭제 후 갱신의 호출 지점을 모두 조사하고, 요청 ID와 FlowTask 및 종료 정리를 연결하는 MainActor owner를 둔다.
2. 시작·취소·종료를 구분하는 내부 action을 정의한다. 취소/종료 정리는 취소된 effect의 `Send`가 아니라 살아 있는 앱 owner가 보내는 새 root action으로 처리하고 반드시 해당 요청 ID를 검사한다.
3. 취소 시 표시 상태는 직전 확정 상태로 복구한다. 첫 로딩 전에는 idle, 기존 정상 데이터가 있으면 loaded, 실패 화면에서 재시도했다면 이전 failed 상태로 돌아가도록 필요한 이전 표시 상태를 보존한다. PhaseMap이 phase를 소유한다.
4. caller 취소가 물리 작업에 전달되고 owner의 종료가 정리 action 처리까지 기다리게 한다. 화면 이탈·재진입과 빠른 request 교체에서 이전 종료가 새 owner를 지우지 못하게 한다. 비협조적 run은 실제 반환까지 기존 lane 계약을 유지한다.
5. 누락 의존성·성공·실패·busy·취소를 각각 처리한다. 물별이 사용하지 않는 다른 화면/저장 작업은 취소하지 않는다.

중요한 계약 구분: raw `FlowTask.cancel()` 자체는 reducer 상태 rollback을 보장하지
않는다. 따라서 consumer 취소 action만 추가한 뒤 raw Store probe도 해결됐다고
표시하면 안 된다. 실제 물별 구성에 종료 관찰/정리를 연결해 **소비자가 제공하는
핸들 취소·caller 취소·화면 이탈 경로 모두**에서 AC-R008을 증명한다. 프레임워크의
취소된 emission 차단은 그대로 유지한다.

필수 회귀: 실행 전/중 취소, 직접 핸들 취소, caller 취소, 빠른 이탈·복귀,
성공/실패 직후 재요청, stale cancellation/admission/completion, 무의존성,
기존 데이터 보존, 실제 repository 호출 수, sibling 작업 생존. iOS와 macOS의
공식 workspace를 사용하고 화면·state·실제 종료를 함께 확인한다.

## 5. R09 — 조건 문맥과 충돌 검사 공통 기반

변경 대상: `InnoFlowMacro+OutputPathSynthesis.swift`, 신규 조건 문맥 helper 파일,
`InnoFlowMacrosTests.swift`, `CompileContractTests.swift`, `OutputCasePathTests.swift`.

1. IfConfig 그룹 번호뿐 아니라 case/member의 유효 조건을 표현한다. `elseif`는 앞선 분기 부정과 현재 조건, `else`는 앞선 조건 전체의 부정으로 표현하고 중첩 문맥을 결합한다.
2. `P`와 `!P`, 서로 다른 `os(...)` 등 확실한 배타 관계를 처리한다. 원래 조건식을 보존하며 현재 호스트의 결과로 평탄화하지 않는다.
3. 조건 중첩을 확정할 수 없는 경우 무조건적인 macro 오류를 내지 않고 실제 활성 조건에서 충돌이 진단되도록 생성/검사 경로를 구성한다. 별도 범용 논리 엔진이나 외부 의존성을 도입하지 않는다.
4. 이름 수집·생성 이름·수동 path·identity marker가 같은 조건 표현을 사용하게 한다. Action 경로가 공유 helper 영향을 받으면 기존 Action macro suite도 검증한다.

필수 회귀: 단일 if/elseif/else, 독립적인 배타 블록, 중첩 조건, `canImport`/사용자
flag on/off, 비활성 플랫폼 전용 타입, 실제 동시 활성 이름 충돌. 실제 충돌을
모두 허용하는 것으로 거짓 충돌 문제를 해결하면 안 된다.

## 6. R10 — 조건부 수동 helper의 전체/부분 포함 관계

R09의 조건 표현을 재사용한다. 변경 대상은 같은 Output 생성기와 macro/compile
tests이며 필요하면 `OutputConditionalCompileContractTests.swift`로 fixture를 분리한다.

1. case의 활성 조건과 수동 helper 정의가 커버하는 조건을 비교한다. 일부만 겹친다는 이유로 전체 합성을 생략하지 않는다.
2. 수동 helper가 없는 나머지 조건에서 자동 helper와 generic identity marker를 생성한다. 기존 수동 helper는 그대로 사용한다.
3. 수동 정의가 여러 조건에 분산된 경우도 합산해 처리하며 opt-out의 조건 범위를 유지한다.

필수 회귀: `MANUAL_PATH` on/off에서 동일 source의 path 접근·round trip 성공,
완전 포함/부분 포함/겹치지 않음, 중첩 조건, public/package/generic,
복수 수동 helper, escaped name, ignore marker. 최소한 flag-on 성공과
flag-off 성공의 두 compiler 결과가 있어야 이 단계를 닫는다.

## 7. R11 — 조건부 availability 구조 보존

변경 대상: Output attribute 수집·생성 helper, macro expansion 및 compile tests.

1. attribute 목록의 직접 AttributeSyntax와 IfConfigDeclSyntax를 재귀 순회한다.
2. `@available`의 조건·순서·구문을 보존해 helper에 적용한다. macro 제어용 attribute를 무조건 복사하지 않는다.
3. case 조건·attribute 조건·generic computed 경로가 겹쳐도 선언과 payload 타입이 조건 밖으로 새지 않게 한다.

필수 회귀: 조건부 attribute만 있는 case, case와 attribute가 함께 조건부인 경우,
다중 availability, 부모 enum의 가용성, public/package/generic, 최소 배포 타깃의
허용 문맥과 의도적으로 금지된 문맥. 성공과 실패 대조군을 함께 유지한다.

## 8. R12 — unavailable 및 availability 종류별 유효 생성

변경 대상: Output stored/computed helper 생성, macro tests, compile contracts,
필요한 가용성 설명 문서.

1. introduced/deprecated/unavailable/obsoleted를 compiler 대조군과 비교한다. Swift 언어 자체가 금지하는 enum 선언과 생성기 결함을 분리한다.
2. unavailable stored initializer를 그대로 생성하지 않는다. 제한된 declaration 내부의 computed helper처럼 컴파일러가 허용하는 형태를 먼저 검증하고 선택한다. 해당 가용성에서 helper 사용은 계속 금지돼야 한다.
3. unavailable case를 조용히 전부 무시하거나 모든 non-generic helper를 computed로 바꿔 우회하지 않는다. 제한적인 생성 방식으로 해결할 수 없는 종류는 합성 계약의 명시적 결정과 compile 증거를 먼저 남긴다.
4. 정상 case의 접근 수준·payload·안정된 path identity는 보존한다.

필수 회귀: `@available(*, unavailable)`, 플랫폼별 unavailable,
introduced/deprecated/obsoleted, payload 유무, generic/non-generic,
conditional attribute와 조합. R11/R12는 별도 반례이므로 각각의 실패/성공 증거를 둔다.

## 9. R13 — 실제 pending 수와 diagnostics 정합성

변경 대상: `EffectRunScheduler.swift`, `StoreDiagnostics.swift`,
`Store+EffectDriver.swift`, 필요 시 `TestStore+EffectRunScheduler.swift`,
`DispatchDiagnosticsTests.swift`, `EffectRunSchedulerTests.swift`.

1. scheduled request token으로 queued/start/cancel/replace/finish 상태를 식별한다. 물리 run token과 scheduled token의 의미를 혼동하지 않는다.
2. pending 제거를 diagnostics에 전달하는 package 내부 callback/메타데이터 경로를 연결한다. 공개 enum에 case를 추가하는 호환성 변경 없이 처리하는 방향을 우선한다.
3. queued 수는 한 request의 대기 진입·이탈마다 정확히 한 번 갱신한다. 같은 dispatch의 다른 run 시작·종료가 이 request의 대기 수를 변경하지 못하게 한다.
4. live token만 보관하며 dispatch 종료·교체·Store 해제 시 정리한다. 종료 ID tombstone 집합이나 기본 payload 녹화는 추가하지 않는다.

필수 회귀: pending 취소 뒤 긴 sibling만 생존, 여러 pending 중 일부 취소,
서로 다른 lane/dispatch/Store, 시작과 취소 교차, 동일 토큰 중복 callback,
직접 handle 취소·상속 ID 취소·cancelAll, history capacity 0/1/N,
Store 해제 및 반복 후 저장 구조 기준선 복귀. 테스트는 dispatch 종료 전에도
실제 queue=0 및 diagnostics queued=0임을 확인해야 한다.

## 10. R14 — 물별 접근성 6건 수정

변경 후보: `TrainingRecordsScene+Display.swift`, `TrainingRecordsScene+Components.swift`,
`TrainingRecordsCurrentExperienceScene.swift`, `TrainingRecordCurrentDetailSupport.swift`,
`TrainingRecordCurrentDetailScreen.swift`, `AccessibilityAuditUITests.swift`,
`TrainingRecordsNavigationUITests.swift`. 필요할 때만 물별 DesignSystem semantic
token의 원본 정의를 조정하고 해당 token 소비 화면을 검증한다.

1. root `100%`, row `01:30`, row `4/4`, detail summary `4/4`, set status `성공`의 텍스트/배경 조합을 고친다. 장식용 색과 읽는 텍스트 색을 구분한다.
2. 대상 텍스트는 일반 크기에서도 4.5:1 이상을 계획 기준으로 적용하고 Apple 렌더링 audit까지 통과시킨다. 계산값만으로 near-pass를 무시하지 않는다.
3. `training.records.detail.more`의 실제 hit area를 44×44pt 이상으로 보장하고 메뉴 열기·편집/삭제 동작·toolbar 배치를 검증한다.
4. light/dark, 기본/최대 지원 Dynamic Type, 한국어 및 기존 대표 locale fixture, iPhone/iPad·macOS 관련 공유 표면을 확인한다. VoiceOver 읽기 순서·라벨·포커스도 유지한다.

완료 기준은 지정된 6건의 통과와 영향 화면의 회귀 없음이다. audit ignore 목록
확대나 UI 테스트 삭제로 통과시키지 않는다. 다른 training/settings의 기존
접근성 실패가 남으면 전체 앱 audit 성공과 구분해서 기록한다.

## 11. R15 — 동일 후보의 최종 검증과 완료 근거

각 단계는 `실패 재현 → 구현 → 집중 회귀 → 인접 영향 검사 → 계약 기록`으로 닫는다.
최종 실행은 소스 변경이 끝난 후보에서 수행하며 이미 통과한 동일 검사를 이유 없이
반복하지 않는다. 결과마다 후보 hash, toolchain/OS, 명령, 종료 코드, 테스트 수,
실패/미실행, 로그와 실제 의존성 해석 경로를 남긴다.

| 검증 묶음 | 실행 기준 |
| --- | --- |
| 정적/문서 | format lint, 두 저장소 diff check, static principle gate, macro 운영/계약·release surface 정합성 |
| 전체 테스트 | full principle gate의 Debug/Release 전체 및 성능 기준·canonical sample 검증. 새 회귀가 실제 test discovery에 포함되는지 확인 |
| 메모리/동시성 | 별도 build path에서 TSan/ASan, 새 token bookkeeping과 consumer 수명 owner의 취소/보관 회귀 |
| 매크로 소비자 | plain enum과 일반 public/package/generic @InnoFlow 대조, 사용자 flag on/off, 5 SDK 실제 활성 분기와 최소 deployment target, plugin-free Core |
| 툴체인/런타임 | 가용한 Swift 6.3 및 현재 6.4, 5 Apple SDK build, 설치된 지원 runtime의 집중 scheduler/scope/diagnostics/Output 실행. 구형 OS 실기기 결과를 SDK build로 대체하지 않음 |
| 물별 | 실제 로컬 후보를 연결한 공식 workspace feature tests, iOS/macOS 취소/이탈/복귀/실패복구/기록 표시/상세/empty CTA, 접근성 재검증 |
| CI와 이력 | 새로운 fixture와 flags matrix가 관련 CI 경로에 포함되는지 확인. 승인받아 원격 실행한 결과가 없으면 로컬 통과만 기록 |

최종 문서는 `QUALITY_REVIEW_6_0.md`, 두 수정 계획, `IMPLEMENTATION_PLAN_6_0.md`,
실행 정책 ADR, `CLAUDE.md`, `MACRO_OPERATIONS.md`를 실제 변경 범위에 맞게 갱신한다.
기존 완료 이력은 삭제하지 않고 후속 반례와 재검증 결과를 연결한다.

기존 13초 cold-start 관찰과 빌드 경고는 별도 증거 점검 항목이다. 첫 실행·데이터
조회·UI test 준비 시간을 분리하고 같은 조건의 반복 측정으로 원인을 확인한다.
이번 변경에서 생긴 경고/지연은 해결하고, 기존 공통 토큰 deprecation 등 전역
정리 작업은 영향 파일·범위와 함께 후속 항목으로 기록한다. 불안정한 기존 측정값을
성능 합격 기준으로 채택하거나 전체 경고 개수만으로 개선됐다고 판단하지 않는다.

## 12. 완료 판정과 반례 점검

- R08~R14 각각의 AC가 통과해야 코드/화면 수정 완료다. R15 검증표의 필수 행까지 통과해야 로컬 후보 검증 완료다.
- 환경이 없어 실행하지 못한 필수 행은 `미검증`으로 남기고 담당자/필요 환경/다음 명령을 기록한다. 전체 완료와 동일하게 취급하지 않는다.
- 로컬 검증 완료와 공개 릴리스는 다른 상태다. 원격 CI·정확한 원격 의존성 설치·태그/API baseline·공개 배포는 해당 결과가 있을 때만 완료 처리한다.
- 문서 상태는 Draft/Reviewed/Approved이며, 실제 실행 상태·검증 상태는 별도 필드로 기록한다. 실행이 끝났다고 리뷰/승인을 자동 부여하지 않는다.

최종 반례 검토에서는 다음을 확인한다: 취소 플래그만 켜고 loading을 남겼는가,
정리 action이 새 요청을 지우는가, 실제 큐 대신 진단 숫자만 0으로 만들었는가,
manual flag 한쪽만 빌드했는가, 충돌 검사를 모두 껐는가, availability를 제거했는가,
최소 OS를 올려 컴파일을 통과시켰는가, 접근성 경고를 ignore했는가,
미실행 환경을 완료로 표현했는가. 하나라도 해당하면 해당 AC를 닫지 않는다.

## 13. 2026-09-07 로컬 실행 결과

R08~R14의 구현과 정식 회귀 편입을 완료했다. 최종 코드·테스트 후보 SHA-256은
`69ebfde89345b4f21df0f9c16e66ebb34d3a1c38c578981542837ffeafb152d5`다.
InnoFlow의 Sources/Tests/canonical sample과 물별 TrainingRecords source/tests,
두 UI test 및 QA 문서 237개 파일의 경로별 SHA-256 manifest를 다시 해시했다.
InnoFlow 기준 branch/HEAD는
`release/6.0.0-local` / `00a73ed2d2cb94114b0be5c9fbd59c187a4b67c7`,
물별은 `main` / `092ff951`이며 두 저장소의 기존 dirty 변경을 보존했다.

### 구현 결과

- **R08:** 물별 TrainingRecords가 요청 ID와 `FlowTask`를 함께 소유하고 취소·종료 시
  직전 확정 표시 상태로 복구한다. 이전 요청의 종료가 새 요청을 정리하지 못하며
  직렬 lane은 비협조적 선행 작업의 실제 반환 전까지 중첩 실행을 허용하지 않는다.
- **R09~R12:** Output 합성기가 `#if/#elseif/#else`의 논리 문맥과 중첩을 보존하고,
  명백한 긍정/부정 및 플랫폼 배타 관계를 구분한다. 조건부 수동 helper는 자신이
  덮는 분기만 억제하며 조건부 availability와 플랫폼 unavailable의 허용 범위를
  자동 helper에 보존한다.
- **R13:** scheduler pending 제거 callback을 diagnostics에 연결해 취소·교체·완료와
  `cancelAll`에서 정확한 request만 한 번 차감한다. 긴 sibling이 살아 있는 동안에도
  실제 pending과 `queuedEffectRunCount`가 함께 0이 되는 회귀를 추가했다.
- **R14:** 지정된 대비 5건은 읽는 텍스트에 `textPrimary`를 적용해 해소했고 More와
  편집 Save의 실제 hit area를 44pt 이상으로 보장했다. iPad floating keyboard
  popover까지 포함한 편집·저장·복귀 경로를 자동화했다. 추가 시각 검토에서 최대
  Dynamic Type의 긴 RTL 제목 폭이 58pt로 붕괴하던 문제를 발견해 제목/상태를 세로
  배치하고 160pt 이상 읽기 폭을 회귀로 고정했다. 접근성 audit의 초대형 RTL 목록
  이동은 실제 Records 스크롤뷰와 요소 위치를 기준으로 짧게 이동한다.

### 검증 기록

| 검증 | 로컬 결과와 증거 |
| --- | --- |
| InnoFlow 전체 | Debug/Release 각각 Core 708개·58 suites 및 macro 65개·5 suites, 성능 기준, canonical sample/PhaseMap을 통과했다. 최종 동일 후보 재실행 로그는 `/tmp/innoflow-principle-gates-exact-final.log`다. |
| 집중 계약 | macro snapshot과 외부 compile contract가 `MANUAL_PATH` on/off, 조건부/직접 availability·unavailable, 플랫폼 분기와 독립 배타 조건을 모두 통과했다. |
| Sanitizer | 최종 소스에서 TSan과 ASan 집중 회귀가 각각 45개·3 suites를 통과했고 sanitizer report가 없었다: `/tmp/innoflow-tsan-final.log`, `/tmp/innoflow-asan-final.log`. |
| SDK 최소 타깃 | 실제 macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2 SDK/triple에서 `InnoFlow` product를 독립 scratch path와 `--jobs 1`로 빌드했다: `/tmp/innoflow-sdk-swiftpm-*-final.log`. |
| 물별 feature | 공식 workspace에서 TrainingRecords 신규 8개가 iOS와 macOS에서 각각 통과했다. xcresult는 `/tmp/mulbyul-followup-feature.aDaLTZ/TrainingRecordsFeatureTests-final3.xcresult`, `TrainingRecordsFeatureTests-macOS-final.xcresult`다. |
| 물별 iPhone/iPad UI | iPhone 17 Pro와 iPad Pro 11-inch에서 각각 4개 통과, 폼팩터 전용 2개 skip, 실패 0이다. 직접 상세, empty CTA, 편집/저장/복귀, 세트 닫기, More/Save hit area를 검증했다. xcresult는 같은 임시 폴더의 `TrainingRecordsNavigationUITests-{iPhone,iPad}-final-pass.xcresult`다. |
| 접근성 | light/dark 및 Arabic 최대 Dynamic Type audit로 지정된 대비 5건이 해소됨을 확인했다. 최종 Arabic 실행은 요약 지표 도달, 긴 RTL 제목 폭 160pt 이상, 화면 중앙의 세트 상태 대비를 통과했다: `/tmp/mulbyul-followup-feature.aDaLTZ/AccessibilityAudit-Arabic-exact-final5.xcresult`. 전체 테스트 상태는 범위 밖 Settings 테마 도달/동적 글자 크기 실패 때문에 red이며, Records 세트 상세의 검증된 clipped-text false positive도 전체 앱 green과 분리한다. |
| 동일 후보 확인 | strict format, 두 저장소 `git diff --check`, static/full principle gate를 최종 후보에서 통과했다. 전체 로그는 `/tmp/innoflow-principle-gates-exact-final.log`, 후보 SHA-256은 `69ebfde89345b4f21df0f9c16e66ebb34d3a1c38c578981542837ffeafb152d5`다. |

### 확인된 환경 경계

- 현재 머신에는 Swift 6.4/Xcode 27.0만 있어 정확한 Swift 6.3 컴파일 실행은
  **미검증**이다. 다섯 최소 deployment triple의 실제 SDK 빌드는 통과했지만 구형
  실기기 runtime 증거를 대신하지 않는다.
- Xcode 27이 로컬 생성 프로젝트에 `InnoFlow-Package` scheme을 노출하지 않고 직접
  `InnoFlow` scheme은 SwiftSyntax 모듈 해석에 실패했다. 따라서 플랫폼 검증은 실제
  SwiftPM package product와 SDK로 수행했다. CI의 `macos-26` package scheme은 원격
  실행에서 별도 확인해야 한다.
- 원격 CI, 정확한 원격 SHA 소비자 설치, API baseline/tag, 서명 및 공개 설치·배포는
  실행하지 않았다. 이는 로컬 구현 완료와 별개의 릴리스 승인 gate다.
