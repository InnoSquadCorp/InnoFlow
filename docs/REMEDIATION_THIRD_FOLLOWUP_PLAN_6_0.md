# InnoFlow 6.0.0 — 배포 증거·매크로 호환성·소비자 품질 수정 계획

- 문서 상태: **Draft (미승인)**, 작성일 2026-09-09. 현재 판정: **R25/R27/R28 재개, R26 구현·회귀 보완 필요, R30/R31 미완료**. R29의 과거 집중 검증은 보존한다.
- 최신 수정 계획: [네 번째 후속 계획 — IF6-R32~R38](REMEDIATION_FOURTH_FOLLOWUP_PLAN_6_0.md). 아래 12절은 당시 실행 이력이며 새 반례 발견 후의 전체 합격 판정이 아니다.
- 결정권자: 프로젝트 소유자. 구현 담당: 후속 실행 담당자. 리뷰 담당자·승인일: 미기록.
- 목적: 직전 재검토에서 확인한 결함 5건과 검증 공백 2묶음을 수정하고, 약속한 6.0.0 계약을 실제 소비자·지원 환경에서 입증한다. 새 제품 기능을 추가하는 계획이 아니다.
- 요구사항: [기존 구현 계획](IMPLEMENTATION_PLAN_6_0.md)의 FR-001~007/NFR-001~005, [첫 후속 계획](REMEDIATION_FOLLOWUP_PLAN_6_0.md)의 FR-008을 유지한다. 새 작업은 **IF6-R25~R31**, 새 완료 조건은 **AC-R025~031**이다.
- 이력: [두 번째 후속 계획](REMEDIATION_SECOND_FOLLOWUP_PLAN_6_0.md)의 과거 실행 기록을 보존한다. 다만 현재 R20/R24는 새 반례로 다시 열고, R21/R23은 부분 충족으로 취급한다. 이 문서는 과거의 통과 이력을 현재의 전체 합격으로 승계하지 않는다.
- 감사 근거: [2026-09-09 재검토 보고서](../.build/review-20260909-EQbFF6/REVIEW.md). 아래 F1~F5/G1~G2는 이 보고서의 번호이며 이전 보고서의 동일 번호와 구분한다. `.build` 증거는 로컬 보존본이므로 구현 때 최소 fixture를 정식 테스트에 편입한다.

## 1. 기준 상태와 범위

### 확인된 사실 — 2026-09-09 재검토 기준

| 항목 | 기준과 의미 |
| --- | --- |
| InnoFlow | `release/6.0.0-local`, HEAD `00a73ed2d2cb94114b0be5c9fbd59c187a4b67c7` 및 미커밋 변경. 상태 항목 163개 |
| 물별 | `main`, HEAD `092ff9514695ceae5cfd490388e017fac331e30a` 및 미커밋 변경. 상태 항목 27개. Apple package가 로컬 InnoFlow를 참조 |
| 감사 당시 두 저장소 해시 | `05e4db8b3ef9bfdfd8c1b6c2a78bf2c5cee00d9081345c01db775abf8b25e91a`. 이 계획 파일 추가 전 기준이며, 이후 후보 해시로 재사용하지 않음 |
| 검증 환경 | Xcode 27 / Swift 6.4. 정확한 Swift 6.3은 미검증. 오래된 빌드 산출물은 설치된 toolchain의 증거가 아님 |
| 최근 통과 | product build, 집중 55 tests / 5 suites, static principle gate, 기존 evidence self-test. 새 반례를 포함하지 않는 통과임 |
| 접근성 원본 재판독 | canonical xcresult 10/10 실패. 실패 메시지 기준 대비 65 + Dynamic Type 54 + clipped text 12 = 131건, infrastructure timeout 3건. raw audit 151건 및 고유 UI 결함 수와는 다른 지표 |

위 표는 구현 전 기준 상태를 보존한다. 2026-09-09 후속 실행 결과는 12절에 별도 기록하며, 과거 결과를 새 후보의 증거로 재표기하지 않는다.

### 범위와 비목표

- 포함: InnoFlow Output 매크로와 dispatch 진단, 증거 생성·검사·CI/CD 연결, 물별 Apple TrainingRecords의 접근성·실패 복구·내비게이션·macOS UI 검증, 직접 관련 계약 문서.
- 제외: 새 API/실행 정책/제품 기능, 저장 스키마 변경, 최소 OS·Swift 버전 상향, 다른 프레임워크 변경, Settings 전체 개선, 별도 Kotlin/Android·TypeScript/React 후보 병합. Apple 다중 플랫폼 검증을 Android/Web 검증 완료로 표현하지 않는다.
- 기존 dirty/untracked 파일, `Derived/`, `InnoFlow.xcodeproj/`를 보존한다. 생성 Xcode 프로젝트는 손으로 수정하지 않는다. 필요한 경우 물별의 정식 프로젝트 정의와 생성 절차를 사용한다.
- 이번 요청은 계획 작성이다. 후속 구현 승인과 별개로 커밋·푸시·원격 workflow 실행·태그·서명·공개 배포는 자동 승인하지 않는다. 무관한 변경을 정리하거나 배포 권한·보안 설정을 낮추지 않는다.

### 가정과 미확인 사항

- 작업 가정: 앞선 R16~R24의 기능·플랫폼·접근성 계약을 축소하지 않고 보완한다. 그 계약을 바꾸려면 변경 이유와 영향에 대한 별도 결정이 필요하다.
- 미확인: 정확한 Swift 6.3 실행 환경, macOS UI 자동화 가능 범위, VoiceOver 실제 탐색 수단, 원격에서 물별 증거를 가져올 권한·경로. 구현 담당자가 가능한 로컬 수단을 먼저 확인하고, 환경 제공·외부 실행·예외 승인은 프로젝트 소유자에게 요청한다.
- audit 시스템 자체의 false positive 여부는 개별 독립 재현 전까지 미확인이다. 시간 초과 3건도 원인을 조사하기 전에는 제품/테스트/환경 중 하나로 단정하지 않는다.

## 2. 실행 순서와 요구사항 추적

순서는 **준비 → R25 → R26 → R27 → R28 → R29 → R30 → R31**이다. 각 단계에서 실패 회귀 확보 → 수정 → 집중 검증 → 관련 문서·게이트 반영을 완료한다. R26의 원격 실행 등 환경·권한 대기는 열린 채로 기록하고 가능한 다음 로컬 단계는 진행한다. R31의 통합 합격은 앞선 모든 필수 조건이 닫힌 뒤에만 가능하다.

| 순서 / 작업 | 발견·요구사항 | 완료 조건 | 필수 검증 |
| --- | --- | --- | --- |
| 1 / IF6-R25 | F1, FR-001/007, NFR-005, 기존 AC-R024 | **AC-R025:** 독립 필수 목록과 실제 실행 증거가 완전하게 일치할 때만 해당 검증 단계가 통과한다. 행 삭제·강등·실패 재표기·다른 후보 증거로 통과할 수 없다. | manifest/receipt 음성 회귀, 정상 완전 집합 양성 회귀, artifact 결과 대조 |
| 2 / IF6-R26 | F2, FR-007, NFR-005, AC-R024 | **AC-R026:** 공개 배포 job은 정확한 태그 후보의 배포 전 필수 증거·승인 검사가 성공한 경우에만 실행 가능하다. | workflow 제어 흐름 검사, 누락/실패/skip 입력, 무배포 실행 경로 |
| 3 / IF6-R27 | F3, FR-006/007, AC-R020 | **AC-R027:** compiler가 허용하는 배타 조건은 helper를 보존하고, 동시에 활성화되는 실제 충돌은 계속 실패한다. | arch/targetEnvironment/swift/compiler 및 기존 Boolean 조건의 실제 compiler 대조 |
| 4 / IF6-R28 | F4, FR-006/007, AC-R021 | **AC-R028:** 정상 앱의 helper를 보존하면서 extension의 금지 사용·버전 제한은 약화하지 않는다. | plain/manual/macro 대조, 일반 앱 양성·extension 음성, SDK별 availability |
| 5 / IF6-R29 | F5, FR-004, NFR-004 | **AC-R029:** 취소 경계의 queued action drop이 원래 DispatchID로 정확히 기록되며 상태·output·sibling 수명·bounded history 계약은 유지된다. | public Store의 run/send 두 경로, ID·횟수·상태·종료 후 기록 회귀 |
| 6 / IF6-R30 | G1/G2, FR-007/008, AC-R023 | **AC-R030:** 원본 결과를 일관되게 집계하고, 지정 접근성 대상·24개 표시 조합·실제 복구/내비게이션·macOS UI·VoiceOver 계약을 예외 마스킹 없이 검증한다. | 집계 fixture, iPhone/iPad 24조합, 실패/재시도/갱신 UI, macOS 창/키보드, 실제 VoiceOver |
| 7 / IF6-R31 | F1/F2/G1/G2, FR-001/007/008, NFR-005, AC-R024 | **AC-R031:** 최종 후보에 필수 검사별 결과가 연결되고 로컬·배포 전·배포 후 상태가 일치한다. 미실행·실패·누락은 전체 완료로 바뀌지 않는다. | 전체 회귀, SDK/runtime/툴체인/소비자, 독립 증거 검사, 문서 대조 |

새 성공 기준:

- **SC-FU007:** F1~F5 각각 수정 전 실패와 수정 후 통과를 보이는 정식 회귀가 있고, 양성 대조군 및 인접 계약이 함께 통과한다.
- **SC-FU008:** R30의 필수 환경·시나리오를 빠짐없이 식별하고 모든 결과를 원본에 추적할 수 있다. 제품 이슈·무시된 raw 이슈·실행 오류·미실행을 별도 집계하며, 필수 대상 실패/미실행이 남으면 접근성 완료가 아니다.
- **SC-FU009:** R31에서 해당 단계의 필수 ID·환경 집합, 실행 후보, artifact 결과가 모두 일치한다. 서로 다른 후보의 부분 통과를 합치거나 공개 설치 전 로컬 검증을 공개 배포 완료라고 부르지 않는다.

## 3. 준비 — 변경 보존과 재현 고정

1. 두 저장소의 HEAD/status·해시 입력 목록, 의존성 해석 경로, toolchain/SDK/runtime·scheme/destination을 새로 기록한다. 로컬 경로 의존성과 공개 버전 소비를 구분한다.
2. 재검토 디렉터리의 false-COMPLETE 입력, macro plain/manual/macro fixture, `DiagnosticDropProbe.swift`를 최소 정식 회귀로 옮길 위치를 정한다. 원본 실패 로그는 덮어쓰지 않는다.
3. Apple/물별 수정 전 해당 저장소 지침과 현재 QA·프로젝트 정의를 확인한다. 테스트만 다른 구현을 호출하는 우회 경로를 만들지 않는다.
4. 빌드 경로를 toolchain·configuration·platform별로 분리하고 무거운 빌드는 jobs 1을 기본으로 한다. 다른 활성 빌드·테스트를 종료하거나 캐시를 지우지 않는다.
5. 실행 기록 상태는 `미착수 / 진행 중 / 수정 완료·검증 대기 / 검증 통과 / 실패 / 환경·승인 대기`로 통일한다. 문서의 Draft/Reviewed/Approved와 구분한다.

## 4. R25 — 증거 검사기의 완전성·실행 결과 연결

변경 대상:

- [verify-release-evidence.sh](../scripts/verify-release-evidence.sh), [self-test](../scripts/verify-release-evidence-selftest.sh), [candidate hash](../scripts/release-candidate-hash.sh).
- [principle-gates-lib.sh](../scripts/principle-gates-lib.sh), [principle-gates-selftest.sh](../scripts/principle-gates-selftest.sh), [RELEASING.md](../RELEASING.md).
- 신규 후보: `docs/contracts/release-evidence-policy.json`, `scripts/record-release-evidence.sh`, 작은 입력 fixture 디렉터리. 기존 스크립트와 역할을 중복하지 않도록 구현 시작 때 최종 파일 분리를 확정한다.

1. manifest와 독립된 버전 관리 정책에 필수 check ID, 환경 키, 증거 종류, 검증 단계, 허용되는 N/A 조건을 선언한다. manifest의 `required/optional` 값이 필수성을 결정하지 못하게 한다. 필수 집합 축소는 정책 변경·리뷰 대상으로 드러나야 한다.
2. 환경 키는 check ID + toolchain + platform/runtime + configuration + consumer/scenario를 구별한다. R30의 기기·언어·테마·글자 크기 조합과 macOS UI·실패 복구·VoiceOver를 별도 필수 항목으로 선등록한다. 33행이라는 과거 숫자를 새 기준으로 고정하지 않는다.
3. producer가 실행 명령/인수, 시작·종료 상태와 exit code, toolchain/OS/SDK, 테스트 ID·pass/fail/skip 수, 정책 버전, 후보 식별자, 로그/xcresult의 상대 경로와 SHA-256을 receipt로 기록한다. 실행 중단·부분 파일은 PASS가 될 수 없고 receipt 확정은 원자적으로 처리한다. 비밀값이나 사용자 데이터를 명령·로그에 남기지 않는다.
4. verifier는 receipt·artifact 체크섬뿐 아니라 증거 종류별 실제 결과를 검증한다. xcresult의 실패/skip/discovery와 테스트 로그의 종료 결과가 summary와 모순되면 실패한다. 파서 오류·지원하지 않는 schema·0개 테스트는 합격이 아니다. 단순 로그 존재 확인이나 `PASS` 문자열 검색으로 대체하지 않는다.
5. 두 저장소를 `primary/consumer` 같은 안정된 논리 이름으로 식별하고 각각의 파일 목록·component digest·HEAD/dirty를 보존한다. aggregate 후보는 두 component와 정책 버전에 연결한다. CI의 단일 Git SHA와 로컬 dirty aggregate를 같은 값이라고 가정하지 않는다. 원격 검증 후보는 실제 checkout digest 및 정확한 consumer revision/digest로 다시 검증한다.
6. 소스·테스트·빌드 입력·workflow·검증 정책은 후보 범위에 포함한다. 생성 receipt/로그/결과 summary는 지정 ignored artifact 영역에 두어 자기참조 해시를 만들지 않는다. 문서까지 포함하는 현재 해시에서는 문서 변경도 후보 변경이다. 새 보고서를 이전 해시의 증거로 재표기하지 않는다.
7. manual 증거는 자동 테스트 PASS와 구분한다. 시나리오·환경·후보·검토자·검토일·실제 관찰 및 첨부물 해시를 가진 attestation으로 받으며, 빈 체크박스나 일반 배포 승인으로 대체하지 않는다. 로컬 파일 체크섬만으로 검토자 신원을 증명할 수 없다는 한계를 명시하고 원격 신뢰 경계는 R26에서 승인된 producer/검토 경로로 제한한다.
8. artifact 경로는 지정 evidence root 내부로 제한하고 경로 이탈·바깥을 가리키는 symlink·누락/빈 파일을 거절한다. 알 수 없는 ID/중복 키/필수 강등/잘못된 상태/열 수 불일치를 검출하며 마지막 개행 없는 행도 빠뜨리지 않는다.

필수 회귀: 완전한 정상 집합 PASS; 실패 6행 삭제·PASS 1행만 유지·실패 xcresult를 PASS로 표기한 세 재현은 모두 실패. 추가로 duplicate, required→optional, unknown ID/status, 필수 SKIP/BLOCKED/N/A, malformed TSV, 마지막 행 개행 없음, 잘못된 후보·artifact digest·환경, receipt 중단, 파일 누락·경로 이탈, policy mismatch를 검사한다. 허용 N/A는 사전 정책과 해당 환경에서만 인정하며 사용자 입력으로 필수 항목을 사라지게 하지 않는다.

완료 조건: AC-R025와 self-test가 실제 검사기를 호출해 통과하고, 실패한 원본 6행이 남은 기존 후보는 여전히 미완료여야 한다. 증거 형식만 바꿔 기존 실패를 합격시키지 않는다.

## 5. R26 — 배포 workflow에 독립 증거 gate 연결

변경 대상: [cd.yml](../.github/workflows/cd.yml), [ci.yml](../.github/workflows/ci.yml), [principle-gates.sh](../scripts/principle-gates.sh), 해당 구현/self-test, [RELEASING.md](../RELEASING.md). 신규 workflow 제어 흐름 회귀는 기존 gate self-test 구조를 재사용한다.

1. 각 검사 job이 R25 형식의 receipt와 artifact를 보존하고, 별도 `release-evidence` job이 필요한 결과를 모아 배포 전 정책을 검증하게 한다. 일부 matrix 실패·취소 때도 진단 artifact는 수집하되 수집 성공을 검사 성공으로 취급하지 않는다.
2. `publish-release`의 `needs`에 증거 job을 포함하고 성공 조건을 명시한다. `always()`나 `continue-on-error` 등으로 실패/skip을 publication까지 전파하지 않는 우회가 없는지 모든 경로를 확인한다. publication에 필요한 `contents: write`는 해당 job에만 유지한다.
3. artifact는 정확한 repository/ref/SHA·workflow run/attempt·후보 digest로 선택한다. 이름만 같은 이전 실행, 다른 태그, 다른 consumer revision, 미신뢰 producer의 파일을 가져오지 않는다. 로컬 attestation의 신뢰 가능한 전달·검토 경로가 없으면 원격 gate는 BLOCKED다.
4. 검증 단계를 고정한다: `local-preflight`는 로컬 코드/소비자 필수 검사, `pre-publication`은 이에 대응하는 후보 증거와 정확한 원격 CI·태그/API baseline·필요한 서명·수동 검토, `post-publication`은 실제 공개 태그/배포물의 독립 설치 확인이다. 서명은 배포물이 요구하는 경우만 정책으로 구분한다. SPM 소스 배포에 앱 서명을 무조건 요구하지 않는다.
5. 공개된 버전으로만 가능한 설치 확인을 publication 선행 조건에 넣지 않는다. 반대로 공개 설치가 안 된 상태를 공개 배포 검증 완료로 표시하지 않는다. 사전에는 고정된 후보 revision의 독립 consumer 설치/빌드를 수행한다.
6. 현재 scheme·runner·toolchain 선택이 정책과 맞는지도 대조한다. 존재하지 않는 scheme, 최신 runtime으로 최소/이전 runtime을 대체한 결과, Swift language mode로 정확한 compiler 버전을 대신한 결과는 통과시키지 않는다.
7. 로컬 제어 흐름 회귀에서는 증거 job 제거, `needs` 누락, 실패/skip/누락 artifact를 넣으면 publication 조건 검사가 실패해야 한다. 승인 후 원격 `workflow_dispatch`의 무배포 경로로 실제 artifact 전달을 확인하고, 태그 publication 경로는 별도 승인 전 실행하지 않는다.

완료 조건: AC-R026의 로컬 workflow 계약 검증과 실제 원격 검증 상태를 분리한다. YAML 텍스트에 verifier 이름이 있다는 이유만으로 연결 완료라고 판단하지 않는다. 원격 승인 전에는 `로컬 구현·검증 통과 / 원격 증거 대기`까지만 기록한다.

## 6. R27 — compiler 조건의 배타성 및 실제 충돌 유지

변경 대상: [OutputPathSynthesis](../Sources/InnoFlowMacros/InnoFlowMacro+OutputPathSynthesis.swift), [CompileContractTests](../Tests/InnoFlowTests/CompileContractTests.swift), [OutputCasePathTests](../Tests/InnoFlowTests/OutputCasePathTests.swift), [macro tests](../Tests/InnoFlowMacrosTests/InnoFlowMacrosTests.swift), [CLAUDE.md](../CLAUDE.md), [MACRO_OPERATIONS.md](MACRO_OPERATIONS.md), 관련 principle/CI gate.

1. `arch(arm64)`/`arch(x86_64)`, `swift(>=6.0)`/`swift(<6.0)`의 plain 성공·macro 실패 fixture를 먼저 편입한다. active helper를 실제 호출하고 extract/embed 결과도 검증한다.
2. 기존 조건 표현에 알려진 단일값 compiler predicate(`os`, `arch`, `targetEnvironment`)와 `swift`/`compiler` 버전 경계 관계를 모델링한다. 공백·괄호·부정·중첩·서로 겹치는 범위를 포함한다. 현재 호스트 평가로 비활성 소스를 없애지 않는다.
3. 증명된 배타성·증명된 충돌·관계 미확정을 구분한다. 미확정 또는 복잡도 한도 초과를 곧바로 충돌로 바꾸지 않는다. 원래 조건을 보존한 helper를 생성하여 compiler가 활성 선언을 판정하는 fallback을 검증한다. helper를 전부 삭제하거나 모든 충돌 진단을 끄는 fallback은 금지한다. 유효성 보존이 안 되는 경우는 구체적인 제한·대안을 제시하고 해당 AC를 열린 상태로 남긴다.
4. 수동 helper의 조건부 억제, 이름 정규화·marker, public/package/generic에도 같은 판단을 적용한다. 범용 SAT 엔진·새 외부 의존성은 도입하지 않고 계산량 한도와 fallback을 테스트한다.

필수 회귀: 기존 2-flag 4조합/3-flag 8조합 유지; arch의 실제 두 target compile, simulator/device targetEnvironment, swift/compiler 버전의 경계·비중첩/중첩, if/elseif/else·독립/중첩 조건, 조건부 manual helper. 진짜 동시에 활성인 이름 충돌 음성군도 유지한다. plain/manual/macro를 독립 compiler로 비교하고, negative는 plugin 로딩 오류가 아니라 의도한 충돌 진단인지 확인한다. 실행 환경이 없는 target은 build 또는 미검증으로 정확히 구분한다.

완료 조건: AC-R027 및 기존 AC-R019/020 회귀 통과. 매크로 snapshot 성공만으로 닫지 않는다.

## 7. R28 — 일반 앱과 App Extension 가용성 구분

변경 대상: R27의 매크로·compile/expansion 테스트·계약 문서와 공유한다. R27을 먼저 안정화한 뒤 같은 파일을 수정한다.

1. `@available(macOSApplicationExtension, unavailable)` case의 일반 앱 plain/manual/macro fixture와 `-application-extension` 소비 음성군을 고정한다.
2. case의 availability를 helper 선언에 의미 그대로 전달한다. extension domain을 모르는 OS로 취급해 helper 전체를 제거하지 않는다. 존재하지 않는 `#if appExtension` 같은 조건을 만들지 않고 Swift availability와 compiler의 extension 검사를 사용한다.
3. 도입/폐기 버전, unavailable, message/renamed, 조건부 attribute·opt-out·manual helper와의 조합을 점검한다. Swift가 허용한 알려지지 않은 domain을 임의로 전역 unavailable로 해석하지 않는다. 처리 불가 시 의미를 바꾸거나 무음 누락하지 않고 제한을 드러낸다.
4. 현재 지원 SDK에서 compiler가 인정하는 iOS/macOS/tvOS/watchOS/visionOS 및 Catalyst 관련 extension domain을 확인해 적용한다. 모든 domain 이름이 모든 SDK에서 지원된다고 가정하지 않는다. 적용 불가 항목은 compiler 근거와 정책 N/A를 남긴다.

필수 회귀: 정상 앱의 helper 존재·round-trip, extension에서 금지된 helper 사용의 의도한 compiler 실패, extension-safe case의 성공, public/package/generic, 두 availability의 혼합과 최소 deployment target. 정상 앱을 허용하려고 extension 보호가 사라지는 반례도 검사한다.

완료 조건: AC-R028과 기존 AC-R021/022를 함께 충족한다. 단순 missing-member 오류를 availability 음성군의 성공으로 세지 않는다.

## 8. R29 — 취소된 queued action의 dispatch 진단 연결

변경 대상: [Store.swift](../Sources/InnoFlowCore/Store.swift), [DispatchContext.swift](../Sources/InnoFlowCore/DispatchContext.swift), [StoreDiagnostics.swift](../Sources/InnoFlowCore/StoreDiagnostics.swift), [FlowTaskCancellationBoundaryTests](../Tests/InnoFlowTests/FlowTaskCancellationBoundaryTests.swift), [DispatchDiagnosticsTests](../Tests/InnoFlowTests/DispatchDiagnosticsTests.swift). 원인 수정은 queue drop context 전달을 우선하며 진단 구조 전체를 재설계하지 않는다.

1. public Store에서 emission 직후 취소·queue drain 순서를 명시적 readiness/release signal로 재현한다. 고정 sleep이나 private 상태 강제 주입을 주된 증거로 쓰지 않는다.
2. `.cancellationBoundary`로 버릴 때 queued action의 tracker를 context에 전달하여 원래 dispatch와 연결한다. 이미 반영된 state rollback이나 추가 cancellation을 넣지 않는다.
3. run의 첫 action과 그 action이 만든 즉시 `.send` 후속 action 두 경로 각각에서 drop event 1개, nil 아닌 원래 DispatchID, 대응 diagnostics record 1개를 확인한다. reduce/output은 취소 경계를 넘지 않아야 한다.
4. sibling dispatch의 작업·진단 유지, finish 이후 늦은 drop이 active dispatch를 부활시키지 않음, history 한도·해제·진단 비활성화 경로를 검증한다. payload 기록이나 unbounded tracker 보관을 추가하지 않는다.

완료 조건: AC-R029, 기존 scheduler/scope/diagnostics/cancellation 집중군과 관련 TSan/ASan이 통과한다. 실제 취소 실패와 관측 누락을 혼동하지 않고 수정 결과를 기록한다.

## 9. R30 — 접근성 원본 집계와 물별 실제 UI 계약 완성

변경 대상:

- 물별 [AccessibilityAuditUITests.swift](/Users/changwooson/Developer/InnoSquad/Projects/Mulbyul/Apple/App/UITests/Sources/AccessibilityAuditUITests.swift), [TrainingRecordsNavigationUITests.swift](/Users/changwooson/Developer/InnoSquad/Projects/Mulbyul/Apple/App/UITests/Sources/TrainingRecordsNavigationUITests.swift), [audit 실행 스크립트](/Users/changwooson/Developer/InnoSquad/Projects/Mulbyul/Apple/Scripts/run_ios_accessibility_audits.sh).
- [TrainingRecords feature](/Users/changwooson/Developer/InnoSquad/Projects/Mulbyul/Apple/Features/TrainingRecords/UIs/Shared/TrainingRecordsFeature.swift), [load owner](/Users/changwooson/Developer/InnoSquad/Projects/Mulbyul/Apple/Features/TrainingRecords/UIs/Shared/TrainingRecordsLoadLifecycle.swift), 관련 iOS/shared/macOS 화면. 제품 수정은 실제 재현된 실패의 원인 파일에 한정한다.
- 물별 [QA 문서](/Users/changwooson/Developer/InnoSquad/Projects/Mulbyul/Apple/docs/TRAINING_RECORDS_QA.md), InnoFlow [QUALITY_REVIEW_6_0.md](QUALITY_REVIEW_6_0.md), R25 정책/receipt producer.
- 신규 후보: 물별 `Apple/Scripts/summarize_training_records_audits.sh` 및 작은 sanitized xcresult JSON fixture, 필요한 macOS UI-test target/시나리오. target 정의가 필요하면 [App/Project.swift](/Users/changwooson/Developer/InnoSquad/Projects/Mulbyul/Apple/App/Project.swift) 등 정식 정의를 수정한다.

### R30-A — UI 수정 전에 집계 기준 고정

1. canonical 실행을 후보+환경+시나리오+attempt ID로 고정한다. 재실행은 이전 결과를 보존하고 전체 해당 시나리오를 대체하는 관계를 기록한다. 여러 실행에서 성공한 assertion만 골라 한 번의 통과로 만들지 않는다.
2. 원본 xcresult의 test ID·failure ID·첨부물과 raw audit callback을 연결한다. raw/ignored/보호 대상 실패/전체 제품 실패/timeout·실행 오류/skip/미실행을 분리한다. 반복 발생 수와 고유 결함 분류는 별도 지표다.
3. 기존 10개 결과로 실패 10/10, 제품 실패 메시지 131건, timeout 3건을 재현한다. raw 151건과의 차이를 설명하고 기존 QA 문서의 timeout 1건 기록을 날짜·원본 링크를 가진 정정 기록으로 보완한다. 과거 산출물을 덮어쓰지 않는다.
4. 집계 회귀에는 복수 timeout, ignored issue, 같은 surface 반복, 실패/성공 재시도, missing/corrupt JSON, schema 변경, 0개 test를 포함한다. 원본 수와 안 맞거나 파싱을 못 하면 summary를 PASS로 만들지 않는다.

### R30-B — 필수 접근성 조합과 제품 수정

- iPhone/iPad 각각 `light/dark × 기본/최대 지원 글자 크기 × ko/en/ar` 12조합, **총 24조합**을 독립 ID로 등록한다. Reduce Motion은 이 조합 수에 섞어 세지 않고 별도 대상 회귀로 유지한다. 작은 iPhone 화면·iPad 좁은 창·긴 Arabic RTL도 명시적으로 실행한다.
- 보호 대상은 root `100%`, row `01:30`/`4/4`, detail summary `4/4`, set status `성공`, More/편집 Save다. 안정된 ID와 실제 화면 위치를 확인하고 safe visible region 안에서 완전 노출 후 audit한다. 미발견·스크롤 실패·잘림을 skip 처리하지 않는다.
- 대비/글자 확대/잘림을 분리해 재현한 뒤 해당 텍스트 색·레이아웃·semantic text 사용을 수정한다. 기존 대비 기준과 실제 44×44pt 조작 영역 검증을 유지한다. 보호 대상 issue를 nil identifier allowance나 새 ignore에 숨기지 않는다.
- 전체 앱 audit와 TrainingRecords 전용 audit는 별도 결과로 유지한다. 무관한 Settings 실패를 고치기 위해 범위를 자동 확장하거나 전체 앱 결과를 TrainingRecords 합격으로 덮어쓰지 않는다. 전체 앱 필수 gate에 실패가 남으면 그 gate는 열린 상태다.

### R30-C — 실제 복구·내비게이션·macOS·VoiceOver

1. iPhone/iPad/macOS 실제 화면에서 초기 로드 실패→오류 표시→재시도 성공, 성공 후 저장/삭제→재조회→정확한 목록·선택 갱신, 이탈→복귀→새 요청, 이전 비협조적 요청의 늦은 응답이 현재 화면을 덮지 않는 흐름을 검증한다. empty CTA·상세·편집·저장·삭제·back 기존 회귀도 유지한다.
2. 실패/대기/늦은 응답 제어는 UI 테스트용 주입 repository가 실제 feature/owner 경로를 사용하도록 구현한다. production 네트워크나 사용자 데이터를 변경하지 않는다. 제어 hook은 production 배포 경로에서 비활성/미포함이며 테스트가 제품 코드를 우회하지 않음을 확인한다. 테스트 데이터와 요청 카운터를 실행별로 격리한다.
3. 세 timeout의 요소 탐색·스크롤·전이 완료 조건을 조사하고 명시적 화면 상태를 기다리도록 수정한다. timeout 상향만으로 원인 수정을 대신하지 않는다. 수정된 시나리오는 독립 실행 3회 연속 확인하고 최종 전체 matrix에도 포함한다.
4. macOS는 실제 앱에서 좁은 창, 키보드 이동/활성화·포커스, 상세/편집/저장/삭제/복귀와 실패 복구를 확인한다. feature 테스트 37개나 SDK compile을 UI 증거로 대신하지 않는다. iOS 글자 크기 축과 동일하지 않은 설정은 macOS에 적용 가능한 값을 명시한다.
5. VoiceOver는 실제 탐색으로 대상 라벨·값·상태·읽기 순서, 상세 열기/닫기·More·편집 후 포커스 복귀를 확인한다. 지원 iPhone/iPad/macOS의 관련 경로, 장치·OS·언어·수행자·결과를 남긴다. 자동 audit·스크린샷은 보조 증거이지 실제 VoiceOver 사용의 대체물이 아니다.

완료 조건: AC-R030과 SC-FU008, 기존 AC-R023을 충족한다. 시스템 false positive에 예외가 필요하면 최소 독립 재현·영향·환경·재검증 조건을 보고하고 별도 승인 전에는 합격시키지 않는다. 환경이 없는 항목은 R31에 BLOCKED로 전달한다.

## 10. R31 — 최종 후보 통합 검증과 완료 판정

앞선 단계에서 집중 회귀가 안정된 뒤 후보 입력을 고정하고 아래를 실행한다. 테스트 수는 감소 탐지용 보조 값이며, 필수 테스트 ID·환경 discovery와 실패/skip이 실제 합격 기준이다.

| 검사 묶음 | 필수 범위와 증거 |
| --- | --- |
| 정적/계약 | 두 저장소 diff check, format/doc contract, principle static 및 self-test, R25/R26 음성군, 문서·정책·workflow 정합성 |
| 전체 package | Debug/Release 전체 principle gate, 성능 기준, canonical sample, compiler-plugin-free Core와 macro source fallback. 새 회귀 discovery 확인 |
| 매크로 소비자 | public/package/generic, 기존 Boolean matrix, R27 compiler predicate, R28 일반/extension 허용·금지 대조군. 원인 진단과 active helper 사용 확인 |
| Toolchain | 정확한 Swift 6.3 및 6.4로 package/macro consumer/집중 runtime. 설치되지 않았다면 환경 대기이며 버전 선언이나 language mode로 대체 금지 |
| SDK | iOS 18/macOS 15/tvOS 18/watchOS 11/visionOS 2 deployment target을 유지한 5 SDK build. build와 runtime 결과 구분 |
| Runtime | 현재 macOS, iOS/tvOS/watchOS/visionOS의 가용 27.0 계열과 이전 18.5/11.5/2.5 계열 8개 simulator 환경에서 scheduler/scope/diagnostics/Output 집중군. 최소 OS patch·실기기까지 검증한 것으로 확대 해석 금지 |
| Sanitizer | 독립 경로 TSan/ASan의 scheduler/diagnostics/FlowTask/FlowScope 및 가능한 실제 consumer owner 경계. 미실행 범위 별도 표기 |
| 물별 feature/UI | 정확한 로컬 후보를 쓰는 공식 TrainingRecords scheme의 iOS/macOS feature/owner, R30 UI/24조합/macOS/VoiceOver. 관련 앱 build도 확인 |
| 배포 전/후 | R26 정책별 원격 CI·태그/API baseline·필요 attestation/서명 및 배포 후 공개 설치. 승인 전에는 실행하지 않고 대기 상태 유지 |

실행·기록 규칙:

1. 필수 목록은 R25의 독립 정책에서 생성하고 각 실행이 남긴 receipt와 대조한다. 실패 때문에 목록을 줄이거나 증거 없이 상태만 PASS로 바꾸지 않는다.
2. 후보 고정 후 소스·테스트·정책·workflow·해시 대상 문서가 바뀌면 새 후보로 인식한다. 개발 중 영향 검사와 최종 동일 후보 검증을 구분하고, 최종 합격에는 변경 후 필수 gate를 다시 실행한다. 이전 로그의 후보 식별자를 고쳐 재사용하지 않는다.
3. 최종 결과는 우선 ignored evidence 디렉터리에 확정하여 해시 자기참조를 피한다. 추적 문서에 결과를 기록할 때는 검증한 후보와 이후 문서 변경을 구분한다. 문서를 포함한 최종 배포 revision의 판정은 그 revision으로 다시 실행하는 승인된 CI gate가 책임진다.
4. `QUALITY_REVIEW_6_0.md`, 물별 QA, RELEASING 및 본 계획 실행 기록에 통과·실패·환경/승인 대기를 일치시킨다. 독립 verifier가 미완료인데 보고서만 완료라고 쓰지 않는다.
5. 보고서는 변경 파일, 결함별 수정 전/후 증거, 지원 환경별 실행/미실행, 원본 위치, 남은 gate와 필요한 결정, Git 변경 범위를 포함한다. 큰 xcresult는 추적 소스에 넣지 않고 artifact로 보존한다.

완료 명칭은 다음을 구분한다.

- **계획 작성 완료:** 이 Draft와 추적표·반례·문서 검사가 준비됨. 구현 또는 승인 완료를 뜻하지 않음.
- **코드 수정 완료:** R25~R30의 구현과 정식 집중 회귀·관련 문서/게이트 반영이 끝남. 미실행 UI/환경이 있으면 검증 상태를 별도 명시함.
- **전체 로컬 검증 완료:** AC-R025/027~031의 로컬 필수 조건과 R26 로컬 계약 검사, SC-FU007~009가 최종 로컬 후보에서 통과함. 필수 VoiceOver·툴체인·runtime 등이 열려 있으면 이 명칭을 사용하지 않음.
- **배포 준비 완료:** 별도 승인된 정확한 배포 후보의 pre-publication 조건과 원격 실행이 모두 통과함. 아직 공개 배포 완료는 아님.
- **공개 배포·설치 검증 완료:** 별도 승인된 publication 및 post-publication 독립 설치가 실제 성공했을 때만 사용함.

## 11. 계획 반례 검토와 중단 조건

아래가 가능하면 계획대로 형식만 지켰어도 의도한 품질을 충족하지 못한다. 관련 AC를 닫지 않고 설계·테스트를 보완한다.

| 형식적 통과의 반례 | 이를 막는 조건 |
| --- | --- |
| 실패 행·누락 환경을 manifest에서 지워 COMPLETE를 얻음 | AC-R025: 독립 정책·환경 집합과 정확 대조, 누락/강등 음성군 |
| 실패 artifact의 status와 후보 문자열만 바꿔 제출함 | AC-R025/026: 실행 receipt·원본 결과·digest·신뢰된 producer/run 식별 |
| verifier job은 있지만 publication의 선행 조건이 아님 | AC-R026: 실제 제어 흐름과 실패/skip 전파 검증 |
| 공개 후에만 가능한 설치를 배포 전에 요구해 영구 차단됨 | AC-R026/031: pre-/post-publication 분리, 사전 고정 revision 소비 검증 |
| 로컬 dirty 후보와 다른 tag SHA의 테스트를 섞음 | AC-R025/031: component digest·의존성 revision·후보/정책 연결 |
| arch 반례만 하드코딩하거나 모든 충돌 진단을 끔 | AC-R027: 알려진 조건 관계, 미확정 fallback, 실제 활성 충돌 음성군 |
| 일반 앱 helper를 살리면서 extension에서도 금지 API를 허용함 | AC-R028: 일반 앱 양성 및 extension의 의도한 가용성 음성군 |
| drop ID는 남지만 sibling이 종료되거나 late event가 active를 부활시킴 | AC-R029: 상태/output·sibling·종료·보관 한도 회귀 |
| 24조합 이름만 있고 실제로 같은 환경을 24번 실행함 | AC-R030/031: receipt의 실제 locale/theme/content-size/device 및 UI 상태 대조 |
| 화면을 못 찾거나 timeout 난 audit를 집계에서 제외함 | AC-R030: 원본 test 수·실패·timeout·미실행 보존, 파서 fail-closed |
| UI 주입 경로만 성공하고 실제 scene은 다른 owner를 사용함 | AC-R030: 제품과 동일 feature/owner 경로·실제 내비게이션 증거 |
| 자동 audit 통과를 VoiceOver/macOS UI 통과로 보고함 | AC-R030/031: 별도 실제 탐색·창/키보드 증거와 required ID |
| 마지막 수정 전 여러 후보의 성공만 합쳐 최종 완료라 보고함 | AC-R031: 최종 입력 고정·후보 변경 무효화·단계별 완료 명칭 |

환경 부재·권한 대기에서는 가능한 다른 로컬 작업을 진행하되 해당 필수 gate는 열린 채 보고한다. 테스트 삭제·플랫폼 축소·예외 추가·계약 변경·외부 실행이 필요하면 정확한 이유와 영향, 필요한 결정을 제시하고 그 변경 전에 멈춘다. 실행 승인이 있어도 새로운 제품 기능이나 공개 배포까지 범위를 넓히지 않는다.

## 12. 실행 기록

2026-09-09 로컬 실행 결과다. `검증 통과`는 명시한 로컬 범위만 뜻하며 원격·수동·공개 배포 gate를 닫지 않는다.

| 작업 | 현재 상태 | 다음 증거 |
| --- | --- | --- |
| IF6-R25 | 로컬 검증 통과 | 독립 policy, receipt/artifact digest, xcresult 의미 판독, 경로 이탈·누락·강등·거짓 PASS 음성군을 `verify-release-evidence-selftest.sh`로 재검증했다. 원격 신뢰 producer 증거는 R26에 남는다. |
| IF6-R26 | 로컬 검증 통과 / 원격 대기 | publication이 `release-evidence` 성공에 fail-closed로 의존하는 workflow 계약과 누락 회귀가 통과했다. 실제 원격 artifact producer/run, 승인, 태그 실행은 미실행이다. |
| IF6-R27 | 검증 통과 | `arch`, `targetEnvironment`, `swift`, `compiler` 배타·중첩 조건을 외부 compiler consumer와 macro 회귀에 편입했고 Debug/Release 전체 gate에서 통과했다. |
| IF6-R28 | 검증 통과 | 일반 앱 허용과 `-application-extension` 금지 대조, 조건부 availability 보존이 외부 consumer 및 전체 gate에서 통과했다. |
| IF6-R29 | 검증 통과 | public Store의 queued cancellation drop이 원래 DispatchID를 보존하는 두 경로와 sibling/상태/output 계약이 집중·전체 회귀에서 통과했다. |
| IF6-R30 | 자동화 부분 통과 / 환경·승인 대기 | 과거 10개 실패 집계 재현, iPhone/iPad 각 12개 release matrix, iPad frame/retry/split 3회 반복, iOS 59/59와 macOS 37/37 기능 테스트가 통과했다. 제한된 nil-identifier audit 예외는 별도 소유자 승인이 없고, 잠긴 Mac의 system authentication 때문에 macOS UI runner는 test discovery 전에 차단됐으며, 실제 VoiceOver는 미실행이다. |
| IF6-R31 | 로컬 자동 검증 통과 / 전체 완료 대기 | Swift 6.4/Xcode 27에서 TSan·ASan 각 777/777, Debug/Release 각 777/777, 5 SDK build, 8 runtime 각각 53/53, 성능·sample·정적/self-test가 통과했다. 격리된 최신 원격 Mulbyul에서 iOS/macOS feature와 iPhone UI·audit 시나리오를 확인했지만 최신 원격 iPad/macOS 실제 UI는 미실행이다. 정확한 Swift 6.3, 수동/원격/태그/API/public-install gate는 열려 있다. |

보존 증거는 `.build/release-evidence-r31/`에 있다. 물별 결과는 `Apple/.build/r30-*`와 `Apple/.build/r31-trainingrecords-{ios,macos}.xcresult`에 있다. 물별 로컬 checkout은 fetched `origin/main`보다 6 commits 뒤지만, 격리된 `origin/main` 00313ffa에 현재 Apple patch와 로컬 InnoFlow를 적용한 결과도 `.build/release-evidence-r31/origin-main-integration/`에 보존했다. 그 격리본은 feature iOS 59/59·macOS 37/37, 실패→재시도 UI, iPhone audit 11개 연속 통과와 cold-timeout 1개 시나리오의 보존 재시도 1/1을 통과했다. 이는 최신 원격 iPad·macOS 실제 UI 또는 단일 12/12 matrix 증거가 아니다.

문서 승인 기록 없이 상태를 Reviewed/Approved로 올리지 않는다. 구현 검증 시에는 이 계획과 실제 코드·테스트를 다시 대조하고, 구현에 맞추기 위해 완료 조건을 사후 축소하지 않는다.
