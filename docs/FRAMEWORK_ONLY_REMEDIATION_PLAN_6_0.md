# InnoFlow 6.0.0 — 프레임워크 단독 검증 및 추가 결함 수정 계획

- 문서 상태: **Draft**. 실행 상태: R52/R57 로컬 구현·검증 완료, R53/R55 재개, R54/R56/R58 부분 완료, 2026-09-18. 9월 23일 종합 검토 이후 최종 활성 순서는 [배포 전 실행 계획 R68 → R69 → R59~R67](PRE_RELEASE_EXECUTION_PLAN_6_0.md)을 따른다. 정확한 Swift 6.3, 후보 결합 receipt/manifest, 원격·공개 단계는 열린 차단 조건이다.
- 결정권자: 프로젝트 소유자. 물별 검증 제외는 2026-09-18 사용자 지시로 확정했다. 상세 구현 계획의 검토자·승인일은 미기록이다.
- 기준: `release/6.0.0-local`, HEAD `dbd6cfec40e302fc03ac9f8f35ff810d30d48014`와 기존 미커밋 변경. 사용자 생성물과 다른 저장소의 작업은 보존한다.
- 상위 계약: [구현 계획](IMPLEMENTATION_PLAN_6_0.md)의 FR-007/AC-007 개정, NFR-001/003/004/005. [R46~R51 계획](VALIDATION_REMEDIATION_PLAN_6_0.md)의 미충족 조건을 계승한다.
- 실행 순서: **IF6-R52 → R53 → R54 → R55 → R56 → R57 → R58**. 각 단계에서 반례 고정 → 수정 → 정상/실패 대조 → 관련 문서·게이트 갱신을 마친다.
- 현재 변경은 runtime, JSON 정책, workflow와 검증 도구에 구현됐다. commit/push·원격 규칙·배포 승인은 수행하지 않았다. 물별 요구는 활성 정책·workflow에서 제거했다.

## 1. 범위 결정과 기준 사실

### 물별 검증 제외 — 즉시 적용되는 계획·체크리스트 결정

- 물별 feature/navigation/recovery, iPhone/iPad/Mac UI, 접근성 24조합, 실제 VoiceOver, Reduce Motion, RTL/긴 콘텐츠, 좁은 Mac 창, 물별 diff 검사를 **InnoFlow 검증 목록에서 제외**한다.
- 물별 저장소·제품 테스트·기존 결과를 삭제하거나 변경하지 않는다. 물별에 관해 검증 통과·사용성 보장·예외 승인을 부여한 것으로 해석하지 않는다.
- IF6-R40/AC-R040, IF6-R41/AC-R041은 이 릴리스의 필수 범위에서 제외한다. R48의 물별 checkout 검증 의무도 R52로 대체한다. 기존 ID와 과거 실행 기록은 보존한다.
- R44/R51의 전체 증거 집합은 물별 없는 새 정책을 기준으로 다시 계산한다. 과거 실패를 PASS로 바꾸거나 실패 이력을 삭제하지 않는다.
- 프레임워크 자체의 Apple 멀티플랫폼, Swift 6.3/6.4, Core 독립성, macro/compile contract, 독립 소비자·Catalyst, canonical sample, coverage, sanitizer, CI·release provenance 검증은 유지한다. 다른 제품 앱을 새 필수 소비자로 지정하지 않는다.

### 확인된 사실

2026-09-18 직전 검토에서 다음을 실행으로 확인했다. 임시 원본은 `/tmp/innoflow-review-20260918.rT7TXR/`이며 구현 시 최소 fixture를 저장소 테스트로 편입한다. 이 경로의 존재를 향후 gate의 전제로 삼지 않는다.

1. 다른 임시 package에 정책과 같은 31개 표시명만 넣어도 공식 recorder가 현재 InnoFlow 후보의 `external-macro-consumer PASS` receipt를 발급했다. 전체 manifest는 나머지 64개 누락으로 차단됐다.
2. 컬렉션 삭제 뒤 `ScopedStore.optionalState`, `SelectedStore.optionalValue`는 nil, 두 `isAlive`는 false지만 네 관찰 callback은 모두 0회였다. 일반 값 변경은 정상 알림을 보냈다.
3. 미완료 run/leaf, run 사이 숫자 불일치의 상쇄, 중복 leaf 로그를 parser가 인정했다.
4. 실제 성공한 Swift 6.4 테스트의 `signal 9` 및 내부 따옴표 표시명을 parser가 거부했다.
5. 새 실패 job의 집계 누락, 집계 step `if: false`, 결과 명령 `|| true` 변이가 CI checker를 통과했다. 현재 workflow가 무조건 성공한다는 뜻은 아니다.

기존 집중 테스트 132개/6 suite와 static/self-test/actionlint는 통과했다. 이 정상 결과는 위 반례의 통과를 대신하지 않는다. 이번 계획 작성에서 runtime을 다시 실행하지 않았다.

현재 JSON 정책을 펼친 기준: local-preflight **65개 중 물별 41개 제외 → 24개 유지**, pre-publication 3개, post-publication 1개 유지. 이는 변경 전 정책으로 계산한 예상 집합이며, 구현 후 실제 ID 목록과 대조한다. 원본 문서의 68개 등 과거 수치를 새 정답으로 복사하지 않는다.

### 2026-09-18 구현 및 실행 결과

아래는 후속 재검토 전의 실행 이력이다. SDK no-build·runtime package-root 우회, parser 역순/중복 identity, runtime inventory/관찰 회귀 누락, toolchain 명령 정책 불일치가 추가 확인되어 R53/R55를 재개했다. 전체 성공 수치는 해당 실행의 기록이며 새 후보의 공식 receipt나 누락된 직접 회귀의 증거가 아니다. 상세 반례와 종료 조건은 [R59~R67](PRE_RELEASE_EXECUTION_PLAN_6_0.md)에 기록한다.

- R52: 활성 정책은 local-preflight 24개, pre-publication 3개, post-publication 1개로 고정됐다. 물별 checkout·입력·token·SHA·matrix를 제거했고, 재도입 변이는 checker self-test가 거부한다.
- R53: root SwiftPM 검사는 `--package-path`, SDK 검사는 `-project`/`-workspace`/`-packagePath` 우회를 거부한다. receipt의 후보 상대 `componentPath`는 `.`으로 검증되며, 외부 macro inventory 31개를 정확히 대조한다.
- R54: 컬렉션 항목 삭제 시 `ScopedStore`와 `SelectedStore`의 생존/optional 관찰이 각각 한 번 무효화되고, 반복 삭제와 형제 삭제는 중복·오염 알림을 만들지 않는다. 신규 2개 회귀를 포함해 전체 Debug/Release가 통과했다.
- R55/R56: run/test/suite 시작·종료와 run별 summary를 모델링하는 fail-closed parser로 교체했다. 미완료·중복·상쇄·실패·skip·signal은 거부하고, 내부 따옴표·Unicode·상태 단어가 포함된 정상 표시명과 parameter case는 통과한다.
- R57: CI의 비집계 job 전체 분류, exact `needs`, 결과 행렬, 집계 step의 무조건 실행·실패 전파를 검사한다. 새 job, `if: false`, 모든 `continue-on-error`, `|| true` 변이는 거부하며 `actionlint`도 통과했다.
- R58 실행: full principle은 Debug 713개/58 suite와 macro 68개/5 suite, Release의 같은 집합, timing 1개와 sample/compile 계약까지 통과했다. coverage는 전체 86.69%, Core 89.42%, Macros 83.33%, SwiftUI 65.17%, Testing 84.63%다. TSan/ASan은 각각 53/53, Catalyst 외부 소비자는 통과했다. Swift 6.4는 runtime 713개와 macro 68개가 통과했고, 5 SDK generic build가 통과했다.
- 설치된 runtime 8개(iOS 18.5/27.0, tvOS 18.5/27.0, watchOS 11.5/27.0, visionOS 2.5/27.0)는 각각 53/53, failed/skipped/expected failure/runtime warning 0으로 통과했다.
- runtime 행렬 실행 중 macOS 기본 Bash 3.2에서 빈 `forwarded`/`workspace_args` 배열이 실제 테스트 전에 중단시키는 결함 2개를 발견해 조건부 argv 구성으로 수정했다. 프로젝트 없음/있음과 전달 인자 없음/있음 회귀 self-test를 추가했다.
- 미완료: 이 머신에는 정확한 Swift 6.3이 없다. 최종 후보 digest에 결합된 24개 local receipt/manifest, 정확한 SHA의 원격 CI·producer·required check, 승인·tag·공개 설치 증거도 아직 없다. 따라서 로컬 구현 완료를 6.0.0 release-ready나 공개 배포 완료로 표현하지 않는다.

## 2. 요구사항 → 작업 → 완료 조건

| 순서 / 작업 | 요구사항 | 완료 조건 | 증거 |
| --- | --- | --- | --- |
| 1 / IF6-R52 범위·배포 경로 정리 | 개정 FR-007/AC-007, NFR-001/005 | AC-R052: 물별 코드·checkout·token·SHA·receipt 없이 프레임워크 검증 경로를 구성하며 나머지 gate는 보존 | 정책 ID 차집합, checkout/manifest 변이, static/self-test/actionlint |
| 2 / IF6-R53 후보와 실행 대상 결합 | FR-007, R39/R47, NFR-005 | AC-R053: 다른 package/project/workspace 실행과 stale 결과가 현재 후보 PASS가 될 수 없음 | 명령 정상/경로 우회, 실제 recorder→verifier 대조 |
| 3 / IF6-R54 파생 Store 삭제 관찰 | FR-007, NFR-003/004/005 | AC-R054: 삭제 시 lifecycle-aware observer가 무효화되고 값·소유권·형제 격리를 유지 | 삭제/일반 변경/형제/재삽입/해제 회귀 |
| 4 / IF6-R55 로그 완전성 | FR-007, R46, NFR-005 | AC-R055: run별 시작·종료·leaf·suite·summary가 맞아야 통과 | 미완료·중복·상쇄·실패·skip·중단 fixtures |
| 5 / IF6-R56 표시명과 상태 분리 | FR-007, R46, NFR-005 | AC-R056: 정상 표시명을 인정하고 실제 실패·skip·signal을 차단 | Swift 6.3/6.4 실제 출력과 parser 대조 |
| 6 / IF6-R57 CI 집계 회귀 방어 | FR-007, R50, NFR-005 | AC-R057: 미분류 job·needs 누락·실행 생략·실패 무시를 checker가 거부 | job/result/조건/shell 변이와 actionlint |
| 7 / IF6-R58 최종 후보 통합 검증 | FR-007, R42/R43/R44/R45, NFR-001/005 | AC-R058: 남은 모든 필수 증거가 최종 후보에 결합되고 로컬/원격/공개 상태가 분리 | 새 snapshot/manifest, 전체 회귀, 별도 승인된 원격 결과 |

## 3. R52 — 물별 없는 검증·배포 경로

대상: `docs/contracts/release-evidence-policy.json`, `.github/workflows/release-evidence.yml`, `.github/workflows/cd.yml`, `scripts/check-release-evidence-workflow.rb`와 self-test, evidence/snapshot self-test, `RELEASING.md`, 관련 활성 계획·검증 문서.

1. 제외 ID 목록을 검토 가능한 변경 기록으로 고정한다. `mulbyul-*` 이름만 필터링하지 않고 `static-mulbyul-diff`, `actual-voiceover-navigation-*`, component/environment가 물별인 항목과 matrix를 함께 제거한다. optional로 남겨 자동 실행을 유도하지 않는다.
2. 두 workflow의 물별 SHA 입력·추출, 저장소 checkout, `MULBYUL_READ_TOKEN` 참조, 물별 component 검증·snapshot 인자를 제거한다. checker의 checkout 개수·label·입력 계약도 프레임워크 단독 구성에 맞춘다. 원격 secret 자체 삭제는 하지 않는다.
3. 정식 릴리스 snapshot의 구성은 InnoFlow로 고정한다. 일반 snapshot 도구의 다중 저장소 지원까지 불필요하게 없애지 않는다. 새 policy digest를 사용하고 예전 물별 포함 snapshot/receipt를 새 후보로 재표기하지 않는다. 이전 bundle은 보존하되 새 intake에는 명시적 재수집을 요구한다.
4. 물별 없는 checkout/입력으로 local-preflight와 producer/CD 검증 경로의 로컬 smoke를 수행한다. 물별 참조가 다시 들어오는 변이, 남은 required 항목 누락, 다른 component 대체는 차단한다. fixture 실행을 원격 producer 성공으로 보고하지 않는다.
5. 샘플 build/UI, 독립 macro 소비자, SDK/runtime, coverage/sanitizer, release 승인·provenance 조건은 제거하지 않는다. 같은 주제의 모든 접근성 문서를 전역 삭제하지 않는다.

**종료:** 계획된 41개만 제외됐음을 ID 차집합으로 증명하고 남은 24개 local·3개 pre·1개 post ID가 보존된다. 물별 repo/token/SHA/증거 없이 실행 경로의 전제조건을 충족한다.

## 4. R53 — 검증 명령을 실제 후보에 결합

대상: `scripts/record-release-evidence.sh`, `scripts/release-evidence-tool.rb`, 정책의 `commandContract`, `scripts/verify-release-evidence-selftest.sh`, `scripts/check-release-evidence-policy.rb`와 self-test.

1. 직전 foreign-package receipt 반례를 독립 음성 fixture로 고정한다. 정상 root 명령과 허용되는 sample/consumer 실행을 대조군으로 둔다.
2. 실행 전에 command의 유효 package/project/workspace와 component root를 정규화해 검사한다. 공백형·등호형·중복 옵션·상대 경로·`..`·symlink를 다루고, 허용 대상이 불명확한 경로 재지정은 거부한다. check별로 허용한 root 또는 후보 내부 입력만 인정한다.
3. 검증된 실행 대상의 논리 역할·후보 상대 경로를 receipt에 남기고 verifier도 이를 확인한다. 다른 호스트의 절대 경로 문자열 동일성을 요구하지 않는다. 새 필수 필드가 필요하면 schema/호환 규칙을 명시하며 과거 receipt를 조용히 승격하지 않는다.
4. 현재 후보의 실제 discovered test ID와 검토된 필수 inventory를 대조한다. 표시명·총개수만 같은 다른 집합은 통과하지 않는다. discovery의 filter 적용 여부도 실제 출력으로 검증한다.
5. CompileContractTests 내부에서 의도적으로 생성하는 독립 consumer package는 유지한다. 금지 대상은 root 검증 명령을 무관한 package로 바꾸는 행위이지 외부 소비자 테스트 자체가 아니다.

**종료:** foreign-package 반례는 실행 전 nonzero이며 PASS receipt가 없다. 정상 후보의 recorder→raw result→receipt→verifier는 통과한다. 전체 manifest의 다른 누락은 여전히 INCOMPLETE다.

## 5. R54 — 삭제·비활성 상태의 관찰 알림

대상: `Sources/InnoFlowCore/ScopedStore.swift`, `SelectedStore.swift`, 필요 시 `ProjectionObserverRegistry.swift`, `Tests/InnoFlowTests/StoreScopeSelectionTests.swift`, `CollectionScopeCacheTests.swift`, `ARCHITECTURE_CONTRACT.md`와 관련 authoring 문서.

1. 임시 RuntimeProbe의 정상 변경/삭제 대조를 정식 테스트로 이식한다. 원래 package 설정에서 먼저 실패를 확인한다.
2. 생존 상태를 관찰 가능한 상태 또는 명시적 lifecycle invalidation으로 연결한다. 우선 최소 변경안을 검토하되 registry 전체 강제 refresh나 강한 parent 참조로 문제를 숨기지 않는다.
3. `optionalState/optionalValue/isAlive`만 읽은 각각의 observer가 삭제 전이를 통지받도록 한다. `withObservationTracking`의 한 번 등록당 onChange 의미에 맞춰 기대 횟수를 정하고, callback 내부에서 변경 후 값이 이미 보인다고 가정하지 않는다. dispatch 완료 후 값은 nil/false여야 한다.
4. 형제 변경·형제 삭제는 생존 row를 불필요하게 무효화하지 않아야 한다. 같은 ID 재삽입 시 이전 projection은 계속 비활성이고 새 projection이 정상 동작해야 한다. 반복 삭제·후속 dispatch의 중복 알림, root 해제 시 nil 계약, weak cache·메모리 해제도 검사한다.
5. Debug assertion, Release cached fallback, dead projection send/no-op 및 `requireAlive` 계약은 보존한다. MainActor 밖 무리한 호출·sleep 기반 검증 대신 결정적인 dispatch 완료 경계를 사용한다.

**종료:** 삭제 반례와 기존 scope/selection/cache 테스트를 Debug·Release에서 통과한다. 지원 플랫폼 runtime의 해당 회귀는 R58에 포함하며 물별 화면은 실행하지 않는다.

## 6. R55 — 실행별 로그 완전성

대상: `scripts/release-evidence-output-parser.rb`, 전용 self-test, evidence verifier self-test, 최소 실제 로그 fixtures.

1. run 경계와 test/suite의 시작·종료·summary를 별도로 모델링한다. 서로 다른 run의 수를 먼저 합산해 누락을 상쇄하지 않는다. Debug/Release에서 같은 테스트가 다시 실행되는 것은 각 run 안에서 검증한다.
2. 미완료 추가 run, 시작만 있는 leaf, 중복 종료, summary 선행/누락, run별 불일치, 0-test, 실제 실패/취소/skip을 거부한다. 잘린 로그를 원인 없이 leaf mismatch 하나로만 설명하지 않는다.
3. parameterized declaration 수와 case 수를 구분하고 bundle별 결과를 확인한다. 동일 표시명을 가진 서로 다른 테스트를 하나로 dedup하지 않는다. R53 discovery identity와 연결한다.
4. 지원 toolchain의 안정된 machine-readable 결과 사용 가능성을 먼저 확인한다. 텍스트만으로 ID나 경계를 구분할 수 없는 경우는 명시적으로 차단하며, 표시명으로 임의 추정해 PASS를 내지 않는다. 포맷 변경은 recorder/verifier와 함께 적용한다.
5. 실제 정상 소규모 실행과 실제 실패·skip 실행을 fixture로 보존한다. wrapper가 실패를 exit 0으로 가린 로그도 거부하고 실제 프로세스 종료 코드 검사는 계속 유지한다.

**종료:** 직전 4개 불완전 로그 반례가 모두 거부되고 정상 단일/복수 bundle·parameterized 출력은 통과한다. 과거 전체 로그 replay는 parser 회귀 증거일 뿐 새 후보 실행 receipt가 아니다.

## 7. R56 — 표시명과 결과 상태 분리

대상: R55의 parser/fixtures/self-test와 toolchain 검증 경로.

1. `signal 9`, `failed`, `skipped`, 내부 따옴표·역슬래시·Unicode 표시명의 실제 정상 출력을 고정한다. quoted/unquoted·parameterized·ANSI·줄바꿈 변형을 포함한다.
2. 표시명 내부 단어를 결과로 해석하는 전역 검색을 없애고 terminal/진단 줄의 구조로 상태를 판단한다. 표시명 안의 summary 유사 문자열도 run summary로 세지 않는다.
3. 실제 `skipped:`와 disabled/빈 arguments 출력, 실제 signal 진단·실패 leaf·실패 suite·실패 summary는 계속 거부한다. 모르는 terminal 형식은 조용히 무시하지 않는다.
4. Swift 6.4뿐 아니라 지원 최소선인 Swift 6.3의 실제 출력도 확보한다. 6.3 환경이 없으면 해당 compatibility 조건을 열린 상태로 남긴다.

**종료:** 정상 이름 반례는 통과하고 이름만 비슷한 실제 실패는 거부한다. R55의 불완전 로그 차단이 함께 유지된다.

## 8. R57 — CI 집계 누락과 실패 무시 차단

대상: `.github/workflows/ci.yml`, `scripts/check-ci-efficiency.rb`와 self-test, `scripts/check-required-ci-results.rb`와 self-test, `docs/CI_GATES.md`.

1. 실제 workflow job 집합과 required/조건부/aggregate 분류를 완전히 대조한다. 새 job은 명시적으로 분류되기 전 실패한다. 서로 복사한 두 고정 목록이 일치한다는 이유만으로 완전하다고 판단하지 않는다.
2. required job·needs·전달 인자가 빠지거나 중복/unknown인 경우를 차단한다. PR의 push-only ASan skip만 현재 정책대로 허용하고 그 밖의 failure/cancel/skip/empty는 실패한다. 선택 ASan은 최신 SHA 검증을 별도로 유지한다.
3. 집계 step의 조건·continue-on-error·실행 명령을 제한된 명확한 형태로 고정한다. `if: false`, 표현식형 실패 무시, `|| true`, `exit 0`, 명령이 주석/echo에만 있는 변이를 거부한다. 임의 shell을 부분 문자열만으로 안전하다고 판단하지 않는다.
4. 무거운 검사를 집계 job에서 다시 돌리지 않는다. 모든 required 성공 대조와 실제 결과 판정 스크립트의 nonzero 전파를 로컬에서 검증한다.
5. `CI Required`의 실제 GitHub check 확인·main 규칙 연결은 승인된 원격 단계로 남긴다. 로컬 checker 통과와 원격 병합 차단을 구분한다.

**종료:** 직전 3개 CI 변이와 결과 행렬의 실패 대조가 모두 거부된다. 정상 workflow는 checker/actionlint를 통과하고 기존 ASan 이벤트 계약도 유지한다.

## 9. R58 — 최종 검증과 인계

1. 매 단계는 관련 테스트만 실행한다. 빠른 gate는 `git diff --check`, static principle, principle self-test, parser/policy/evidence/CI 전용 self-test, actionlint다. source·test inventory 변경 시 기대 개수도 discovery와 검토된 ID 기준으로 갱신하며 범위를 넓혀 통과시키지 않는다.
2. R52~R57의 source·정책·문서를 안정화한 뒤 새 candidate snapshot을 만든다. 정책 변경 이전 receipt와 임시 반례 receipt를 가져오지 않는다.
3. 최종 후보에서 full principle을 한 번 실행해 Debug/Release·sample·성능을 확인한다. coverage, TSan/ASan, macro/독립 compile consumer/Catalyst, Swift 6.3/6.4, 5 SDK, 지원 runtime 행렬 및 R54 신규 회귀를 검증한다. 환경이 없으면 해당 행만 미완료로 표시한다.
4. 남은 정책 ID별 정상 receipt를 수집하고 verifier를 실행한다. local-preflight 통과와 pre-publication 승인/원격 증거, post-publication 설치 확인은 별개다. 물별 증거는 어느 단계에서도 다시 요구하지 않는다.
5. 별도 승인된 push/PR 경로에서 정확한 SHA의 CI, 선택 ASan, producer 및 필수 check 적용을 확인한다. tag-only producer를 시험하려고 임의 공개 tag를 만들지 않는다. 승인·태그·공개 배포·공개 설치는 자동 후속 작업이 아니다.
6. 외부 push가 승인돼 수행됐다면 remote parity와 worktree 보존을 먼저 검증하고 전역 지침의 XcodeBuildMCP cleanup을 수행한다. 활성 build를 중단하지 않는다.

### 현재 활성 검증 목록

- [x] R52 물별 전용 정책 41개 및 실행·checkout·token·snapshot 의존성 제거.
- [ ] R53 재개: 기존 root 우회 차단은 유지. SDK no-build/runtime helper package-root 및 정식 Swift 명령 정합성은 R59에서 해결.
- [ ] R54 부분 완료: desktop 삭제 관찰 회귀 통과. 필수 플랫폼의 직접 삭제/재삽입/격리 회귀는 R61에서 완료.
- [ ] R55 재개: run별 총수 검사는 구현됨. 이벤트 역순·중복 identity·모호한 표시명은 R60에서 해결.
- [ ] R56 부분 완료: Swift 6.4 정상 표시명과 상태 분리 회귀 통과. 정확한 Swift 6.3 실제 출력은 R60/R66의 열린 호환성 조건.
- [x] R57 job inventory·집계 실행·실패 전파 회귀 통과.
- [ ] R58 InnoFlow 자체 Debug/Release·coverage·sanitizer·macro/독립 소비자·sample·Swift 6.3/6.4·5 SDK/runtime·최종 local manifest 검증.
- [ ] 별도 승인 단계: 최신 SHA 원격 CI·producer·main required check, 배포 승인·공개 설치.

물별의 기능·UI·접근성·VoiceOver 검증은 이 목록에 없으며, 미완료 차단 조건으로 다시 집계하지 않는다.

## 10. 설계 선택·미확인 경계·완료 표현

- **범위 선택:** 물별 검증을 optional로 남기거나 다른 앱으로 대체하지 않고 InnoFlow 릴리스에서 분리한다. 기존 제품 결과는 역사적 기록으로 보존한다.
- **관찰 선택:** 생존 상태의 관찰 신호를 우선한다. 전체 Store 강제 재발행·parent 강한 참조는 중복 갱신/수명 연장 때문에 기본안에서 제외한다.
- **parser 선택:** 명시적 실행 상태와 실제 toolchain 결과를 사용한다. 신뢰할 수 있는 구조화 결과 지원 여부는 R55 시작 시 확정할 기술 조사 항목이다. 지원하지 않는 형식은 누락 검사를 완화하지 않고 차단한다.
- **CI 선택:** job 분류의 완전성 검사와 제한된 집계 실행 계약을 사용한다. 고정된 목록 복제·임의 shell의 부분 문자열 검사는 완료 조건을 만족하지 않는다.
- **환경 미확인:** Swift 6.3, 지원 simulator runtime, trusted runner와 원격 권한은 실행 시 재확인한다. 물별 token/GUI/VoiceOver 수단은 더 이상 필요한 환경이 아니다.
- **실패 시:** 단계 실패는 receipt/attempt와 원본을 보존하고 해당 단계에서 원인을 수정한다. broad reset·기존 artifact 삭제·gate 예외를 해결책으로 쓰지 않는다.
- **상태 보고:** 계획 작성, 로컬 구현, 최종 후보 검증, 원격 보호 적용, 공개 배포를 따로 기록한다. R52의 범위 축소를 품질 테스트 통과로 보고하지 않는다.

### 계획의 반례 검사

다음 구현이 완료로 인정될 수 있다면 계획 또는 AC를 보완해야 한다: 문서에서만 물별을 빼고 token/SHA를 계속 요구함; 표시명 31개만 같은 무관한 package를 통과시킴; 삭제 후 직접 읽기만 nil이고 observer는 통지받지 못함; 다른 run의 숫자로 누락을 상쇄함; 정상 이름을 signal로 판정함; 새 job이 분류 밖에 있거나 집계 실행이 생략돼도 성공함; 물별 제외를 Swift 6.3·플랫폼 runtime 제외로 확대함.
