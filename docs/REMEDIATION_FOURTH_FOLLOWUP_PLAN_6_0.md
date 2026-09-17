# InnoFlow 6.0.0 — 검증 신뢰성·매크로 호환성 추가 수정 계획

- 문서 상태: **Draft**, 2026-09-10. 실행 상태: **로컬 hardening 구현·검증 진행 / 배포 gate 미충족**.
- 잔여 작업 계획: [배포 차단 조건 해소 — IF6-R39~R45](RELEASE_BLOCKER_PLAN_6_0.md), 2026-09-11. R33의 명령 실행 계약을 재개하고 R34/R37/R38의 미완료 작업을 구체화한다. 아래 실행 이력은 보존하되 최신 완료 판정은 잔여 계획을 따른다.
- 결정권자: 프로젝트 소유자. 구현 담당: 후속 실행 담당자. 검토자·승인일: 미기록.
- 목적: 최근 재검토의 F1~F7을 수정하고, 기존 6.0.0 계약을 동일 후보의 실제 결과로 검증한다. 새 제품 기능을 추가하는 계획이 아니다.
- 요구사항: [기존 구현 계획](IMPLEMENTATION_PLAN_6_0.md)의 FR-001~007/NFR-001~005와 [첫 후속 계획](REMEDIATION_FOLLOWUP_PLAN_6_0.md)의 FR-008을 계승한다. 새 작업은 **IF6-R32~R38**, 완료 조건은 **AC-R032~038**이다.
- 기존 상태 정정: [세 번째 후속 계획](REMEDIATION_THIRD_FOLLOWUP_PLAN_6_0.md)의 R25/R27/R28은 재개, R26은 구현·회귀 보완 필요, R30/R31은 미완료다. R29의 과거 집중 검증은 보존하되 최종 후보 회귀에는 다시 포함한다.
- 감사 출처: 2026-09-09 추가 검토 및 재현 파일의 당시 경로는 `/private/tmp/innoflow-review-Sd4GP5/REVIEW.md`다. 2026-09-11 확인 시 해당 임시 파일은 남아 있지 않다. 아래에 보존한 재현 조건과 정식 fixture를 사용하며, 임시 보고서 원본이 현재 존재한다고 간주하지 않는다. 이 문서의 F 번호는 해당 보고서 기준이다.

## 1. 현재 사실과 작업 경계

### 확인한 사실

| 항목 | 기준 |
| --- | --- |
| InnoFlow | HEAD `00a73ed2d2cb94114b0be5c9fbd59c187a4b67c7` 및 기존 dirty/untracked 변경. 계획 작성 전 상태 항목 168개 |
| Mulbyul | HEAD `092ff9514695ceae5cfd490388e017fac331e30a` 및 기존 변경. 상태 항목 39개. Apple package는 로컬 InnoFlow를 소비 |
| 원격 비교 | 직전 검토의 fetch 기준 InnoFlow는 origin/main과 동일, Mulbyul은 `00313ffa7f02bf2975b33cb4384a4ae32aa980d3`보다 6 commits 뒤. 계획 작성 중 별도 원격 실행은 하지 않음 |
| 직전 감사 후보 | 두 저장소 aggregate `87f38486cc071834a960a9b84a97a9402f748a1fd3575f3f039cf4b03ba467b2`. **이 문서 추가 전 후보**이며 최종 수정 후보로 재사용하지 않음 |
| 기존 검사 | 직전 검토에서 static principle, evidence self-test, workflow 검사, 두 저장소 diff check가 통과했지만 새 반례를 검출하지 못함 |
| 컴파일 반례 | Xcode 27 / Swift 6.4에서 plain Swift 성공과 macro 실패를 대조. 예전 Swift 6.3.1 모듈은 현 toolchain 실행 증거가 아님 |

이번 요청의 활성 범위는 **InnoFlow docs / release 기술 계획**이다. 후속 구현 범위는 InnoFlow 매크로·검증 스크립트·CI/CD와 Mulbyul **Apple TrainingRecords 검증 경로**다. 원본 worktree의 무관한 변경, 생성 프로젝트, 별도 Kotlin/TypeScript 후보, Android/Web 제품은 수정·병합 대상이 아니다.

다음은 별도 승인 또는 환경 확인이 필요한 미확인 사항이다: 정확한 Swift 6.3 실행 환경, macOS UI·실제 VoiceOver 수행 수단, 물별 원격 증거 전달 권한, 신뢰할 producer/승인 경로, 접근성 예외의 독립 재현과 승인. 구현 담당자가 안전한 로컬 수단을 먼저 확인하고, 남은 선택·권한은 프로젝트 소유자에게 요청한다. 환경 부재를 필수 검사 삭제나 임의 N/A로 바꾸지 않는다.

커밋·푸시·원격 workflow 실행·태그·공개 배포·보안 설정 변경은 이 계획 작성으로 승인되지 않는다. 후속 로컬 구현 승인도 접근성 예외 승인이나 공개 배포 승인과 구분한다.

## 2. 결함 기준과 실행 순서

| 발견 | 수정 전 관찰 | 필요한 결과 |
| --- | --- | --- |
| F1 | 정식 56개 local ID의 실패 JSON을 기본 `command-exit`으로 기록해도 COMPLETE. expected failure/runtime warning도 허용. 반대로 정상 무출력 diff 검사는 거부 | 종류·환경·원본 결과가 맞는 실행만 합격, 정상 무출력 명령은 수용 |
| F2 | 독립 `#if targetEnvironment(simulator)`와 `#if targetEnvironment(macCatalyst)`의 같은 case 이름을 macro가 충돌로 진단 | 배타 조건의 유효한 선언/helper 유지, 실제 충돌은 거부 |
| F3 | iOS unavailable + Catalyst introduced case의 직접 사용은 Catalyst에서 성공하지만 helper는 누락 | 세부 플랫폼 availability override 보존 |
| F4 | xcodebuild exit 0 및 번들/summary 없음인 test double에서 접근성 12개 matrix가 exit 0 | 미실행·파서 실패·잘못된 결과를 runner 자체가 실패 처리 |
| F5 | verifier를 echo로 바꾸거나 다른 job에 needs 문자열을 옮겨도 workflow 검사 OK | 실제 job/step/의존 경로를 검증 |
| F6 | 로컬 aggregate와 CD의 Git SHA를 같은 candidate 필드로 사용. producer·component/provenance 연결 미완성 | 후보 내용과 저장소 revision을 연결한 실행·전달·검증 경로 |
| F7 | 최신 원격 물별 통합 결과에 summary 16개, xcresult 0개. R31에는 실제 실행 receipt manifest가 없음 | 원본 보존 후 정식 receipt·manifest로 최종 검증 |

**준비 → R32 → R33 → R34 → R35 → R36 → R37 → R38** 순서로 실행한다. R32에서 증거 계약을 고정하고, R33/R34에서 거짓 합격을 차단한 뒤 매크로를 고친다. R37에서 원격 연결의 로컬 구현·회귀를 끝내고 R38에서 최종 후보 검증을 수행한다. 원격 승인 대기는 명시한 채 가능한 로컬 R38 작업을 계속할 수 있지만 전체 완료로 닫을 수는 없다.

| 순서 / 작업 | 발견 → 요구사항 | 완료 조건 | 테스트·증거 |
| --- | --- | --- | --- |
| 1 / IF6-R32 | F6 → FR-007, NFR-001/005 | **AC-R032:** 후보 내용·consumer·정책·revision 관계를 재계산 가능하게 보존하고 변경/불일치를 거부 | `EV-CAND`: snapshot 결정성·변경·이식·revision 대조 |
| 2 / IF6-R33 | F1 → FR-001/007, NFR-005 | **AC-R033:** check ID별 허용 실행/형식/환경/원본 결과를 검증하며 무출력 성공을 오판하지 않음 | `EV-RESULT`: 거짓 PASS·정상 PASS·누락·경로·schema 회귀 |
| 3 / IF6-R34 | F4 → FR-007/008, NFR-003/005 | **AC-R034:** audit 결과·discovery·환경이 불완전하면 shell/Makefile/receipt 모두 실패하며 복구·원본 보존 | `UI-RUNNER`: 명령 test double와 작은 실제 UI 실행 |
| 4 / IF6-R35 | F2 → FR-006/007, 기존 AC-R027 | **AC-R035:** 배타적인 targetEnvironment helper를 보존하고 활성 충돌/조건부 manual 계약을 유지 | `MAC-COND`: plain/manual/macro compiler matrix |
| 5 / IF6-R36 | F3 → FR-006/007, 기존 AC-R028 | **AC-R036:** Catalyst override를 보존하면서 iOS·extension의 금지 사용과 버전 제한을 약화하지 않음 | `MAC-AVAIL`: 실제 target compile와 helper 사용 |
| 6 / IF6-R37 | F5/F6 → FR-007, NFR-005 | **AC-R037:** 신뢰된 producer부터 publication까지 실제 실패 전파·후보 연결을 검증. 로컬·원격 결과 구분 | `WF-GATE`: YAML 변이·실패/skip/cancel 및 provenance 회귀 |
| 7 / IF6-R38 | F7 → FR-001/007/008, 기존 AC-R030/031 | **AC-R038:** 동일 최종 후보의 필수 실행과 원본이 완전하며 단계별 판정이 일치 | `E2E-EVID`: 원본 이동/손상/재시도 회귀, 전체 후보 matrix |

테스트 라벨은 후속 구현 시 사용할 안정된 검증 묶음 이름이며 현재 테스트가 존재하거나 통과했다는 뜻이 아니다.

성공 기준:

- **SC-FU010:** F1~F5의 실행 반례와 F6/F7의 누락·불일치 반례가 정식 음성 회귀로 검출되고, 정상 대조군도 통과한다.
- **SC-FU011:** 정책의 필수 ID×환경 집합과 원본에서 발견한 실행 집합이 일치한다. 누락, 실패, 필수 skip, 미승인 예외는 전체 합격이 아니다.
- **SC-FU012:** source component·consumer·정책·실행 provenance·raw artifact가 하나의 후보로 연결되며, 결과 집계와 문서 판정이 다르지 않다.

## 3. 준비 — 재현·원본 보존을 먼저 고정

1. 두 저장소의 HEAD/status와 이번 변경 범위를 다시 확인한다. 원격 통합은 최신 상태를 읽은 뒤 격리 checkout에서 수행하고 원본 dirty worktree를 업데이트하거나 정리하지 않는다.
2. 감사의 `PredicateProbe.swift`, `AvailabilityProbe.swift`, `evidence-probe.rb`, `silent-check-probe.rb`, `workflow-probe.rb`, audit 명령 test double를 정식 fixture로 옮길 위치를 정한다. synthetic 증거에는 테스트 전용 표시를 유지하고 실제 release manifest에 합치지 않는다.
3. 첫 실행부터 checkout 밖의 지속 보존 evidence root를 사용한다. `candidate / check-id / environment / attempt`별 경로를 분리하고 원본을 덮어쓰지 않는다. 보존 실패 시 임시 checkout 제거를 진행하지 않는다.
4. 무거운 빌드는 jobs 1, toolchain/configuration/platform/sanitizer별 독립 경로로 실행한다. 기존 활성 빌드나 무관한 simulator를 종료하지 않는다. 실행기가 만든 리소스와 변경한 simulator 설정만 원래대로 복구한다.
5. 각 작업은 **수정 전 반례 → 원인 수정 → 정상·실패 대조 → 실제 실행 경로 → 관련 문서·gate** 순서로 닫는다. 자체 테스트가 통과했다는 이유로 실제 consumer/원격 실행 단계를 생략하지 않는다.

## 4. R32 — 후보 식별과 증거 계약

대상: [release-candidate-hash.sh](../scripts/release-candidate-hash.sh), 제거할 v1 TSV 정책, [RELEASING.md](../RELEASING.md). 신규 후보는 `docs/contracts/release-evidence-policy.json`과 공통 evidence helper/fixture다.

구현 방향:

1. shell 진입점은 유지하되 nested 환경·test ID·artifact 목록을 표현할 수 있는 버전 있는 JSON 정책/manifest/receipt 계약으로 정리한다. 기존 TSV와 신규 JSON을 두 개의 정책 원본으로 병행 유지하지 않는다. v1은 역사 조회용으로만 구분하고 v2 배포 검증에 묵시적으로 승격하지 않는다.
2. `primary`와 `consumer`의 정렬된 상대 경로·파일 종류/모드·내용 digest·의존성 lockfile을 보존한다. tracked 삭제, untracked 입력, symlink 처리와 generated/ignored 제외 규칙을 명시한다. 저장소 밖을 가리키는 입력은 대상 정책 없이 추적하지 않는다.
3. **content digest와 Git revision은 별도 필드**다. HEAD/dirty는 provenance이며 clean/dirty 표현 차이만으로 같은 내용이 다른 content digest가 되지 않게 한다. 서로 다른 내용의 remote 물별 패치 통합은 별도 후보로 기록한다.
4. aggregate는 두 component content digest와 정책 digest에 연결한다. 실제 소비 경로·resolved revision·빌드 설정이 기록된 입력과 일치해야 한다. receipt에 사용자가 후보 문자열을 넣는 것만으로 실행 후보를 입증하지 않는다.
5. 정책에는 필수 check ID, 허용 producer/명령 템플릿·인수, 결과 형식, 실제 toolchain/SDK/runtime/configuration, device/locale/theme/content-size/scenario, 필수 test ID 집합, skip/N/A/경고 정책을 선언한다. release entrypoint는 임의 fixture policy로 교체할 수 없어야 한다.
6. 원본 artifact의 상대 경로·종류·크기·digest와 bundle 파일 manifest를 정한다. 정상 0바이트 stdout과 누락/중단된 필수 파일은 구분한다. 생성 로그·receipt·결과 보고서는 해시 대상에서 제외하지만 소스·테스트·정책·workflow·빌드 입력·현재 포함된 문서는 유지한다.

회귀: 같은 내용/다른 절대 경로의 digest 일치; primary/consumer/lockfile/정책/실행 모드 변경 검출; 삭제·symlink·경로 이탈; component 교환; 잘못된 revision 매핑; 입력 목록 누락. 실행 전후 snapshot이 달라지면 해당 실행은 최종 증거가 아니다.

선택 이유: 기존 arbitrary command + 문자열 해시를 보강하는 방식보다 정책 기반 producer가 결과 종류와 환경을 강제하기 쉽다. 새 외부 검증 프레임워크는 도입하지 않고 현재 사용 중인 Ruby 등 표준 라이브러리 기반 공통 helper를 우선한다. 실패 시 legacy PASS로 fallback하지 않고 미완료를 반환한다.

## 5. R33 — 증거 생성·판정의 거짓 합격과 거짓 실패 제거

대상: [record-release-evidence.sh](../scripts/record-release-evidence.sh), [manual recorder](../scripts/record-manual-release-evidence.sh), [verifier](../scripts/verify-release-evidence.sh), [self-test](../scripts/verify-release-evidence-selftest.sh), [principle gates](../scripts/principle-gates-lib.sh), R32 공통 helper.

1. check ID에 등록된 producer가 실제 검사 명령을 실행하도록 한다. test 결과를 `command-exit`으로 강등하거나 summary 추출 명령의 exit 0을 원래 test 성공으로 대체할 수 없게 한다. argv·작업 경로·시작/종료·실제 버전·원본 결과를 연결하되 secret은 기록하지 않는다.
2. XCTest는 원본 xcresult에서 test ID·환경·성공/실패/skip/expected failure/runtime warning을 읽고 요약과 대조한다. 원본 교체, detached JSON, count 불일치, parser/schema 오류, discovery 0은 실패다. Swift Testing 등 다른 실행 형식도 해당 producer의 원본 결과 계약으로 판독한다.
3. diff/format 같은 정상 무출력 명령은 성공한 실행 metadata와 0바이트 stdout digest로 인정한다. 테스트·수동 관찰처럼 내용이 필수인 파일까지 빈 파일을 허용하지 않는다.
4. 필수 집합은 manifest가 아니라 정책이 결정한다. duplicate/unknown ID, 다른 환경, 삭제된 실패 행, 필수 SKIP/BLOCKED/N/A, 잘못된 source/policy digest를 거부한다. 중단 시 PASS receipt를 확정하지 않고 atomic write로 실패/중단 상태를 남긴다.
5. 수동 관찰은 시나리오·환경·후보·수행자·시각·관찰 내용·첨부물 digest를 요구한다. 로컬 reviewer 문자열은 신원 인증이 아니며 원격 승인은 R37의 신뢰 경로가 필요하다. 자동 audit receipt를 VoiceOver 관찰로 전환하지 않는다.

필수 회귀: 정식 required 집합 전체가 실패인데 COMPLETE인 기존 반례, expected failure/runtime warning, 무출력 실제 `git diff --check`, failed/zero/skipped/wrong-ID xcresult, 같은 실행을 다른 환경 ID로 복제, artifact·정책·후보 변조, path/symlink 이탈, 중단·중복 키·지원하지 않는 schema. 정상 완전 집합은 통과해야 한다.

통합 확인: 작은 실제 성공/실패 테스트 실행에서 recorder→원본 parser→verifier를 연결한다. 실패 테스트를 판독하는 명령 자체가 exit 0이어도 전체는 실패해야 한다. synthetic fixture만으로 이 단계를 닫지 않는다.

## 6. R34 — 접근성 runner의 실제 결과 검증

대상: Mulbyul `Apple/Scripts/run_ios_accessibility_audits.sh`, `summarize_training_records_audits.sh`, `summarize_training_records_audits_selftest.sh`, `Apple/Makefile`, `Apple/App/UITests/Sources/AccessibilityAuditUITests.swift`, `Apple/docs/TRAINING_RECORDS_QA.md`.

1. 번들 없음, summary 생성 실패, 테스트 0개, 다른 test ID, 실패/skip/정책상 금지 경고를 runner 자체의 nonzero로 연결한다. Makefile과 receipt producer도 동일 실패를 전달해야 한다.
2. build-for-testing과 test-without-building의 결과·timeout을 분리한다. cold build 시간을 UI timeout으로 계산하지 않는다. timeout을 늘리는 것만으로 수정을 대신하지 않는다. 사용자 취소·timeout·build 실패·test 실패·parser 실패를 서로 다른 원인으로 기록한다.
3. 실제 실행 환경을 앱/xcresult에서 확인한다. UDID/device/OS/locale/theme/content-size/Reduce Motion을 예상 조합과 대조하며 같은 환경을 다른 이름으로 여러 번 실행해 통과시키지 않는다.
4. 실패·중단 결과도 지속 evidence root에 보존하고 attempt 관계를 기록한다. 설정 복원은 trap 및 실패 회귀로 검증한다. 변경한 simulator 상태만 복구하며 다른 앱/빌드를 중단하지 않는다.
5. 보호 대상의 nil-identifier 문제는 일반 문구·횟수만으로 시스템 이슈라고 판정하지 않는다. release 판정에서 미승인 예외는 실패/대기로 남기고, 기존 raw/ignored issue 및 승인 여부를 별도로 노출한다. 승인 없는 allowlist 확대나 전체 감사 범위 축소는 금지한다.

회귀: F4 test double, corrupt/missing summary, 0개/wrong-ID/skip/실패 결과, timeout/signal/설정 복원, 정상 결과, 보호 대상 nil issue. 이어서 실제 iPhone/iPad에서 대표 조합 하나씩 실행하여 test discovery·환경·원본·receipt를 확인한다. 전체 24조합과 실제 UI/VoiceOver는 R38에서 최종 후보로 실행한다.

## 7. R35 — compiler 조건의 배타성

대상: [OutputPathSynthesis](../Sources/InnoFlowMacros/InnoFlowMacro+OutputPathSynthesis.swift), [CompileContractTests](../Tests/InnoFlowTests/CompileContractTests.swift), [OutputCasePathTests](../Tests/InnoFlowTests/OutputCasePathTests.swift), [macro tests](../Tests/InnoFlowMacrosTests/InnoFlowMacrosTests.swift), [CLAUDE.md](../CLAUDE.md), [MACRO_OPERATIONS.md](MACRO_OPERATIONS.md), 관련 principle/CI 계약.

최소 반례는 Output 안의 **서로 독립된** 두 조건이다.

```swift
#if targetEnvironment(simulator)
case platformValue(Int)
#endif
#if targetEnvironment(macCatalyst)
case platformValue(String)
#endif
```

1. plain/manual/macro 대조를 정식 테스트에 추가하고, 먼저 기존 macro의 `OutputPathCollision` 실패를 확인한다. inactive host compile만이 아니라 활성 target에서 helper 사용까지 확인한다.
2. 기존 조건 모델에 알려진 단일값 targetEnvironment 관계와 정규화·부정·괄호·독립/중첩 분기 처리를 일관되게 적용한다. host 환경으로 타 플랫폼 소스를 제거하지 않는다.
3. 기존 os/arch/swift/compiler 및 2-flag/3-flag matrix, 조건부 manual helper, public/package/generic 경로를 유지한다. 동시 활성 case/helper 충돌은 계속 의도한 진단으로 실패해야 한다.
4. 관계 미확정/복잡도 상한 초과는 기존 AC-R027의 조건 보존·compiler 위임 계약을 따르며, 유효 helper 일괄 삭제나 모든 충돌 진단 해제로 해결하지 않는다. 범용 SAT 엔진이나 새 의존성 도입은 비목표다.

필수 검증: simulator/device/Catalyst target compile, host compile, 정상 helper embed/extract, 실제 활성 충돌 음성군, manual helper 중복 억제. SDK compile과 runtime은 별도 결과다. compiler/plugin 로딩 오류를 기대 충돌 성공으로 세지 않는다.

## 8. R36 — Catalyst availability override

대상: R35와 같은 macro/compile fixture/계약 문서. R35를 먼저 마친 뒤 수정한다.

```swift
@available(iOS, unavailable)
@available(macCatalyst, introduced: 13.0)
case catalystOnly(Int)
```

1. Catalyst에서 직접 case 사용은 성공하지만 macro helper가 missing-member로 실패하는 대조를 편입한다. 감사의 최소 CasePath stub 재현에 더해 실제 public InnoFlow consumer로 검증한다.
2. 일반 OS availability와 세부 플랫폼 override를 함께 계산하고 원래 case의 조건·버전 제약을 helper에 보존한다. 단순 `iOS unavailable → os(iOS) 제외`로 처리하지 않는다.
3. Catalyst에서 helper 존재·사용을 확인하고 iOS에서 금지된 case/helper 사용은 compiler availability 진단으로 거부됨을 확인한다. generic computed helper와 non-generic helper 모두 검증한다.
4. macOS/iOS 및 SDK가 지원하는 extension domain의 일반 앱 양성·extension 음성, introduced/deprecated/obsoleted, 조건부 attribute, manual/ignored 경로를 대조한다. 확인되지 않은 domain을 임의로 전역 unavailable로 해석하지 않는다.

완료 조건은 유효한 소비자가 컴파일되는 것과 금지된 사용이 계속 거절되는 것을 모두 포함한다. missing-member 또는 unrelated build failure를 가용성 보호의 성공으로 세지 않는다.

## 9. R37 — 실제 workflow 제어 흐름과 신뢰된 producer 연결

대상: [cd.yml](../.github/workflows/cd.yml), [ci.yml](../.github/workflows/ci.yml), [workflow checker](../scripts/check-release-evidence-workflow.sh), [principle self-test](../scripts/principle-gates-selftest.sh), [RELEASING.md](../RELEASING.md). 필요 시 publication을 포함하지 않는 evidence producer workflow를 분리한다.

1. 전체 YAML 문자열 검색을 job별 구조 검사로 교체한다. `publish-release`의 실제 needs/if, evidence job의 선행 검사와 verifier step, continue-on-error/always/skip 전파를 검증한다. shell 의미를 무제한 추론하지 않고 검증된 entrypoint·허용된 호출 구조를 사용하며 알 수 없는 우회 구조는 실패 처리한다.
2. `echo verifier`, 무관한 job으로 needs 이동, verifier/필수 matrix 제거, exit 0 우회, continue-on-error, 실패/skip/cancel/missing artifact 변이를 정식 음성군에 추가한다. 정상 workflow 구조는 통과해야 한다.
3. producer가 R32/R33 형식으로 실제 job별 receipt·raw artifact를 생성·업로드하고 aggregator가 required 집합을 검사하도록 구현한다. 실패 때도 진단 원본을 보존하되 upload 성공을 검사 성공으로 세지 않는다. 작은 mocked pass bundle만 생성하는 producer는 완료가 아니다.
4. artifact 이름 외에 repository, workflow 식별/허용 ref, head SHA, run ID/attempt/conclusion, artifact digest와 실제 primary/consumer content digest를 검증한다. 임의 PR/fork/다른 attempt의 artifact, 다른 consumer, 정책 변경 전 증거는 거부한다.
5. Git SHA를 aggregate 대신 receipt에 써넣지 않는다. 정확한 두 checkout에서 다시 계산한 내용과 승인된 revision 관계를 확인한다. dirty 로컬 증거를 원격 후보에 대응시킬 수 없으면 새 원격 실행이 필요하다.
6. 수동 증거·배포 승인은 해당 후보에 결합된 소유자 승인 경로를 통해 받는다. 전달/검토 경로가 준비되지 않았으면 원격 gate는 BLOCKED다. 로컬 reviewer 문자열로 자동 승인하지 않는다.
7. 무배포 producer/검증 경로와 태그 publication 경로를 분리한다. post-publication 공개 설치는 publication 선행 조건으로 두지 않는다. 태그 push만으로 불완전한 후보를 공개하지 않는 기존 보호를 유지한다.

로컬 완료: 구조 변이·실패 전파·artifact/provenance fixture 검증과 실행 가능한 producer 정의가 모두 준비됨. 원격 완료: 별도 승인 후 무배포 실행에서 실제 artifact 전달과 실패 차단을 입증함. 원격 실행을 하지 않았다면 두 상태를 분리해서 남긴다.

## 10. R38 — 원본 재확보와 최종 후보 검증

대상: 새 evidence 보존/집계 경로, R32~R37의 producer, [QUALITY_REVIEW_6_0.md](QUALITY_REVIEW_6_0.md), [세 번째 후속 계획](REMEDIATION_THIRD_FOLLOWUP_PLAN_6_0.md)의 R30/R31, Mulbyul `Apple/docs/TRAINING_RECORDS_QA.md`.

### 원본 보존 및 재실행

1. 기존 raw/summary/receipt를 조사하고 원본이 없는 최신 원격 물별 통합 결과는 참고 요약으로 표시한다. summary에서 xcresult를 재구성하거나 과거 후보 문자열을 수정하지 않는다.
2. 결과 번들·로그·환경/후보 metadata·첨부물을 지속 evidence root로 수집하고 digest와 parser 재개방을 확인한 뒤에만 임시 checkout 제거가 가능하다. 복사 실패, 디스크 부족, artifact 누락/손상 시 완료나 정리를 진행하지 않는다. 큰 원본은 소스 Git에 넣지 않는다.
3. 동일 후보·환경·전체 시나리오의 재시도만 별도 attempt로 기록한다. 실패 이력과 재시도 관계를 보존하고, 성공한 assertion만 모아 합격을 만들지 않는다. 정책에 없는 best-of 선택은 금지하며 최종 matrix의 canonical attempt를 명시한다.
4. 최신 물별 원격과 로컬 후보의 차이는 격리 checkout에서 실제 소비자 검증한다. source-of-truth Tuist 정의와 정식 생성 절차로 fresh generation을 확인하며 이전 generated source를 복사한 것만으로 재현성을 입증하지 않는다. 원본 worktree의 무관한 변경을 덮어쓰지 않는다.

### 최종 입력 고정과 필수 검사

R32~R37 수정 및 관련 계약 문서가 안정된 뒤 후보를 고정한다. 이후 입력이 바뀌면 새 후보로 식별하고 그 후보의 필수 검사를 다시 충족해야 한다. 과거 777/53/59/37이라는 개수는 비교용 baseline이지 고정 합격 조건이 아니다. 새 테스트 discovery와 정확한 환경·결과를 검증한다.

| 검사 | 완료 증거 |
| --- | --- |
| 정적·검증 체계 | 두 저장소 diff check, InnoFlow format/doc/static principle, EV-CAND/EV-RESULT/UI-RUNNER/WF-GATE, 모든 새 반례의 실패 차단과 정상 대조 |
| 전체 package | Debug/Release 전체 principle, 성능 기준, canonical sample, compiler-plugin-free Core와 macro source fallback. scheduler/scope/dispatch/output/invariant 기존 계약 유지 |
| 매크로·toolchain | MAC-COND/MAC-AVAIL의 public/package/generic 소비자, 정확한 Swift 6.3과 6.4. `-swift-version`이나 과거 모듈 파일로 설치·실행 증거 대체 금지 |
| SDK·runtime | 기존 최소 deployment target을 유지한 macOS/iOS/tvOS/watchOS/visionOS 5 SDK build, 새 Catalyst compile 대조. 현재 macOS 및 iOS/tvOS/watchOS/visionOS 27.0과 이전 18.5/11.5/2.5의 8 simulator 집중 runtime |
| Sanitizer | 독립 build 경로의 TSan·ASan 회귀. source/toolchain 불일치와 sanitizer 경고를 parser가 차단. 지원하지 않는 조합은 미실행으로 명시 |
| 물별 기능·UI | 공식 TrainingRecords iOS/macOS feature/owner, iPhone/iPad/macOS의 실패→재시도, 저장/삭제→재조회, 이탈/복귀·늦은 응답, 상세/편집/선택·키보드/포커스 회귀 |
| 접근성 | iPhone/iPad 각각 light/dark × 기본/최대 글자 × ko/en/ar, 총 24조합. 보호 대상·좁은 화면/창·긴 RTL·별도 Reduce Motion. 실제 VoiceOver 탐색은 별도 관찰·후보·수행자 증거 |
| 배포 경계 | local-preflight와 pre-/post-publication을 분리. 원격 CI·태그/API baseline·승인 및 공개 설치는 해당 승인/실행이 있을 때만 통과 |

최종 결과는 빈 manifest가 아니라 **실제 모든 실행 receipt를 가진 manifest**로 검증한다. raw artifact를 재개방하고 source/policy/environment/test ID를 대조한다. 최종 보고서는 우선 ignored evidence 영역에 작성한다. 추적 문서에 결과를 추가해 후보가 바뀌면 검증한 후보와 새 revision을 구분하고, 새 배포 revision의 gate를 다시 충족한다.

R30의 기존 접근성/VoiceOver/플랫폼 계약은 축소하지 않는다. 시스템 false positive에 예외가 필요하면 독립 최소 재현·영향·환경·재검증 조건·승인을 확보하기 전 합격시키지 않는다. 새로운 제품 결함이 발견되면 원인 파일과 회귀를 좁혀 수정 범위를 제시하고, 범위를 벗어나면 별도 결정을 요청한다.

## 11. 형식적으로만 통과하는 반례 점검

| 반례 | 닫는 조건 |
| --- | --- |
| 실패 JSON을 성공한 parser 명령으로 기록 | AC-R033: 원래 검사 producer와 원본 결과 판독 |
| 모든 조합 이름에 같은 환경/다른 테스트 결과 복제 | AC-R032/034/038: 실제 환경·test ID 집합 대조 |
| 정상 무출력 검사를 거부하거나 테스트 빈 결과를 허용 | AC-R033: 결과 종류별 필수 내용과 실행 metadata 구분 |
| macro 충돌 진단을 모두 꺼서 양성만 통과 | AC-R035: 실제 동시 활성 충돌 음성군 |
| Catalyst를 살리면서 iOS/extension 금지까지 해제 | AC-R036: 플랫폼·extension availability 음성 대조 |
| verifier 이름과 needs 문자열은 있지만 실제로 실행되지 않음 | AC-R037: job 구조·entrypoint·우회 변이 회귀 |
| 신뢰할 수 없는 producer/다른 consumer 증거로 승인 | AC-R032/037: 내용·revision·정책·run/attempt·승인 연결 |
| 원본 삭제 뒤 summary와 문서만으로 전체 완료 | AC-R038: 원본 재개방·digest와 실제 receipt manifest |
| 보호 대상 nil issue를 횟수 예외로 숨기거나 자동 audit를 VoiceOver로 대체 | AC-R034/038와 기존 AC-R030: 미승인 예외 차단·별도 실제 관찰 |

이 반례 중 하나라도 구현이 모든 서면 조건을 충족하면서 허용할 수 있다면 해당 AC는 완료가 아니다. 요구사항 또는 테스트의 공백을 먼저 보완하며, 구현에 맞춰 기준을 사후 축소하지 않는다.

## 12. 진행 상태와 완료 명칭

### 2026-09-10 실행 기록

- R32는 두 저장소의 tracked/untracked 입력, 삭제, mode, content digest, Git revision과 단일 JSON 정책을 분리해 기록하는 candidate snapshot으로 구현했다. 결정성·경로 이식·내용/정책 변경·component 불일치 회귀가 통과했다.
- R33은 check별 profile, 허용 명령, 환경, artifact digest, 원본 xcresult와 실제 test identifier를 검증한다. 고정 개수만 맞춘 다른 테스트, 실패/skip/expected failure/runtime warning, 경로 이탈, symlink, 빈 필수 artifact, candidate/policy 불일치를 음성군으로 차단했다.
- R34 runner는 결과 번들·summary·tests JSON·정확한 테스트 ID가 없거나 실패하면 nonzero이며, timeout watchdog과 사용자 signal에서 자신이 생성한 프로세스 및 simulator 설정을 정리한다. stale generated InnoFlow project도 실제 빌드 전에 거부한다. fresh Tuist 생성 뒤 iPad 대표 조합은 1/1 통과했지만 iPhone 대표 조합은 nil-element contrast audit 4건으로 실패했으므로 R34 전체는 열려 있다.
- R35/R36은 `targetEnvironment(simulator)`와 `targetEnvironment(macCatalyst)`의 배타성을 보존하고 Catalyst 세부 availability를 synthesized helper에 복사한다. macro expansion, external compile contract와 실제 Catalyst consumer가 Xcode 27.0 / Swift 6.4에서 통과했다.
- R37은 CD job dependency와 verifier 호출 구조, prerequisite 결과, candidate component 및 GitHub artifact provenance의 로컬 변이 회귀를 구현했다. 그러나 허용된 `.github/workflows/release-evidence.yml` producer 정의와 실제 trusted run은 아직 없으므로 로컬/원격 완료가 아니다.
- R38의 현재 후보는 Debug와 Release 각각 711 runtime + 68 macro 테스트, release timing baseline, sample package/canonical app, Catalyst consumer, 5개 generic Apple SDK build, 8개 이전/현재 simulator runtime 각각 53/53, TSan/ASan 집중 53/53, strict format, full principle 및 관련 self-test를 통과했다. 보존한 iOS DerivedData가 macOS compile-contract module 탐색을 오염시키는 반례도 추가해 host module 우선 선택을 고정했다. 정확한 Swift 6.3, 24개 접근성 조합, actual VoiceOver, macOS UI runtime, trusted remote evidence/승인/태그/공개 설치는 아직 충족하지 않았다.

현재 판정은 **로컬 hardening 구현 완료에 근접했지만 배포 준비 완료 아님**이다. 특히 iPhone 접근성 실패를 횟수 예외로 숨기지 않으며, 승인되지 않은 기존 nil-identifier 예외도 합격 증거로 사용하지 않는다.

| 작업 | 현재 상태 | 다음 종료 조건 |
| --- | --- | --- |
| IF6-R32 | 로컬 구현·회귀 완료 | 최종 candidate 고정 뒤 동일 snapshot으로 필수 receipt 연결 |
| IF6-R33 | 로컬 구현·회귀 완료 | 최종 candidate의 실제 전체 manifest 검증 |
| IF6-R34 | 부분 완료 / iPhone 실패 | iPhone contrast 4건 원인 해결 또는 독립 재현·소유자 승인 후 대표 조합 재통과 |
| IF6-R35 | Xcode 27 / Swift 6.4 완료 | Swift 6.3 실제 toolchain 대조 |
| IF6-R36 | Xcode 27 / Swift 6.4 완료 | Swift 6.3 실제 toolchain 대조 |
| IF6-R37 | 로컬 구조·provenance 회귀 완료 / producer 없음 | 실행 가능한 trusted producer 정의와 별도 원격 무배포 run |
| IF6-R38 | 일부 로컬 회귀 완료 | 원본·실제 manifest·필수 전체 candidate matrix와 승인 |

- **계획 작성 완료:** 이 Draft의 작업·AC·반례·문서 검사가 준비됨. 구현/검토/승인 완료가 아님.
- **코드 수정 완료:** R32~R37 및 R38 보존 경로 구현과 정식 회귀가 완료됨. 실제 환경·원격 실행 대기는 별도 표기.
- **전체 로컬 검증 완료:** 최종 후보의 local-preflight required 집합과 R30/R31 로컬 계약이 모두 충족됨. 필수 toolchain/UI/VoiceOver/원본이 없으면 사용하지 않는 명칭.
- **배포 준비 완료:** 정확한 배포 후보의 pre-publication·신뢰된 원격 실행·승인까지 충족됨. 공개 배포 완료와 다름.
- **공개 배포·설치 검증 완료:** 별도 승인된 publication과 post-publication 독립 설치가 실제 성공함.

환경/권한 대기 때는 가능한 다른 로컬 작업을 진행하되 남은 gate·필요한 입력·결정권자를 명시한다. Draft/Reviewed/Approved는 실제 문서 검토·승인 기록에 의해서만 바꾼다. 실행 요청만으로 수동 관찰이나 예외 승인이 생기지 않는다.
