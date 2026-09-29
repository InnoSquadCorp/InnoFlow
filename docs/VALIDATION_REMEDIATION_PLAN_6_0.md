# InnoFlow 6.0.0 — 검증·배포 경로 결함 수정 계획

> 2026-09-18 후속 결정: [프레임워크 단독 수정 계획](FRAMEWORK_ONLY_REMEDIATION_PLAN_6_0.md)의 R52~R58이 현재 활성 계획이다. 물별 검증은 사용자 지시로 제외하고 R48의 물별 checkout 검증 의무는 R52에서 제거한다. 아래 수행 이력은 보존하지만 R46/R47/R50은 추가 반례를 해결하기 전 완료로 판정하지 않는다. 물별 UI/VoiceOver 등의 기존 유지 문구는 이 결정으로 대체한다.

- 상태: **추가 반례에 따라 R46/R47/R50 재개, 물별 검증 범위 제외**, 2026-09-18. 이전 로컬 회귀 이력은 보존한다.
- 결정권자: 프로젝트 소유자. 구현 담당: 후속 실행 담당자. 검토자·승인일: 미기록.
- 기준: `release/6.0.0-local`, `dbd6cfec40e302fc03ac9f8f35ff810d30d48014`.
- 상위 계약: [구현 계획](IMPLEMENTATION_PLAN_6_0.md)의 FR-007, NFR-001/005와 [배포 차단 조건 계획](RELEASE_BLOCKER_PLAN_6_0.md)의 R39/R43~R45.
- 범위: 직전 검토에서 확인한 증거 파서·명령 정책·consumer checkout·ASan 이벤트·원격 필수 검사 문제. 기존 작업 ID를 유지하고 **IF6-R46~R51 / AC-R046~051**을 추가한다.
- 목적: 정상 검증은 정확하게 인정하고 실패·누락은 계속 차단하는, 실제 실행 가능한 검증 경로를 만든다. 이 작업 완료와 6.0.0 전체 배포 준비 완료는 구분한다.

## 1. 사실·가정·제외 범위

### 확인한 기준

- 계획 작성 시 HEAD와 작업 트리를 재확인했다. tracked 변경은 없고 사용자 생성물 `Derived/`, `InnoFlow.xcodeproj/`가 존재한다. 이 문서 추가 이후 candidate digest는 이전 검증 후보와 다르다.
- 같은 HEAD에 대한 직전 검토에서 Swift 6.4 집중 테스트 runtime 249 + macro 68 = 317개, static principle 및 principle self-test가 통과했다. 전체 Debug/Release·플랫폼·물별 UI를 이번 계획 작성에서 재실행하지 않았다.
- `validate_swift_test_output!`는 실제 성공한 파라미터화 테스트, 이름에 `skipped`가 포함된 테스트, 표시명 없는 테스트/스위트를 거부했다. 일반 테스트 대조군은 인정했다.
- `external-macro-consumer`는 `--filter CompileContractTests`만 허용하지만 해당 suite 31개와 정책의 최대 1개가 충돌한다. 특정 테스트 하나로 좁히는 명령도 현재 정책에서 거부된다.
- producer와 CD는 `InnoSquad/Mulbyul`을 참조한다. 직전 GitHub 조회에서 해당 경로는 404였고 실제 consumer 원격 `InnoSquadCorp/Mulbyul`은 조회됐다. checker도 잘못된 주소를 요구한다.
- ASan 전용 workflow는 `labeled`만 받는다. 추가 commit의 `synchronize`와 `reopened`에서 실행되지 않는다. 일반 라벨 이벤트도 workflow 수준의 동일 concurrency group에 들어간다.
- 직전 원격 조회에서 `main`에 적용되는 rules 결과는 비어 있었고 legacy branch protection도 없었다. 기준 release branch의 PR·CI run은 없었다. 이 원격 상태는 적용 직전에 다시 조회해야 한다.

임시 재현 자료는 `/tmp/innoflow-review.00FenV/`의 스크립트·네 가지 parser 로그·`selected-tests.log`다. 실행 단계에서 검토된 최소 fixture로 저장소에 편입한다. `/tmp` 파일을 장기 릴리스 증거나 향후 존재가 보장된 의존성으로 사용하지 않는다.

### 유지할 경계

- framework public API, runtime 기능, 최소 OS/Swift 버전, Mulbyul 제품 UI는 이번 결함 수정의 기본 변경 대상이 아니다.
- 실패를 없애기 위해 coverage 기준, 필수 suite, sanitizer, UI/접근성 gate를 삭제하거나 성공·실패 결과를 이름만 바꾸지 않는다.
- Swift 6.3·실제 VoiceOver·Mac UI·최종 전체 manifest 등 기존 미완료 조건은 그대로 유지한다. 이 계획의 통과로 R41/R42/R44/R45 전체를 닫지 않는다.
- 이번 실행에서는 commit/push, PR 생성, GitHub rules 변경, 원격 workflow 실행, 태그·Release 공개를 수행하지 않았다. 외부 변경이 필요한 단계는 열린 상태로 인계한다.

## 2. 순서와 추적

순차 구현한다. 각 단계는 **현재 코드에서 반례 실패 확인 → 수정 → 정상 대조·음성 회귀 → 인접 경로 확인**을 마친 후 다음 단계로 넘어간다.

| 순서 | 작업 / 상위 요구 | 완료 조건 | 증거 |
| --- | --- | --- | --- |
| 1 | IF6-R46 증거 파서 / FR-007, NFR-005, R39 | AC-R046: 지원하는 실제 성공 출력은 인정하고 실패·skip·불완전 결과는 거부 | 실제 Swift 출력 fixture, parser 회귀, recorder→verifier round-trip |
| 2 | IF6-R47 매크로 증거 정책 / FR-007, NFR-005, R39 | AC-R047: 실행 범위·발견된 ID·필수 ID·결과 수가 일치 | 전체 compile-contract 실행 및 receipt, 다른 suite·0-test·부분 실행 차단 |
| 3 | IF6-R48 consumer 주소 / FR-007, NFR-005, R43 | AC-R048: 두 workflow가 실제 동일 consumer 저장소의 지정 SHA를 사용 | workflow 변이 테스트, 읽기 전용 접근·SHA 검사, checkout smoke |
| 4 | IF6-R49 ASan 이벤트 / FR-007, NFR-005 | AC-R049: 선택된 PR 최신 commit을 재검증하고 무관 라벨이 실행을 교란하지 않음 | 이벤트 행렬, concurrency 검사, 원격 최신 SHA 결과 |
| 5 | IF6-R50 필수 CI 결과 / FR-007, NFR-005, R43/R45 | AC-R050: 필수 job이 모두 성공해야 안정된 최종 check가 성공하고 원격 병합 조건에 연결됨 | 결과 행렬·누락 변이, 실제 check 이름/제공자, 적용된 원격 규칙 |
| 6 | IF6-R51 통합 검증·인계 / FR-007, NFR-001/005, R44/R45 | AC-R051: 최종 후보에서 위 계약과 증거 전달을 확인하고 미실행 gate를 분리 | 최종 diff, 실행 로그·receipt, 원격 parity·run SHA, 남은 gate 목록 |

## 3. R46 — 실제 Swift Testing 출력을 정확히 판독

대상: [release-evidence-tool.rb](../scripts/release-evidence-tool.rb), [verify-release-evidence-selftest.sh](../scripts/verify-release-evidence-selftest.sh), 필요 시 parser 전용 helper와 `scripts/fixtures/`의 소규모 실제 출력 fixture.

1. 기존 CLI 동작을 유지한 채 결과 해석을 독립적으로 테스트 가능한 함수로 분리한다. 현재 재현 세 가지와 일반 성공 대조군을 먼저 고정한다.
2. 줄의 구조를 따라 실행 시작·test/suite 종료·run summary를 구분한다. 표시명 내부의 `skipped`, `failed`, `signal`을 결과 상태로 해석하지 않는다. quoted display name, 기본 함수/타입명, `with N test cases`를 명시적으로 처리한다.
3. 논리 테스트 수와 파라미터 case 수를 구분한다. run별 terminal 결과를 집계하고 summary와 대조한다. ANSI/줄바꿈, 여러 test bundle, 중복·누락·중단된 실행도 회귀에 넣는다. 알 수 없는 terminal 출력으로 완전성을 판단할 수 없으면 원인을 남기고 차단한다.
4. 실제 failed/skip, leaf 실패 뒤 성공 summary, 0-test, 필수 suite 누락, 잘린 로그, wrapper가 실패를 exit 0으로 덮은 결과는 계속 거부한다. 성공 fixture만으로 테스트하지 않는다.
5. 실제 소규모 Swift 테스트를 실행해 recorder→raw log→receipt→verifier 경로를 확인한다. 전체 release manifest가 부족하면 aggregate는 여전히 INCOMPLETE여야 한다. 작은 fixture 정책의 통과를 canonical 정책 전체 통과로 보고하지 않는다.

**선택:** 상태별 파싱과 실제 fixture를 우선한다. skip 검사를 없애거나 summary 숫자만 신뢰하는 완화는 배제한다. 구조화된 결과 포맷으로의 전면 교체는 지원 toolchain의 실제 제공 계약을 확인한 별도 변경이며 이번 수정의 선행 조건으로 늘리지 않는다. receipt 형식 변경이 필요하면 schema/호환 규칙을 명시하고 기존 receipt를 조용히 재해석하지 않는다.

**종료:** 실제 정상 세 유형과 대조군이 모두 인정되고 모든 실패 대조군은 nonzero다. Swift 6.4 실출력과 Swift 6.3 실출력의 확보 여부를 따로 기록한다. 6.3이 없으면 그 호환성 검증은 미완료다.

## 4. R47 — 실행 명령과 필수 테스트 범위 일치

대상: [release-evidence-policy.json](contracts/release-evidence-policy.json), [CompileContractTests.swift](../Tests/InnoFlowTests/CompileContractTests.swift), evidence matcher/parser와 self-test, [배포 지침](../RELEASING.md).

1. 기본안은 기존 `CompileContractTests` 전체 검증을 유지한다. 단일 외부 consumer 메서드로 범위를 축소하지 않는다. 현재 31개를 출발점으로 하되 `maximumTestCount` 하나만 바꾸고 완료하지 않는다.
2. 실행할 최종 후보의 discovery에서 suite별 ID 목록을 확보하고 검토된 필수 ID 목록과 대조한다. CLI의 list가 filter를 실제 적용하는지도 검사한다. 미적용이면 discovery 결과에 명시적 suite ID 필터를 적용한다.
3. 필수 ID 목록은 검토 가능한 fixture/계약 파일로 관리한다. discovery 결과를 무조건 새 정답으로 덮어써서 테스트 삭제를 정상화하지 않는다. 정책 수치·필수 suite·명령 필터·기대 ID의 불일치가 실행 전에 드러나게 한다.
4. 전체 suite의 실제 실행을 recorder로 수집해 정상 receipt를 생성한다. 이름이 다른 suite, 임의 filter, `--skip`, 다른 package 경로로의 대체, 0-test, 필수 테스트 누락을 거부한다. 신원 확인을 위한 새 결과 필드가 필요하면 R46의 schema 결정과 함께 처리한다.
5. full-principle와 toolchain 행의 정확한 수치도 현재 입력과 대조한다. 불일치를 발견하면 해당 기대값/근거를 함께 수정하고, 단순히 범위를 넓히거나 상한을 삭제하지 않는다.

**대안:** 단일 외부 consumer 테스트만 별도 check로 분리할 수도 있으나, 전체 public compile-contract 검증의 다른 필수 소유자를 보장해야 한다. 이번 기본안은 기존 범위 유지다.

**종료:** 허용 명령으로 실제 필수 테스트를 모두 실행한 결과가 통과한다. 누락·대체 실행은 실패하고 전체 manifest의 다른 누락 항목은 계속 표시된다.

## 5. R48 — 정확한 Mulbyul 저장소와 SHA 연결

대상: [release-evidence.yml](../.github/workflows/release-evidence.yml), [cd.yml](../.github/workflows/cd.yml), [check-release-evidence-workflow.rb](../scripts/check-release-evidence-workflow.rb)와 self-test, 배포 지침의 실제 운영 경로.

1. InnoSquad 계정과 두 저장소의 canonical remote를 읽기 전용으로 재확인한다. 두 checkout 및 checker의 운영 기대값을 `InnoSquadCorp/Mulbyul`로 일치시킨다. 테스트용 임의 owner까지 전역 치환하지 않는다.
2. 정확한 40자리 consumer SHA, 전체 history/tag, credential 비보존, 별도 checkout 경로와 candidate component 검증은 유지한다.
3. workflow 한쪽만 수정, 잘못된 owner/repository, branch 대신 SHA 계약 위반, token 누락·접근 거부를 검사한다. 접근 실패 시 다른 저장소나 기본 branch로 fallback하지 않는다.
4. 승인된 원격 검증에서는 실제 workflow의 read token으로 빈 작업 디렉터리에 지정 SHA를 checkout하고 component digest를 확인한다. 로컬 `gh` 계정의 접근 성공을 Actions secret 접근 성공으로 대신하지 않는다. secret 값은 조회·출력하지 않는다.

**선택:** 확인된 canonical 경로를 명시적으로 사용한다. consumer 저장소를 임의 dispatch 입력으로 바꾸는 일반화는 하지 않는다.

**종료:** 로컬 checker/변이 테스트 통과와 실제 checkout smoke를 구분해 기록한다. runner/token 미확보 시 로컬 수정만 완료이고 원격 검증은 열린 상태다.

## 6. R49 — 선택 ASan이 최신 PR을 검증하도록 수정

대상: [asan.yml](../.github/workflows/asan.yml), [ci.yml](../.github/workflows/ci.yml), [check-ci-efficiency.rb](../scripts/check-ci-efficiency.rb)와 self-test, [CI_GATES.md](CI_GATES.md).

1. 전용 ASan workflow는 `opened`, `synchronize`, `reopened`, `labeled`를 처리한다. PR의 현재 `run-asan` 라벨을 검사하고, `labeled`인 경우에는 이번에 붙은 라벨도 `run-asan`일 때만 무거운 job을 시작한다.
2. 취소 가능한 concurrency를 실행 자격이 있는 ASan job에 적용해, 일반 라벨의 skipped 실행이 진행 중인 ASan을 취소하지 않게 한다. 같은 PR의 새로운 유효 실행은 이전 ASan을 대체하고 다른 PR은 독립적이어야 한다.
3. full CI는 일반 라벨에 재실행되지 않게 유지한다. label 없는 PR은 선택 ASan을 실행하지 않는다. 라벨 제거 후에는 새 ASan을 요구하지 않으며 이미 시작한 실행은 완료될 수 있음을 문서화한다. 태그 배포의 필수 sanitizer는 계속 유지한다.
4. checker는 이전의 `[labeled]` 문자열 일치를 강제하지 않고 아래 행동 행렬과 명령·권한·timeout·취소 범위를 검사하도록 바꾼다.

| 입력 | ASan 기대 결과 |
| --- | --- |
| `run-asan` 추가 | 현재 PR 실행 |
| 라벨 유지 + 새 commit / 재오픈 | 최신 SHA 실행, 이전 동일 PR 실행 대체 |
| 라벨 없는 PR 열기 / 갱신 | 실행 안 함 |
| 다른 라벨 추가 | 새 실행·기존 ASan 취소 없음 |
| 다른 PR 갱신 | 서로 취소하지 않음 |

**종료:** 이벤트 fixture와 실제 GitHub 실행을 별도 검증한다. 원격 확인은 run의 head/merge SHA 및 PR head 연결까지 확인하고 이전 commit의 성공을 최신 성공으로 인정하지 않는다.

## 7. R50 — 필수 CI 최종 결과와 원격 병합 조건

대상: `ci.yml`, CI checker/self-test, `CI_GATES.md`, `RELEASING.md`, 별도 승인 후 GitHub rules 설정.

1. 안정된 이름의 최종 job `CI Required`를 추가한다. `always()`로 결과 집계가 가능하게 하되 필수 결과가 모두 success인 경우에만 성공한다. 검사를 다시 실행하지 않고 기존 job 결과만 집계한다.
2. 필수 의존성을 명시한다: lint, coverage, Debug/Release, API compatibility, TSan, sample tests, 5 SDK builds, focused runtime, static principle, sample package build, canonical sample build/UI. push 이벤트의 ASan도 필수로 포함하고 PR에서 기존 push-only ASan의 skip만 명시적으로 허용한다.
3. 필수 job의 failure/cancel/skip/누락, 빈 결과, 새로운 필수 job의 집계 누락을 음성 테스트로 차단한다. 모든 결과가 success인 정상 대조도 둔다. 집계 job의 무조건 exit 0·`continue-on-error` 우회도 검사한다.
4. 선택 ASan을 모든 PR의 상시 required check로 등록해 라벨 없는 PR을 잠그지 않는다. 라벨로 요청한 ASan의 최신 SHA 완료 여부는 R49/R51 원격 검증에서 별도로 확인한다. 이 선택 검사를 상시 자동 병합 차단 조건으로 승격하는 것은 별도 정책 결정이다.
5. 원격 변경 승인 후 PR에서 실제 check 이름·GitHub Actions 제공자를 확인한다. 현재 rules/legacy protection을 저장하고 기존 보호를 보존하는 최소 변경으로 `main`에 새 최종 check를 required로 연결한다. 존재하지 않는 이름부터 등록하지 않는다. `develop` 등 다른 branch로 보호 범위를 임의 확대하지 않는다.
6. 적용 뒤 API로 branch에 실제 유효한 규칙과 required check를 재조회한다. 위험한 실패 commit을 main에 넣지 않고 격리된 검증 branch/PR 또는 결과 fixture로 실패 차단을 확인한다. 변경 전후 설정과 복구 절차를 남기며 오설정 시 보호 전체를 해제하지 않는다.

**선택:** 개별 matrix 표시명을 다수 등록하는 방식 대신 안정된 단일 집계 check를 사용한다. 전체 job 성공 없이 집계만 초록색이 되는 구현은 허용하지 않는다.

**종료:** 로컬 workflow 구현, 실제 PR check 성공, 원격 필수 검사 적용을 각각 기록한다. 관리자 권한이 없으면 마지막 상태를 완료로 표시하지 않는다.

## 8. R51 — 최종 후보로 연결 검증

1. R46~R50의 코드·정책·문서를 함께 검토하고 후보를 고정한다. 기존 결과를 새 digest에 복사하지 않는다. 사용자 생성물·무관한 변경을 보존한다.
2. 빠른 검증을 먼저 수행한다: `git diff --check`, static principle, principle self-test, evidence/CI/workflow 전용 회귀. 변경한 모든 workflow와 로컬 reusable workflow의 lint를 수행한다. self-hosted label은 명시적 lint 설정으로 검증하고 그 파일만 검사 대상에서 빼지 않는다.
3. 파서의 실제 소규모 정상/실패 대조와 전체 compile-contract recorder 실행을 수행한다. 안정화된 후보에서 full principle을 한 번 실행해 Debug/Release·sample·성능 결과가 새 파서와 연결되는지 검증한다. coverage와 각 gate의 원본 exit code를 보존한다. 변경이 없으면 비용 큰 전체 실행을 반복하지 않는다.
4. 소비자·다중 플랫폼 검증은 기존 R41/R42/R44 계약을 유지한다. 이번 수정만으로 기존 UI/VoiceOver/Swift 6.3 미확인 조건이 해소된 것으로 보고하지 않는다. 전체 배포 판정에는 canonical 정책의 현재 필수 집합을 계산해 누락을 검사한다.
5. 승인된 commit/push·PR 경로에서 최종 revision의 원격 CI를 확인한다. CI push trigger에 release branch가 없으므로 branch push만으로 검증 완료를 기대하지 않는다. 실제 PR 이벤트로 검증하고, 추가 push가 있으면 최신 head 기준으로 다시 확인한다.
6. 원격 실행 시간은 runner 대기 시간과 job 실행 시간, 전체 완료 시간, 취소된 구 실행을 구분해 수집한다. 비교 가능한 기존 run이 없으면 현재 baseline만 기록하고 개선율·절약 시간을 단정하지 않는다.
7. producer의 전체 trusted 증거 검증은 R43/R44의 token·runner·필수 증거가 충족돼야 한다. 현재 tag-only 제약을 우회하기 위해 임의 공개 tag를 만들거나 release 승인 입력을 자동으로 참으로 두지 않는다. 무배포 checkout smoke와 완전한 producer 검증을 구분한다.
8. 외부 변경이 승인돼 push했다면 먼저 remote parity와 worktree 보존을 확인한 뒤 전역 지침의 XcodeBuildMCP cleanup을 수행한다. 활성 build를 중단하지 않고 회수 용량·최종 여유 공간을 보고한다. 최종 증거는 cleanup 대상 밖에 둔다.

**인계 상태:** `계획 승인 대기` → `로컬 수정·회귀 완료` → `최신 SHA 원격 CI 확인` → `원격 필수 검사 적용 확인`. 전체 6.0.0 배포 판정은 기존 R44/R45의 별도 완료 조건을 따른다. 태그·Release·공개 설치는 이번 수정의 자동 후속 작업이 아니다.

## 9. 작업 단위와 남은 의사결정

- 논리적 변경 묶음: (1) parser + fixtures, (2) 명령/ID 정책 + 실제 회귀, (3) consumer workflow + checker, (4) ASan + 이벤트 회귀, (5) CI 집계 + 회귀/문서. 각 묶음의 검증 뒤에 다음으로 진행하고, 실제 commit은 요청 범위에 따른다.
- 프로젝트 소유자 결정: 계획 승인, 이후 push/PR/원격 실행 범위, `main` rules 적용 권한. 읽기 전용 점검과 로컬 구현 가능 여부를 외부 권한과 혼동하지 않는다.
- 실행 담당 확인: 정확한 Swift 6.3 환경, dedicated runner와 consumer read token의 실제 사용 가능성, 재사용 가능한 원격 baseline. 부족한 항목은 필요한 환경과 소유자를 기록한다.
- 상태 정정: 기존 R39의 결과 파싱·기대 ID 연결과 R43의 consumer checkout 부분은 이 계획에서 재개한다. 기존 self-test PASS만으로 재종결하지 않는다. 이전 계획의 68개 집합은 역사적 수치이며 현재 개수는 정책에서 계산한다.

### 계획 검토의 반례

다음 중 하나라도 완료 조건을 만족하는 것으로 처리되면 계획 또는 구현을 보완한다.

- 파라미터 성공을 인정하기 위해 실제 skip/실패 검사를 제거한다.
- 31이라는 수만 맞춘 다른 테스트 집합이나 필수 테스트 삭제가 통과한다.
- 정상 로그를 replay한 fixture를 실제 최종 candidate 실행으로 기록한다.
- consumer checker와 workflow가 같은 잘못된 저장소를 가리켜 함께 통과한다.
- 새 commit은 검사하지 않고 이전 ASan 결과만 남거나 일반 라벨이 진행 중 검사를 취소한다.
- 필수 job이 skipped인데 집계 check가 success이거나 required check 이름만 등록하고 실제 적용을 확인하지 않는다.
- 로컬 스크립트 PASS, checkout smoke, 원격 CI 성공을 각각 전체 배포·물별 사용성 검증 완료로 승격한다.

### 문서 상태

- [x] 직전 검토 반례와 현재 소스/정책을 연결했다.
- [x] 요구사항 → 작업 → 완료 조건 → 증거 및 권한 경계를 명시했다.
- [x] 프로젝트 소유자가 로컬 구현 진행을 승인했다.
- [ ] R46 재개: 기존 출력/779-test 회귀는 통과했으나 미완료·중복/run별 불일치와 signal/따옴표 표시명 반례를 R55/R56에서 해결한다.
- [ ] R47 재개: 31개 정책과 실제 receipt 수집 이력은 보존한다. 다른 package를 현재 후보의 PASS로 인정한 반례와 discovery identity 결합은 R53에서 해결하고 새 후보로 재수집한다.
- R48 — **물별 checkout 검증 의무는 R52로 대체.** 기존 주소 수정·접근 확인 기록은 보존하되 물별 없는 실행 경로로 전환한다.
- [x] R49 이벤트·라벨·concurrency 계약과 음성 대조군을 검증했다.
- [ ] R50 재개: 기존 결과 행렬은 통과했으나 새 job 누락·집계 생략·실패 무시 변이를 R57에서 차단해야 한다.
- [x] R51 full principle에서 Debug 711+68, Release 711+68, isolated timing, sample package, canonical sample build를 통과했다. 이후 runtime/public API를 바꾸지 않은 채 policy checker와 actionlint 설정만 보완했고 static gate·principle self-test·actionlint를 다시 통과했다.
- [ ] 최신 SHA의 실제 PR CI와 선택 ASan 실행을 확인한다.
- [ ] `main` 원격 rules에 실제 `CI Required` check를 연결한다. 2026-09-17 재조회에서는 deletion/non-fast-forward 규칙만 있고 required status check는 없었다.
- [ ] R42/R44/R45 및 R58의 Swift 6.3, 프레임워크 다중 플랫폼 runtime, 물별 없는 trusted producer 전체 증거를 완료한다. R41의 물별 UI·실제 VoiceOver는 범위 제외다.
