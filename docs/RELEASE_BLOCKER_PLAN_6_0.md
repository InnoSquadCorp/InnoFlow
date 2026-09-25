# InnoFlow 6.0.0 — 남은 배포 차단 조건 해소 계획

> **2026-09-18 범위 / 2026-09-23 계획 개정:** 사용자 지시로 물별 전용 검증은 필수 목록에서 제외됐다. R40/AC-R040·R41/AC-R041은 범위 제외이며 PASS가 아니다. 아래 물별 조사·수행 절차는 역사적 기록이다. 활성 계획은 [배포 전 R68 → R69 → R59~R67](PRE_RELEASE_EXECUTION_PLAN_6_0.md)이며 [R52~R58](FRAMEWORK_ONLY_REMEDIATION_PLAN_6_0.md)의 구현 이력과 재개 조건을 계승한다. 물별 없는 정책·workflow 전환은 R52에서 반영됐고 R43/R44의 실제 producer·최종 증거 조건은 계속 열려 있다.

> 2026-09-17 후속 검토: 결과 파서·기대 테스트 정책·consumer checkout·ASan·필수 CI의 추가 결함은 [검증·배포 경로 수정 계획](VALIDATION_REMEDIATION_PLAN_6_0.md)의 R46~R51에서 다룬다. 아래 과거 실행 기록은 보존하며, R39/R43의 해당 부분은 재개한다. R46~R51의 로컬 수정·회귀는 완료됐지만 원격 PR CI·required check 적용과 기존 배포 미완료 조건은 남아 있다.
>
> 증거 보존 참고: 2026-09-17 문서 링크 검사에서 아래의 `.build/release-evidence-r38/principle-final-candidate.log`는 현재 경로에 존재하지 않았다. 과거 실행 기록과 현재 재개방 가능한 원본은 구분하며, 해당 링크만으로 현재 후보의 통과를 입증하지 않는다.

- 문서 상태: **실행 중**, 2026-09-12. 로컬 구현과 일부 실제 검증이 진행됐으며 원격 검증·배포 승인 완료가 아니다.
- 결정권자: 프로젝트 소유자. 구현 담당: 후속 실행 담당자. 검토자·승인일: 미기록.
- 활성 범위: **InnoFlow 자체 runtime·검증·CI/CD**. 물별 제품 코드 및 UI·접근성·VoiceOver 검증은 제외한다.
- 기존 요구사항: [구현 계획](IMPLEMENTATION_PLAN_6_0.md)의 FR-001~007/NFR-001~005, [첫 후속 계획](REMEDIATION_FOLLOWUP_PLAN_6_0.md)의 FR-008을 유지한다.
- 관계: [네 번째 후속 계획](REMEDIATION_FOURTH_FOLLOWUP_PLAN_6_0.md)의 R32~R38을 닫기 위한 잔여 작업이다. 기존 ID를 바꾸지 않고 **IF6-R39~R45 / AC-R039~045**를 추가한다.
- 목적: 실제 물별 실패, 실행되지 않은 필수 검사, 증거 생성·전달의 구현 공백을 해소해 승인 직전의 검토 가능한 6.0.0 후보를 만든다. 새로운 제품 기능은 추가하지 않는다.

## 1. 현재 기준과 이전 완료 표현 정정

2026-09-11 계획 작성 전 로컬 재확인 결과다. 원격 ref·CI 상태는 이번 계획에서 조회하지 않았으며 과거 fetch 상태를 최신이라고 사용하지 않는다.

| 확인한 사실 | 근거와 의미 |
| --- | --- |
| 기존 후보가 보존됨 | aggregate `559c4c28a2252547f6c5be60a11bc01dd201be1a30a5fad21a514921fbc01535`를 현재 입력으로 재계산해 일치 확인. 이 계획 추가 전 후보이며 이후 후보로 재표기하지 않음 |
| 두 저장소는 미커밋 변경을 포함 | InnoFlow HEAD `00a73ed2d2cb94114b0be5c9fbd59c187a4b67c7`, Mulbyul HEAD `092ff9514695ceae5cfd490388e017fac331e30a`. dirty 자체는 제품 결함이 아니며 원본 정리를 해결책으로 삼지 않음 |
| 전체 자동 게이트 통과 이력 존재 | [전체 로그](../.build/release-evidence-r38/principle-final-candidate.log)에 Debug/Release 각각 runtime 711 + macro 68 및 전체 principle PASS. [품질 기록](QUALITY_REVIEW_6_0.md)의 SDK·8 runtime·sanitizer 결과는 해당 후보의 과거 실행 증거 |
| 물별 iPhone 대표 audit 실패 | [iPhone 원본 보존 위치](../../Projects/Mulbyul/.build/device-check-20260910/iphone-fresh-tuist/)의 summary는 1개 테스트 실패, test tree에는 contrast 실패 메시지 4개. 4개 테스트 실패 또는 고유 제품 결함 4개라고 해석하지 않음 |
| 물별 iPad 대표 audit 통과 | [iPad 원본 보존 위치](../../Projects/Mulbyul/.build/device-check-20260910/ipad-fresh-tuist/)는 동일 대표 메서드 1/1 PASS. 전체 24조합 및 VoiceOver 완료 증거는 아님 |
| 정확한 Swift 6.3 실행 증거 없음 | 현재 선택된 Xcode는 27.0 (`27A5252f`), Swift 6.4. 표준 설치 경로 조회에서는 `/Applications/Xcode.app`만 확인. 다른 호스트·비표준 경로의 환경은 미확인 |
| 실제 manifest·producer가 없음 | `.build/release-evidence-r38/manifest.tsv` 및 `.github/workflows/release-evidence.yml` 부재 확인. verifier와 fixture 테스트만으로 R37/R38 구현 완료라고 부를 수 없음 |
| CD 실행 순서 결함 | [cd.yml](../.github/workflows/cd.yml)의 `release-evidence`가 checkout 전에 `scripts/verify-release-prerequisites.sh`를 호출. 새 runner에는 스크립트가 아직 없음 |
| 명령 정책 비교가 지나치게 넓음 | [release-evidence-tool.rb](../scripts/release-evidence-tool.rb)의 실제 `command_matches?`를 읽기 전용 probe로 호출한 결과, `full-principle` 명령에 `--static`을 추가해도 허용. sanitizer 명령의 임의 `--filter NoSuchSuite`도 명령 비교에서 허용됨. 후자는 실제 0-test 실행/전체 verifier 통과까지 재현한 결과는 아님 |

**상태 정정:** R33은 실행 계약 보강을 위해 재개한다. R32의 snapshot 구현과 R35/R36의 Swift 6.4 검증은 보존한다. R34는 iPhone 실패, R37은 producer 미구현과 실행 순서 문제, R38은 실제 전체 manifest 부재로 계속 열려 있다. 지난 결과는 유용한 회귀 기준이지만 “로컬 코드 작업은 모두 끝났고 환경만 대기”인 상태는 아니다.

## 2. 작업 순서와 요구사항 추적

기본 순서는 **R39 → R40 → R41 → R42 → R43 → R44 → R45**다. 시작 시 Swift 6.3 환경·macOS GUI 세션·VoiceOver 수행 수단·원격 consumer 접근 가능성을 읽기 전용으로 먼저 조사한다. 환경 확보가 지연되면 독립적인 로컬 구현은 계속하고 해당 완료 조건만 열린 상태로 남긴다.

| 순서 / 작업 | 계승 요구사항·기존 작업 | 완료 조건 | 검증 증거 |
| --- | --- | --- | --- |
| 1 / IF6-R39 실행·증거 생성 경로 완성 | FR-007, NFR-001/005; R32/R33/R38 | **AC-R039:** 정확한 검사 실행, 원본 결과, 후보·환경, 실패 이력을 한 경로로 기록. 약한 검사/다른 저장소/0-test로 대체 불가 | `EV-EXEC` 정상·우회·중단·경로 회귀와 실제 소규모 실행 |
| 2 / IF6-R40 물별 contrast 및 24조합 | FR-007/008, NFR-003/005; R34/R30 | **AC-R040:** 대표 iPhone 실패의 원인 처리 후 24개 환경의 audit·보호 대상이 모두 충족 | `UI-A11Y` 원본·test tree·환경·예외 적용 기록 |
| 3 / IF6-R41 소비자 기능·복구·macOS·VoiceOver | FR-001/003/007/008; R30/R38 | **AC-R041:** 실제 iPhone/iPad/Mac 동작과 플랫폼별 VoiceOver 탐색을 확인 | `UI-CONSUMER`, 플랫폼별 수동 관찰 receipt |
| 4 / IF6-R42 Swift 6.3/6.4 실컴파일 | FR-006/007, NFR-005; R35/R36 | **AC-R042:** 동일 수정 후보의 두 실제 compiler에서 정상·금지 소비자 및 macro 계약 검증 | `TC-MATRIX` compiler/build/SDK·fixture 원본 |
| 5 / IF6-R43 무배포 producer와 CD 연결 | FR-007, NFR-001/005; R37 | **AC-R043:** 실행 가능한 producer, 선행 단계, 업로드·집계·신뢰 확인이 연결되고 실패 전파 유지 | `WF-PRODUCER` 격리 smoke·변이·실제 원격 무배포 실행 |
| 6 / IF6-R44 후보 고정·실제 전체 manifest | FR-001~008, NFR-001/005; R38 | **AC-R044:** 정책의 모든 local 필수 항목이 동일 후보의 실제 receipt·원본으로 검증됨 | `EV-FINAL` 전체 manifest·원본 재개방·독립 consumer |
| 7 / IF6-R45 배포 전 검증·승인·공개 설치 | FR-007, NFR-005; R37/R38 | **AC-R045:** 로컬 준비, 원격 검증, 공개 배포, 공개 설치의 상태와 증거가 각각 일치 | `REL-PREFLIGHT`, 승인 기록, `REL-INSTALL` |

작업별 구현과 회귀를 함께 완료한다. 최종 후보를 고정하기 전에는 변경과 관련된 테스트만 실행하고, 필수 전체 행렬은 R44에서 수집한다. 이후 변경 또는 새로운 실패가 없으면 전체 suite를 관성적으로 반복하지 않는다.

## 3. R39 — 먼저 검사 실행과 증거 수집을 하나로 연결

대상: [recorder](../scripts/record-release-evidence.sh), [evidence helper](../scripts/release-evidence-tool.rb), [정책](contracts/release-evidence-policy.json), [verifier 회귀](../scripts/verify-release-evidence-selftest.sh), [runtime runner](../scripts/run-focused-platform-runtime-tests.sh), [principle entrypoint](../scripts/principle-gates-lib.sh). 신규 runner/집계 명령은 기존 스크립트에 통합할 수 없는 부분만 추가한다.

1. 명령 부분 문자열 비교를 check별 실행 정의로 교체한다. 실행 파일·저장소 역할·필수/허용 인수·필수 suite를 검증한 뒤에만 실행한다. `full-principle --static`, 임의 필터/skip, 다른 디렉터리의 동명 스크립트, 두 diff 검사에서 같은 저장소 사용은 거부한다. 기록 목적으로 원래 명령을 성공한 summary 추출 명령으로 바꿀 수 없어야 한다.
2. wrapper가 시작/종료 시각·작업 경로의 논리 역할·실제 executable/toolchain/SDK/runtime·argv·원래 exit/signal·check/attempt ID·실행 전후 component digest를 직접 수집한다. 입력 변경·중단·기록 실패면 PASS를 확정하지 않는다. 문자열로 받은 toolchain 설명만으로 환경을 입증하지 않는다. 임의 명령 실행 후 정책 위반을 발견하는 현재 순서도 바로잡는다.
3. Swift Testing 결과도 실제 발견 test ID와 종료 결과를 판독한다. 전체 검사에서 `--filter`, sanitizer에서 0-test·스킵·필수 suite 누락, 실패 로그 뒤 wrapper exit 0을 차단한다. 기록된 779/53이라는 수만 맞추지 않고 해당 후보의 discovery와 검사별 요구 ID 집합을 대조한다. xcresult의 summary count와 leaf case 집합도 일치해야 한다.
4. 실행기가 생성한 새 xcresult와 해당 실행의 연결을 확인한다. 같은 디바이스라도 과거 bundle을 새 실행에 재사용하거나 다른 환경을 이름만 바꿔 넣을 수 없어야 한다. runtime/scheme 선택과 생성 프로젝트 유무를 정식 runner가 처리하고 일반 SDK 빌드에서도 패키지 workspace를 명시한다.
5. 각 attempt의 결과는 PASS/FAIL/BLOCKED/INTERRUPTED와 원본으로 보존한다. 별도 진단 index에 전체 이력을 두고, release manifest는 각 required ID의 canonical attempt를 가리킨다. 집계 파일은 원자적으로 갱신하고 재시도는 새 경로에 기록한다. 실패 행 삭제·여러 실행의 성공 assertion 조합으로 완료를 만들 수 없다.
6. `principle-gates.sh`의 `--help`는 사용법만 출력하고 알 수 없는 옵션은 즉시 nonzero 처리한다. 문서 확인이 전체 빌드를 시작했던 재발을 막는다. shell 경로와 symlink 검사도 실행 전에 수행하고 artifact/root 바깥 쓰기를 거부한다.
7. 정책 누락을 채운다. 현재 local required는 개별 33 + 접근성 24 = 57개지만, 단일 VoiceOver 행으로 세 플랫폼 관찰을 대신하지 않는다. 플랫폼별 관찰, Records Reduce Motion·좁은 화면/창을 독립 필수 ID 또는 검증되는 세부 관찰 항목으로 표현한다. 최종 개수는 정책에서 계산한다. 형식 변경은 schema revision과 명시적 호환 규칙을 함께 갱신한다.

필수 회귀: 정상 무출력 검사, 완전한 실제 소규모 XCTest/Swift Testing, full→static 대체, 0-test·다른 suite, 다른 저장소/명령, 실행 중 소스 변경, 오래된 bundle, 실패/skip/timeout/signal, 누락/손상/경로 이탈, 중복·중단된 기록. 로컬 파일 checksum은 신뢰된 실행자의 신원을 증명하지 않으므로 원격 신뢰는 R43에서 별도로 확인한다.

**종료:** 실제 명령 하나를 실행해 원본·receipt·manifest를 생성하고 재검증하는 경로가 동작한다. 모든 차단 반례를 정식 entrypoint로 검증한다. 완료되지 않은 전체 후보의 manifest도 누락 이유를 출력하며 nonzero여야 한다.

## 4. R40 — iPhone contrast 원인 해결 후 24조합 검증

대상: Mulbyul [AccessibilityAuditUITests.swift](../../Projects/Mulbyul/Apple/App/UITests/Sources/AccessibilityAuditUITests.swift), [접근성 runner](../../Projects/Mulbyul/Apple/Scripts/run_ios_accessibility_audits.sh), [결과 validator](../../Projects/Mulbyul/Apple/Scripts/validate_accessibility_audit_result.rb). 제품 수정 후보는 [Records 공통 UI](../../Projects/Mulbyul/Apple/Features/TrainingRecords/UIs/Shared/TrainingRecordsScene+Components.swift), [iOS Records 화면](../../Projects/Mulbyul/Apple/Features/TrainingRecords/UIs/iOS/TrainingRecordsCurrentExperienceScene.swift)과 실제 원인에 해당하는 DesignSystem token이다.

1. 기존 failed xcresult의 audit 첨부·화면·접근성 트리를 읽고 records-root/overall-summary의 4개 메시지를 화면 요소와 연결한다. 같은 구성의 iPhone/iPad, 실제 OS build, 한 요소씩 줄인 최소 화면을 대조해 제품 문제인지 시스템 audit 문제인지 판정한다. nil-element라는 사실만으로 false positive라고 결론 내리지 않는다.
2. 제품 문제이면 원인 색상/배경/중복 AX 노드/레이아웃을 좁혀 수정한다. 타겟을 접근성 트리에서 숨기거나 audit 범위를 줄이지 않는다. 공통 색상 token을 바꿔야 하면 그 token의 다른 사용 화면에 대한 회귀도 포함한다. 이전에 되돌린 색상 실험을 근거 없이 다시 적용하지 않는다.
3. 시스템 문제로 재현되면 최소 독립 fixture, 환경/OS build, 영향받는 의미 대상, 실제 가독성 확인, 재검증 조건을 남긴다. 자동 우회는 구체적인 진단·환경·대상과 검토 근거를 식별할 수 있어야 하며 nil issue 개수만 허용하지 않는다. 구별 가능한 조건이 없으면 해당 audit gate는 열린 상태다. 기존 `verifiedNilContrastAllowance`와 넓은 예외도 동일 기준으로 점검한다.
4. 대표 `test_recordReleaseTargets_defaultLightKorean`을 iPhone/iPad에서 통과시킨 뒤 **2기기 × 2테마 × 2글자 크기 × 3언어(ko/en/ar) = 24조합**을 실행한다. 각 결과에 기기 모델·OS build·theme/content-size/language·실제 test ID·보호 대상의 관찰 로그를 연결한다. 별도 Records Reduce Motion·RTL 긴 문자열·좁은 화면/창 검사는 R39 정책에 따라 추가한다.
5. runner가 변경한 설정은 실패/timeout/signal에서도 복원한다. 첫 대표 실패를 수정한 뒤 나머지 조합을 계속 확인해 전체 결함 목록을 수집한다. infra 재시도는 같은 환경의 전체 scenario를 새 attempt로 실행하며 원래 실패를 보존한다.

**종료:** 24조합 모두 완전한 원본·정확한 환경과 필수 대상 검증을 갖는다. 실패/스킵/미승인 예외는 0이어야 한다. 예외를 승인받는 경우라도 자동 audit 예외와 실제 VoiceOver 관찰은 별도 증거다.

## 5. R41 — 실제 기능·복구·데스크톱·VoiceOver 마무리

대상: Mulbyul [TrainingRecords 테스트](../../Projects/Mulbyul/Apple/Features/TrainingRecords/Tests/), [Navigation UI tests](../../Projects/Mulbyul/Apple/App/UITests/Sources/TrainingRecordsNavigationUITests.swift), [macOS UI tests](../../Projects/Mulbyul/Apple/App/MacUITests/Sources/TrainingRecordsMacUITests.swift), [프로젝트 정의](../../Projects/Mulbyul/Apple/App/Project.swift), [QA](../../Projects/Mulbyul/Apple/docs/TRAINING_RECORDS_QA.md).

1. iOS/macOS의 실제 feature/owner suite를 실행한다. 이후 iPhone/iPad/Mac에서 실패→재시도, 저장/삭제→재조회, 이탈/복귀·늦은 응답, 편집 중 취소/선택 변경을 실제 production owner 경로로 검증한다. 없는 UI 시나리오는 먼저 추가하고 발견된 원인 코드만 수정한다.
2. iPhone compact 상세/탭바/시트, iPad regular↔compact·선택/미저장 draft·키보드와 저장, Mac 목록 키보드 이동·저장·포커스 복귀·창 크기 변경을 확인한다. 저장 실패·중복 입력·취소 후 로딩 상태도 확인한다. 기능 회복과 단순 화면 전환을 같은 결과로 세지 않는다.
3. macOS는 현재 GUI 세션 상태와 실행 권한을 먼저 확인한다. 과거 잠금으로 테스트 discovery 전에 실패했던 기록을 현재도 잠겼다는 증거로 사용하지 않는다. `build-for-testing` 이후 실제 UI test discovery·행동 결과까지 확보한다. 시스템 잠금/인증을 우회하지 않는다.
4. VoiceOver를 실제 활성화한 iPhone/iPad/Mac 각각에서 기록 목록→상세→편집/저장→복귀, 오류→재시도, 시트 진입/종료를 탐색한다. 읽는 이름·값·상태·순서, 보이지 않는/중복 요소, 포커스 복원, 동적 업데이트 알림을 기록한다. OS/후보·시나리오·수행자·시각·음성 또는 관찰 원본/첨부 digest를 보존한다. 화면 이미지나 자동 audit만으로 완료하지 않는다.

**종료:** 정책에 등록된 feature/UI suite와 추가된 회복 시나리오가 세 플랫폼에서 실행되고 플랫폼별 VoiceOver 관찰이 존재한다. 사용할 수 없는 관찰 수단은 구체적인 환경 요구와 함께 남기고 가능한 다른 로컬 작업을 계속한다.

## 6. R42 — Swift 6.3과 6.4를 실제 toolchain으로 검증

대상: [toolchain runner](../scripts/run-swift-toolchain-evidence.sh), [CompileContractTests](../Tests/InnoFlowTests/CompileContractTests.swift), [macro tests](../Tests/InnoFlowMacrosTests/InnoFlowMacrosTests.swift), [Catalyst consumer](../scripts/check-catalyst-macro-consumer.sh), CI matrix와 정책.

1. 실행 초기에 설치된 Xcode/toolchain·지원 SDK·연결된 작업 호스트를 조사하고 사용 가능한 정확한 6.3.x/6.4.x와 build 번호를 확정한다. 추가 설치가 필요하면 공식 배포물·호스트 호환성·용량·설치 경로를 먼저 확인한다. 설치 또는 접근이 필요한 구체적인 단계만 의사결정 대상으로 남긴다.
2. 명령 단위 `DEVELOPER_DIR`/toolchain 선택과 독립 build path로 실행한다. 전역 Xcode 선택을 바꾸거나 이전 모듈을 재사용하지 않는다. SwiftSyntax dependency·macro plugin을 선택된 compiler로 빌드하고 실제 버전/SDK를 receipt에 기록한다.
3. R35/R36의 plain/manual/macro 양성 대조와 동시 활성 충돌, compiler/arch/environment 분기, extension 금지, Catalyst availability, public/package/generic helper를 두 compiler에서 비교한다. 양성은 helper 사용까지, 음성은 의도한 compiler diagnostic까지 확인한다.
4. 두 버전에서 지정된 package 검사도 실제 실행한다. 실패는 source 호환성·plugin/dependency·SDK·인프라로 분류한다. SDK 부재를 macro 성공으로 세지 않고 언어 모드 `-swift-version`을 compiler 교체 증거로 사용하지 않는다. 최소 지원 버전을 높여 실패를 없애지 않는다.

**종료:** 두 실제 toolchain에서 필수 검사·소비자 fixture가 통과하고 원본이 남는다. 환경을 확보하지 못하면 정확한 부족 환경을 명시하며 R42를 완료하지 않는다.

## 7. R43 — 실행 가능한 무배포 producer와 CD 연결

대상: 신규 `.github/workflows/release-evidence.yml`, [cd.yml](../.github/workflows/cd.yml), [ci.yml](../.github/workflows/ci.yml), [workflow checker](../scripts/check-release-evidence-workflow.rb)와 [회귀](../scripts/check-release-evidence-workflow-selftest.sh), [provenance](../scripts/write-github-evidence-provenance.rb), [배포 지침](../RELEASING.md).

1. CD에서 checkout→저장소 스크립트 실행 순서를 고친다. checker는 step 조건·선행 파일 준비·검증 함수 실행 순서를 검사한다. 빈 작업 디렉터리에서 정상 단계가 실제 실행되는 대조와 checkout 누락/역전, verifier skip, 실패 숨김을 검사한다. 필요한 패키지 workspace도 정식 실행기가 지정한다.
2. producer는 InnoFlow SHA와 Mulbyul SHA를 고정해 체크아웃하고 두 component의 content digest와 실제 dependency 연결을 계산한다. 동작하는 R39 실행기를 통해 필수 job별 receipt·raw artifact를 생성·업로드한다. 접근성·macOS GUI·toolchain별 실행 환경은 명시하고 unavailable 환경을 작은 fixture로 대신하지 않는다.
3. consumer 증거는 원본을 실행한 작업의 repository/ref/SHA·workflow·run ID/attempt와 consumer digest를 보존한다. 가능하면 producer가 직접 실행하고, 별도 Mulbyul workflow가 필요하면 원본 producer provenance를 유지한 채 검증·집계한다. aggregate job 하나의 신원으로 다른 실행자나 임의 로컬 receipt를 신뢰시키지 않는다.
4. artifact 이름뿐 아니라 GitHub API에서 확인한 허용 workflow/ref·완료 상태·run/attempt·artifact ID/digest/만료 여부와 다운로드 파일을 연결한다. 다른 SHA/consumer/attempt, 변조·누락·만료 artifact와 untrusted fork를 거부한다. 여러 job/저장소의 provenance를 합칠 때 동일한 metadata 하나로 덮어쓰지 않는다.
5. producer 실행 완료 후 독립 verifier가 완료된 run을 검사하도록 구성한다. 아직 실행 중인 producer가 자신의 최종 성공을 증명해야 하는 순환 의존은 만들지 않는다. `remote-ci` 등 정책의 명령은 실제 존재하는 CLI/API 실행으로 정의하고 상태 JSON을 판독한다. 수동 승인과 수동 관찰은 각 증거를 생성한 주체·후보에 별도 연결한다.
6. 무배포 실행에서는 release 생성 권한과 publication job을 배제한다. 후속 태그 검증은 검증된 후보와 태그가 가리키는 SHA를 확인하고 필수 job 실패/skip/cancel이면 publication이 실행되지 않게 한다. 공개 설치는 사후 단계로 유지한다.

**로컬 종료:** 실행 가능한 producer 정의, 실제 runner 계약, checkout 순서 및 업로드·누락·우회/provenance 회귀가 통과한다. **원격 종료:** 검토된 두 저장소 revision에 대해 실제 무배포 실행→artifact 전달→독립 검증을 통과한다. 원격 단계는 R44의 revision 준비 후 R45에서 수행하며, 그 전에는 R43을 전체 완료로 표시하지 않는다.

## 8. R44 — 최종 후보와 모든 실제 receipt 고정

1. 원본 dirty worktree를 보존한 채 두 저장소의 정확한 입력·필수 외부 local dependency·lockfile을 조사한다. 원격 통합이 필요한 경우 최신 ref를 조회하고 격리 checkout에 검토된 변경만 적용한다. 실제 사용 dependency가 snapshot 밖에 있으면 revision/digest와 포함 규칙을 먼저 보강한다. generated Tuist/Xcode 파일은 원본 정의에서 `make sync`로 생성한다.
2. 구현·테스트·policy·workflow·배포 지침을 안정화한 뒤 후보를 한 번 고정한다. 기존 후보의 로그는 비교용이며 새로운 후보 해시를 붙여 재사용하지 않는다. 최종 입력을 포함한 로컬 독립 consumer install/build도 검증한다. Git 정리는 명시적 파일별 변경 검토와 commit 제안으로 준비하며 dirty 제거를 위해 무관한 변경을 되돌리거나 한꺼번에 stage하지 않는다.
3. 정책을 해석해 정확한 required 집합과 작업 목록을 출력한다. 전체 Debug/Release principle·성능·sample, macro·두 toolchain, 5 SDK·Catalyst·8 runtime, TSan/ASan, 물별 feature/UI/회복/24 audit·추가 시각/VoiceOver를 모두 R39의 recorder를 통해 수집한다. 기존 테스트 숫자는 기대 test ID 집합을 대신하지 않는다.
4. 지속 보존 디렉터리에 `candidate / check / environment / attempt`별 원본·로그·receipt·manifest를 보존한다. 빌드 캐시 cleanup과 증거 cleanup을 분리한다. 다른 위치로 복사한 evidence bundle도 원본 digest·xcresult 재개방·manifest 검증이 동일하게 통과해야 한다.
5. 재시도 규칙을 먼저 고정한다. infra 재시도는 같은 후보/환경의 전체 검사를 다시 실행하며 모든 실패와 canonical attempt 선택 이유를 남긴다. 제품/테스트 수정으로 후보가 달라지면 영향 검증 후 최종 후보의 필수 집합을 다시 확보한다. 결과 보고서는 후보 범위 밖 evidence 영역에 먼저 작성해 문서 갱신으로 검증을 계속 무효화하지 않는다.

**종료:** `local-preflight`가 실제 전체 manifest를 읽고 COMPLETE를 반환한다. 원본 하나 삭제/변조, 필수 행 삭제, 후보/정책 변경, 다른 attempt 대체 시 nonzero다. 커밋 시 내용이 같아도 HEAD·dirty가 바뀐 provenance는 그대로 재검사하며 로컬 snapshot을 remote 증거로 조용히 승격하지 않는다.

## 9. R45 — 배포 전 준비와 공개 완료를 단계별 종료

1. **검토 가능한 로컬 결과:** 변경 파일별 목적·diff, 후보 snapshot, local manifest, 미해결 항목 0 여부, changelog/버전/API 변화 및 릴리스 명령을 준비한다. 범위에 맞는 commit·push를 실행할 수 있는 상태로 만들고, 실제 실행은 해당 작업에 대한 요청 범위에 따른다.
2. **원격 배포 전 검증:** 정확한 두 repository revision을 올린 뒤 local/upstream/remote ref와 보존한 원본 변경을 대조한다. R43의 무배포 producer 및 독립 검증을 실제 수행한다. 필수 UI/VoiceOver 증거와 후보에 결합된 승인 경로까지 점검한다. 태그 이름·버전·API baseline 사전 검사는 태그 공개 전에도 수행 가능하게 구성한다.
3. **승인 직전 인계:** 배포 대상 SHA/버전, 실제 증거, 남은 외부 입력과 publication 명령이 검토 가능해야 한다. 사용자가 승인할 내용은 이 완성된 결과다. 필수 gate가 남아 있으면 “배포 준비 완료”로 표시하지 않는다.
4. **공개 및 설치 확인:** 공개 배포가 요청된 경우에만 태그·Release를 실행하고 그 태그의 SHA/배포물 digest를 재확인한다. local path override와 기존 캐시 없는 독립 소비자에서 공개 `6.0.0`을 resolve/build해 runtime·macro 진입점을 확인한다. 실패 시 배포 완료 검증을 닫지 않고 원인/복구 계획을 제시한다. 공개 태그를 임의로 이동하지 않는다.
5. 성공한 push 뒤에는 remote parity와 worktree 검사를 마친 후 전역 AGENTS 규칙의 XcodeBuildMCP cleanup을 수행한다. 활성 빌드는 중단하지 않으며 회수 용량·여유 공간을 기록한다. 원본 evidence의 위치는 cleanup 대상과 분리한다.

**종료 상태:** `로컬 필수 검증 완료` → `원격 무배포 검증 완료` → `배포 승인 준비` → `배포 준비 완료(승인 포함)` → `공개 배포·독립 설치 완료`. 각 상태의 실제 증거 없이 다음 상태로 올리지 않는다. 최종 공개 설치는 배포 준비의 선행 blocker가 아니다.

## 10. 가정·미확인 사항·실행 경계

| 항목 | 기본 진행안 / 확인 책임 |
| --- | --- |
| iPhone contrast 원인 | 미확정. 구현 담당자가 원본+독립 최소 재현으로 먼저 판정하고 제품 수정 또는 검토 가능한 예외 근거를 준비 |
| Swift 6.3 환경 | 구현 초기에 로컬·연결 호스트를 조사. 실제 사용 가능한 compiler/SDK가 없으면 구체적인 설치·접근 조건을 프로젝트 소유자에게 제시 |
| macOS GUI·VoiceOver | 실제 세션/관찰 수단을 확인. 자동화로 수행·검증할 수 없는 부분은 플랫폼별 수행 절차와 남은 관찰만 요청 |
| trusted consumer 실행 위치·credential | 로컬 producer 정의·권한 최소화·fixture를 먼저 완성. private Mulbyul 접근 및 원격 실행 권한은 실제 계정/저장소 상태를 확인한 뒤 필요한 입력만 요청 |
| 원격 최신 변경 통합 | 현재 원격과 같다고 가정하지 않음. 격리 checkout에서 검토한 범위만 적용하고 새 candidate로 검증 |
| 완료 기준 변경 | Swift/OS 상향, 필수 검사 제거, blanket 접근성 예외는 기본 해법이 아님. 의미 변경이 필요하면 근거와 영향이 있는 별도 결정으로 기록 |

현재 실행 범위는 로컬 구현·검증까지다. remote workflow의 정의와 회귀는 로컬에서 구현했지만 commit·push·원격 실행·태그·배포는 실행하지 않았다. 실제 외부 상태 변경과 수동 관찰은 해당 권한과 수행 증거가 확보될 때만 완료 처리한다.

## 11. 계획 검토와 반례

- [x] 현재 기준 후보·로그·물별 실패 summary/test tree·producer/manifest 부재를 읽기 전용으로 확인했다.
- [x] 명령 matcher의 full→static 허용을 실제 함수로 재현하고 R39에 반영했다. CD checkout 순서 문제는 소스 수준 확인이며 원격 재현 완료로 주장하지 않는다.
- [x] 요구사항→작업→완료 조건→증거를 연결하고 기존 ID·과거 실행 기록을 보존한다.
- [x] R39의 v3 evidence schema, 정확한 명령·test identity·fresh xcresult 검증, 원자적 manifest 및 attempt 이력과 우회/손상/중단 회귀를 구현하고 일곱 self-test를 통과했다.
- R40 — **범위 제외 (2026-09-18 사용자 결정).** 물별 contrast/24조합의 과거 구현·증거는 보존하되 InnoFlow 릴리스의 재검증 조건으로 요구하지 않는다.
- R41 — **범위 제외 (2026-09-18 사용자 결정).** 물별 기능·복구·Mac UI·좁은 창·iPhone/iPad/Mac VoiceOver는 미완료 차단 목록에서 제거한다. 검증 통과로 변경한 것은 아니다.
- [ ] R42는 Xcode 27.0 (`27A5252f`) / Apple Swift 6.4에서 779개 package test를 통과했다. 이 호스트에 정확한 Swift 6.3 toolchain이 없어 6.3 행은 미완료다.
- [ ] R43은 R52의 물별 없는 producer·CD 전환과 독립 provenance 검증을 완료해야 한다. 검토된 revision의 원격 실행은 별도 승인 단계다.
- [ ] R44는 R52 이후의 프레임워크 전용 정책으로 최종 후보 receipt를 재수집한다. 2026-09-18 기준 예상 집합은 local 24개·pre-publication 3개·post-publication 1개이며 각 단계별로 판정한다. 물별 41개는 제외한다.
- [ ] R45의 승인·태그·공개 배포·독립 설치는 요청·증거가 없으므로 미수행이다.

필수 반례: “전체” 이름에 static-only 결과, 다른 저장소의 깨끗한 diff, 임의 필터 0-test, nil issue 횟수만 허용, 한 플랫폼 VoiceOver로 세 플랫폼 충족, 생성 프로젝트만 빌드, producer 자기 성공 순환 대기, 다른 consumer/attempt artifact, 원본 없는 summary, 실패 행 삭제, 소스 변경 후 이전 receipt, 공개 설치 없는 배포 완료. 이 중 하나가 서면 조건을 모두 충족하고도 허용된다면 해당 AC를 보완한 뒤 구현한다.
