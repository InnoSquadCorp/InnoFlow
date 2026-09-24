# InnoFlow 6.0.0 — 최종 배포 전 실행 계획

- 문서 상태: **Draft**, 최초 2026-09-18 / 개정 2026-09-23. 작업 계획이며 구현 완료·릴리스 승인이 아니다.
- 결정권자: 프로젝트 소유자. 실행 담당: 후속 구현 담당자. 검토자·승인일: 미기록.
- 기준: `release/6.0.0-local`, HEAD `dbd6cfec40e302fc03ac9f8f35ff810d30d48014`와 기존 미커밋 변경. 시작 시 실제 상태를 다시 기록한다.
- 상위 요구사항: [구현 계획](IMPLEMENTATION_PLAN_6_0.md)의 FR-001~007, NFR-001~005. [R52~R58](FRAMEWORK_ONLY_REMEDIATION_PLAN_6_0.md)의 미충족 조건을 계승한다.
- 실행 순서: **환경 확인 → IF6-R68 → R69 → R59 → R60 → R61 → R62 → R63 → R64 → R65 → R66 → R67**. 기존 R59~R67 ID는 유지하고 신규 selector/수명 작업만 R68/R69로 추가한다.
- 목표: 잘못된 selection 결과와 검증의 허점을 수정하고, 공개 API·이전 버전 이행·문서까지 검증한 동일 후보를 배포 승인 가능한 상태로 만든다. 새 제품 기능을 계속 늘리는 작업은 아니다.
- 개정 근거: [2026-09-23 종합 검토](COMPREHENSIVE_REVIEW_6_0_2026_09_23.md)의 F1~F7, C1, M01~M24. 발견 번호는 이 보고서에 한정한다. 과거 보고서의 같은 F 번호와 혼동하지 않는다.

개정 내용: F1→신규 R68, C1→신규 R69, F2/F5→R59, F3→R60, F4→R61, F6→R62, F7→R64. R63/R65~R67의 미완료 조건은 유지한다. 이번 계획 개정은 문서 작업이며 반례 재실행·제품 코드 수정·원격 상태 갱신을 수행했다는 뜻이 아니다.

이후 사용자가 계획 실행과 D1/D2 설계 결정을 위임했다. 위 문장은 최초 계획 작성 시점의 설명이며 현재 구현·검증 상태는 [실행 로그](IMPLEMENTATION_PROGRESS_6_0_2026_09_23.md)를 따른다.

## 1. 범위와 종료 경계

물별 feature/UI/접근성/VoiceOver, checkout/token/SHA/receipt는 제외한다. 다른 제품 앱을 대신 필수 대상으로 지정하지 않는다. InnoFlow의 독립 소비자·canonical sample·Apple 플랫폼·도구 체인·품질·배포 증거는 유지한다. 원래 작업 트리와 `Derived/`, `InnoFlow.xcodeproj/`, 과거 실패/성공 원본은 보존한다.

두 승인 지점을 구분한다.

1. **A — 공개 태그 생성 전:** 최종 clean candidate의 local-preflight, 정확한 원격 후보의 PR CI, API/마이그레이션/문서 검증과 배포 경로 준비가 완료된다. 태그 전용 producer·tag API baseline·공개 설치는 아직 미완료다. 태그 생성 승인이 없으면 여기서 멈춘다.
2. **B — GitHub Release 공개 직전:** 별도로 승인된 정확한 `6.0.0` 태그에서 trusted producer와 비공개 검증 모드의 Release Gate, pre-publication 증거 검증까지 통과한다. `publish-release`는 실행하지 않고 최종 공개 승인을 기다린다.

**공개 Git 태그 자체가 SPM 소비자에게 버전을 노출한다.** B를 “아무것도 배포하지 않은 상태”라고 부르지 않는다. 태그 승인과 GitHub Release 공개 승인은 별개이며, producer의 증거 승인도 실제 공개 권한을 대신하지 않는다. 이번 계획 작성은 commit/push/PR/원격 규칙 변경/태그/공개를 실행하는 승인이 아니다.

이 계획 밖의 새 기능·편의 개선은 후속 backlog로 보낸다. 데이터/상태 정확성, 지원 플랫폼 장애, 호환성 미분류, 검증 우회, 배포 안전성처럼 현재 완료 기준을 깨는 반례만 이번 릴리스의 차단 조건으로 추가한다.

## 2. 재개해야 하는 확인된 문제

2026-09-18 반례는 2026-09-23 종합 검토에서 다시 재현했다. 아래 사실과 테스트·원격 상태의 기준일은 **9월 23일 직전 검토 시점**이며, 계획 작성 단계에서는 HEAD/working tree와 관련 문서를 다시 확인했다. 과거 실행을 새 수정본의 통과 증거로 재사용하지 않는다.

| 확인 사항 | 현재 의미 | 해결 작업 |
| --- | --- | --- |
| F1: 같은 호출 위치의 서로 다른 capture selector가 같은 handle/값을 반환 | root/scoped·dependency/memoized selection의 정확성 결함. Debug/Release 재현 | R68 → R61/R63 |
| SDK 명령에 `-version`을 넣으면 실제 빌드 없이 exit 0, 명령 검사도 허용 | 성공 종료·비어 있지 않은 로그만으로 SDK build를 입증할 수 없음 | R59 |
| runtime helper에 `--package-root /tmp/foreign-package`를 추가해도 명령 검사가 허용 | 최초 working directory 검사만으로 실행 대상 결합이 끝나지 않음 | R59 |
| 종료 이벤트가 시작보다 앞선 로그와 같은 start/terminal 쌍 반복을 parser가 인정 | run별 총수 일치만으로 실행 순서·test identity를 입증할 수 없음 | R60 |
| 필수 suite마다 1개씩, 합계 4개인 fixture가 runtime runner를 통과 | suite prefix/minimum count는 정확한 테스트 집합 증명이 아님 | R61 |
| runtime filter에 `StoreScopeSelectionTests`가 없음 | 기존 8 runtime × 53개 성공은 새 삭제 관찰 수정의 플랫폼 증거가 아님 | R61 |
| 실제 Swift 6.4 테스트 명령의 jobs/no-parallel/warnings-as-errors 인자를 exactArguments 정책이 거부 | 실제 테스트 성공과 정식 receipt 발급 가능 상태가 다름 | R59/R66 |
| F6: artifact 안의 directory symlink가 hash 목록에서 제외됨 | 링크 대상이 바뀌어도 digest가 같음. file symlink 대조는 거부 | R62 |
| F7: sample 지침의 mutable `@Observable … Sendable` 예제가 컴파일 실패 | 문서 지침 오류. actor isolation을 명시한 대조 및 GettingStarted는 성공 | R64 |
| C1: parent Store 해제 후 optionalValue는 nil이지만 관찰 callback은 없음 | 현상은 재현했으나 해제 알림 보장 계약은 미확정. 아직 확정 결함이 아님 | R69 결정 후 회귀·문서 |
| 공식 최종 receipt/manifest와 보존된 전체 runtime xcresult가 없음 | 과거 실행 횟수·coverage 수치를 새 후보의 공식 증거로 승격할 수 없음 | R62/R66 |

R53/R55 재개, R56의 실제 Swift 6.3 출력 미검증, R58 부분 완료 판정은 유지한다. R54 삭제 관찰 회귀는 이번 iOS 18.5 집중 검증에도 포함됐지만 나머지 필수 runtime과 정식 inventory는 미완료다. R52/R57의 기존 기록은 보존한다.

- 직전 검토의 Debug 713+macro 68, Release 집중 173, iOS 18.5 집중 125 통과는 기존 후보의 baseline이다. R68 이후에는 영향받는 회귀를 다시 실행한다.
- 직전 원격 관측: main `protected=false`, effective rules `[]`, repo-visible runners 0, HEAD CI run 없음. 조직 runner 전체 가용성은 확인되지 않았다. 원격 단계 시작 시 재조회한다.
- 검토 범위를 기록상 닫는 것과 배포 필수 검증을 통과하는 것은 다르다. M01~M24의 미검증 사유는 release PASS가 아니다.

## 3. 시작 전 환경 확인

- branch/HEAD/diff/untracked 목록, 적용 지침, 실행 중 build/test, 디스크 여유를 기록한다. 무관한 변경을 stage하거나 reset/stash/삭제하지 않는다.
- 정확한 Swift 6.3/6.4 실행 파일과 버전, 선택된 Xcode/SDK, 지원 simulator destination을 조사한다. Xcode 버전 이름만으로 Swift 호환성을 추정하지 않는다. Swift 6.3 설치·다른 runner 사용에 필요한 권한/비용이 있으면 별도 결정 항목으로 보고한다.
- 원격 ref/태그/branch protection/required check/trusted runner와 artifact intake 접근을 읽기 전용으로 확인한다. 최신 원격 비교가 필요하면 fetch 후 비교한다. 조사는 원격 설정 변경이나 workflow 실행을 포함하지 않는다.
- `ci.yml`은 현재 main/develop push 및 해당 브랜치 대상 PR만 실행한다. release 브랜치 push만으로 CI가 실행될 것이라고 가정하지 않는다.
- 현재 full policy ID 목록을 출력해 기준을 잡는다. 기존 local 24개/pre 3개/post 1개는 출발점이지 새 검사 추가 뒤에도 유지해야 할 고정 숫자가 아니다. 필수 검사 누락이나 중복 실행을 ID 단위로 관리한다.
- Swift 6.3 공급 경로, 필요한 8-runtime 설치 가능성, trusted runner 접근과 원격 보호 설정 승인자를 먼저 식별한다. 확보되지 않아도 독립적인 로컬 수정은 진행할 수 있지만 R66/R67 완료를 약속하지 않는다. 도구 설치·원격 설정 변경·유료 자원 사용은 필요한 승인을 별도로 받는다.

### 3.1 추가 요구사항과 미결정 사항

기존 FR-008은 물별 요구사항으로 이미 사용 중이며 이 범위에서 제외된다. 재번호 부여하지 않고 다음 두 요구사항을 **Draft 추가**한다. 구체적인 API/내부 자료구조는 아래 기술 작업에서 결정한다.

| 요구사항 | 사용자에게 보장할 결과 | 완료 기준 / 작업 |
| --- | --- | --- |
| FR-009 | 같은 소스 위치에서 생성해도 서로 다른 selection 입력/의미가 다른 handle에 섞이지 않는다. 기존 handle의 의미를 후속 select 호출이 바꾸지 않는다. | AC-R068 / R68. 값 정확성·handle 격리·의도된 재사용·해제 및 성능 회귀 |
| FR-010 | 부모 해제·collection 삭제 시 selection의 읽기/관찰/소유권 계약을 명확히 하고 코드·문서·소비자가 같은 의미를 따른다. | AC-R069 / R69. C1의 지원 여부를 결정권자가 확인한 뒤, 선택한 계약의 회귀·문서·소비자 검증 |

| 결정 | 권고안과 대안 | 결정 시점 / 소유자 |
| --- | --- | --- |
| D1: closure selection identity | 2026-09-23 결정: key-path 안정 cache를 유지하고, key 없는 closure는 호출마다 독립 handle로 둔다. 명시적 `id: String`은 동일 의미의 살아 있는 handle만 약하게 재사용하며 캡처 입력을 키에 포함하는 책임은 호출자에게 있다. | 프로젝트 소유자가 난이도보다 올바른 계약을 택하라고 위임. R68 집중 구현·회귀 통과; 최종 후보/소비자 증거는 별도 |
| D2: 부모 해제 관찰 | 2026-09-23 결정: 살아 있는 외부 projection의 liveness/optional 관찰에 MainActor 해제 무효화를 통지한다. 수명 토큰을 먼저 release하고 weak observer를 갱신한 뒤 정리한다. | 같은 위임. R69 집중 구현·회귀 통과; 전체 runtime/소비자 증거는 별도 |
| D3: toolchain/runner 공급 | 공식 서명·공증된 Swift 6.3.3을 현재 사용자 전용으로 설치하고 `TOOLCHAINS=org.swift.633202606251a`, macOS 26.5 SDK에서 엄격한 전체 784개 테스트를 통과했다. Xcode 27의 기본 Swift 6.4와 분리한다. trusted 원격 runner/보호 규칙은 별도 미해결이다. | 로컬 도구 체인 경로 검증 완료; 원격 권한 있는 관리자 확인은 R67에 유지 |

이 결정은 사용자의 구현 진행 요청과 후속 설계 위임에 따른 로컬 계약 변경이다. 최종 공개·push·tag 승인이나 누락된 Swift 6.3 증거를 대신하지 않는다.

## 4. 작업·합격 조건·증거 추적

| 순서 / 작업 | 요구사항 | 완료 기준 | 대표 증거 |
| --- | --- | --- | --- |
| 1 / IF6-R68 selection 정확성 | F1, FR-009, NFR-003/004/005 | AC-R068: root/scoped의 closure/dependency/memoized 선택이 서로 다른 capture를 격리하고, 기존 handle·cache 수명·정상 재사용 계약을 유지 | 정식 selector 회귀, Debug/Release, 독립 소비자, cache 자원 대조 |
| 2 / IF6-R69 부모 수명 관찰 계약 | C1, FR-010/007, NFR-003/004/005 | AC-R069: 지원/비지원 결정·이유가 승인되고 선택한 계약과 회귀/문서/소비자가 일치 | 결정 기록, 해제/삭제/형제/재진입 및 actor 경계 테스트 |
| 3 / IF6-R59 실행 대상·명령 계약 | F2/F5, FR-007, NFR-001/005, R53 | AC-R059: 검사 명령이 허용 후보의 실제 작업만 실행하며 Swift 명령과 정책이 일치 | argv 변이, 실제 no-build 반례, 정상 recorder→verifier |
| 4 / IF6-R60 결과 파서 완전성 | F3, FR-007, NFR-003/005, R55/R56 | AC-R060: test identity·이벤트 순서·run별 집계가 일치해야 PASS | 6.3/6.4 출력, 역순/중복/누락/parameter fixtures |
| 5 / IF6-R61 플랫폼 테스트 집합 | F4, FR-007/009/010, NFR-003/005, R54/R58 | AC-R061: 정확한 inventory와 삭제·재삽입·selection/수명 회귀가 각 필수 runtime에서 실행 | discovery/test ID 대조, 보존 xcresult, subset 음성 대조 |
| 6 / IF6-R62 증거 무결성·수집·재개 | F6, FR-007, NFR-001/005, R58 | AC-R062: directory/file/broken symlink 등 금지 artifact를 거부하고, 동일 후보의 원본/receipt만 재사용하며 실패·중단·변조를 차단 | manifest 음성 대조, recorder→verifier, plan/execute/resume/report 및 attempt 원본 |
| 7 / IF6-R63 API·5.1.1 이행 소비자 | FR-001/006/007/009/010, NFR-005 | AC-R063: 네 공개 product와 5.1.1→6.0 변경에 미분류 차이가 없음 | API inventory/diff, selection identity 변경을 포함한 consumer 비교, migration 문서 |
| 8 / IF6-R64 문서·예제 실행 검증 | F7, FR-006/007/009/010, NFR-005 | AC-R064: 지침을 포함한 코드 블록 전수 분류와 실행/실패 기대가 검증되며 무분류 누락이 없음 | 문서 manifest, 실제 snippet compile, DocC/sample 동작 |
| 9 / IF6-R65 배포 검증·공개 분리 | FR-007, NFR-005 | AC-R065: 검증 성공만으로 공개되지 않으며 pre-tag/tag/published 계약이 일관됨 | workflow 음성 대조, metadata/API lifecycle 테스트 |
| 10 / IF6-R66 최종 후보 통합 검증 | FR-001~007/009/010, NFR-001~005 | AC-R066: 고정된 최종 후보의 모든 local 필수 ID가 원본과 결합해 통과하고 적용되는 M01~M24 증거가 대응 | clean snapshot, manifest, 전체 검증 보고서 |
| 11 / IF6-R67 원격 검증·승인 인계 | FR-007, NFR-001/005 | AC-R067-A/B: 각각의 승인 경계에 필요한 원격 상태·provenance를 확인 | 정확한 SHA의 CI/규칙/producer/Release Gate와 승인 체크리스트 |

표의 AC는 최종 완료 조건이다. 개발 단계에서는 구현·직접 회귀·정상 대조가 통과하면 다음 의존 작업을 진행할 수 있으나, 최종 후보가 필요한 증거까지 확보하기 전에는 해당 AC를 완료 처리하지 않는다. 특히 R61의 inventory/runner 구현과 대표 runtime 대조를 먼저 마친 후, 전수 runtime 결과는 R62 runner가 준비된 R66에서 수집한다. 단계 진행 허용과 최종 합격을 구분해 불필요한 전수 재실행을 줄인다.

### R68 — selector cache의 의미 충돌을 수정한다

대상: `Sources/InnoFlowCore/SelectedStore.swift`, `StoreCaches.swift`, `ProjectionObserverRegistry.swift`, `Tests/InnoFlowTests/StoreScopeSelectionTests.swift`, `ProjectionObserverRegistryPerfTests.swift`, `CompileContractTests.swift`, `ARCHITECTURE_CONTRACT.md`, `CLAUDE.md`, selection/API migration 문서와 관련 게이트.

1. 검토 E05의 최소 public API 반례를 정식 테스트로 편입한다. 동일 helper 위치에서 index 0/1을 선택해 `[10,20]`→`[11,21]` 후 각각 10/20→11/21을 유지해야 한다. root/scoped, closure/dependency/variadic dependency/memoized overload를 함께 조사해 같은 원인에 수정 두 벌을 만들지 않는다.
2. D1의 대안을 비교해 cache identity와 ownership 계약을 먼저 기록한다. closure의 함수 주소·현재 반환값·소스 위치만으로 의미가 같다고 추정하지 않는다. key를 도입하면 store/scope·callsite·type·dependency/memoize 구분과 결합하고 capture를 바꾸는 입력도 identity에 포함하도록 명시한다.
3. key 없는 closure를 독립 handle로 취급하는 경우 이전 strong cache에 호출마다 영구 저장하지 않는다. 등록 해제/약한 참조 정리·캐시 메타데이터 회수를 설계한다. 재평가마다 cache를 전부 비워 기존 살아 있는 handle의 의미·관찰을 깨는 우회도 금지한다.
4. 서로 다른 key/capture, 동일한 explicit identity 재사용, 다른 Store/형제 scope, 같은 반환값에서 이후 분기, 반복 생성/해제, collection 삭제·동일 ID 재삽입을 검증한다. root/scoped에서 기존 handle을 동시에 보관한 채 후속 호출이 값을 바꾸지 않는 대조가 필수다.
5. Debug/Release 집중 회귀와 독립 Core/public macro-first 소비자를 실행한다. cache/pruning 비용은 기존 key-path/dependency 대조와 같은 workload로 측정하고 임계값을 낮추지 않는다. 이후 R61에 test ID, R63에 API/identity 호환성, R64에 사용 예제를 연결한다.

실패 시 동작: 새 identity 의미가 불명확하거나 메모리/관찰 회귀가 있으면 AC-R068을 열어 둔다. 호출자에게 임의 line/column을 넘기게 하는 임시 우회로 완료하지 않는다. 공개 전 실패는 해당 작업 묶음을 다시 수정하며 사용자 기존 변경을 reset하지 않는다.

### R69 — 부모 해제와 관찰의 지원 계약을 먼저 확정한다

대상: `SelectedStore.swift`, `ScopedStore.swift`, `Store.swift`의 isolated deinit 경계, `StoreLifetimeToken.swift`, `ProjectionObserverRegistry.swift`, scope/selection 테스트와 수명 지침. 실제 수정 파일은 D2 결정에 따른다.

1. collection 삭제, scoped parent 해제, root parent 해제를 분리하고 `isAlive`/optional accessor/strict read/SwiftUI-facing read의 기대를 표로 확정한다. C1을 검증된 구현 오류라고 미리 기재하지 않는다.
2. 해제 관찰을 보장한다면 framework가 소유한 projection 상태의 알림을 MainActor 계약 안에서 전달한다. 알림 타이밍·reentrancy·중복 invalidation을 명시하고 callback이 parent를 다시 소유하거나 전역 effect를 취소하지 않게 한다. Swift 6.3 deinit workaround는 별도 실제 검증 없이 제거하지 않는다.
3. 읽기 시점 검사만 보장하기로 결정하면 프로젝트 소유자의 근거를 남기고 parent owner를 관찰하는 실제 소비자 예제와 회귀를 제공한다. 기존 문서가 자동 해제 알림을 암시하지 않게 맞춘다. 단순히 테스트 기대를 0으로 바꿔 C1을 닫지 않는다.
4. 정상 값 변경 대조, observer 등록 후 부모 해제, 사전 해제된 부모, 형제 격리, collection 중복 삭제/재삽입, 외부 handle을 놓은 뒤 회수, 알림 중 재진입을 검증한다. 고정 sleep 대신 명시적 종료/관찰 장벽을 쓴다.
5. 결정이 없으면 이 항목은 미확정 상태로 유지하며 독립적인 R59~R65 작업은 진행할 수 있다. R63의 API 검토와 R66 최종 완료 전에 결정/증거를 닫는다. 지원 보장 확대를 선택한 경우 구현 및 해당 runtime 회귀까지 필요하다.

### R59 — 실제 실행 대상과 명령을 잠근다

대상: `scripts/release-evidence-tool.rb`, `record-release-evidence.sh`, `run-focused-platform-runtime-tests.sh`, `run-swift-toolchain-evidence.sh`, `docs/contracts/release-evidence-policy.json`, policy/recorder/toolchain self-tests.

1. SDK no-build와 foreign package-root 반례를 먼저 회귀 테스트로 고정한다. SDK 명령은 허용 action/option 구조로 검증하고 `-version`, listing/show-only 등 작업을 대체하는 옵션과 알 수 없는 인자를 거부한다. `build` 문자열 포함만으로 허용하지 않는다.
2. helper가 실제 사용하는 package/project/workspace/toolchain 인자까지 검사한다. 중복 옵션·등호/공백형·상대 경로·`..`·symlink를 정규화하고 불명확한 재지정은 거부한다. 최종 isolated checkout은 snapshot/component 검증 뒤 허용한다.
3. Swift 6.3/6.4 정식 명령에 `--jobs 1 --no-parallel -Xswiftc -warnings-as-errors`를 일치시킨다. 인자를 없애서 정책에 맞추지 않는다. SDK는 fresh 결과에서 실제 build가 수행됐다는 구조화 결과를 요구한다.
4. 정상 후보→실행→원본→receipt→verifier 양성 대조를 유지한다. 거부 명령은 PASS receipt를 만들지 않으며 stale result나 명령 실행 중 후보 변경도 거부한다.

### R60 — 테스트 결과를 이벤트/식별자 단위로 검증한다

대상: `scripts/release-evidence-output-parser.rb`, parser self-test, recorder/verifier 및 toolchain fixtures.

1. 두 Swift 도구 체인이 제공하는 machine-readable 결과의 실제 지원 여부와 schema를 확인해 안정적인 test ID를 우선 사용한다. 지원하지 않는 출력은 명시적 adapter로 처리하고 모호하면 실패한다.
2. run/suite/test 상태 전이에서 시작 전 종료, 반복 시작·종료, 미종료 leaf, 서로 다른 run의 숫자 상쇄, summary 불일치, 실패/skip/cancel/crash를 차단한다.
3. 같은 표시명을 가진 서로 다른 테스트와 parameter case는 정상 식별자가 다르면 허용한다. 단순 표시명 중복 금지로 해결하지 않는다. Unicode·따옴표·`signal 9` 같은 정상 표시명도 유지한다.
4. 실제 Swift 6.3/6.4 출력에 양성 대조를 붙인다. 환경이 없으면 fixture 통과와 실제 호환성 완료를 구분하며 R60의 해당 조건을 닫지 않는다.

### R61 — 지원 플랫폼에서 변경 기능을 직접 실행한다

대상: focused runtime runner/matrix와 각각의 self-test, 정책 inventory, `StoreScopeSelectionTests.swift`, `CollectionScopeCacheTests.swift`, 필요한 scope 회귀 테스트.

1. suite prefix/최소 개수 대신 해당 후보의 discovered test ID와 검토된 필수 inventory를 대조한다. discovery 자체가 잘못된 filter로 축소된 경우도 거부한다. 플랫폼별 조건부 테스트는 이유와 기대 집합을 명시한다.
2. 삭제 후 optional/liveness 관찰 알림, 중복 삭제, 형제 격리, 동일 ID 재삽입, R68 selector capture 격리 및 R69에서 확정한 해제 계약을 runtime 집합에 포함한다. 고정 sleep 없이 명시적 관찰/완료 장벽을 사용한다.
3. 4-test 부분집합, 이름만 같은 다른 테스트, 0-test, 누락·skip·중복·stale xcresult는 실패해야 한다. 현재 53개라는 수치를 새 정답으로 고정하지 않는다.
4. 현재 지원 행렬의 8개 runtime 조합과 5 SDK build를 유지하되 시작 시 설치·지원 여부를 재확인한다. 사용할 수 없는 필수 조합은 누락으로 남기고 최신 OS로 대체해 완료 처리하지 않는다. macOS/Catalyst 경로도 유지한다.
5. result bundle을 영속 evidence 경로에 저장하고 로그·test ID·destination/OS·warning summary를 receipt와 결합한다. 일시 경로 정리가 공식 원본을 삭제하지 않게 한다.

### R62 — 검증을 한 번에 계획·실행·재개·보고한다

대상: `scripts/release-evidence-tool.rb`와 verifier/recorder self-test, 기존 snapshot/record/verify 도구를 조합하는 새 `scripts/run-release-preflight.sh` 및 self-test, 정책/원본 보존 계약, `RELEASING.md`.

선행 소작업 R62-A: F6 artifact 무결성을 먼저 고친 뒤 R62-B 수집/재개를 구현한다.

- `lstat` 기반으로 entry 유형을 판정하고 디렉터리 순회/skip 전에 file·directory·broken symlink를 모두 거부한다. root 링크·내부/외부 대상·상대 링크·중첩/순환 링크·숨김 파일·빈 디렉터리의 허용 여부를 명시한다. 링크를 따라가 hash만 늘리는 방식은 후보 경계/원본 보존 문제를 해결하지 못하므로 채택하지 않는다.
- 정상 파일/실제 xcresult 디렉터리 양성 대조, 링크 대상 변경 전후, 파일 추가/삭제/교체, 지원하지 않는 파일형, recorder 실행 도중/검증 전 변경을 회귀로 고정한다. 실제 함수 단위 검사뿐 아니라 recorder→receipt→verifier에서 거부/정상 수용을 확인한다.
- 검사와 읽기 사이의 변경 위험은 immutable attempt staging 및 검증 전후 일치 확인 등으로 통제하고, 증명한 경계만 문서화한다. 기록 중 변경·부분 복사는 실패로 남기며 성공 receipt를 발급하지 않는다.

1. 임의 shell 실행 플랫폼을 만들지 않고 이번 릴리스 정책 ID에 대응하는 제한된 명령 catalog를 제공한다. `plan`은 ID/명령/환경/예상 원본을 출력하고 실행하지 않는다.
2. `execute`는 환경·용량·도구 체인·destination을 먼저 검사한 뒤 attempt별 경로에 실행한다. build 디렉터리/시뮬레이터를 공유하는 작업은 직렬화하거나 격리하며 다른 활성 작업을 종료하지 않는다.
3. `resume`은 candidate/policy/toolchain/environment/command identity와 원본 hash, receipt 유효성, 적용되는 최신성 조건이 모두 맞는 완료 항목만 재사용한다. 누락·변조·후보 변경·부분 성공·만료는 다시 실행하고 과거 receipt를 재표기하지 않는다.
4. 실패/중단된 attempt도 보존하고 최종 manifest에 사용할 성공 attempt를 명시한다. 동시 실행 lock, 재진입, 신호 중단, 디스크 부족, 원본 소실을 self-test한다.
5. `report`는 통과/실패/미실행/재사용과 각 단계 소요 시간·원본 경로를 구분한다. 같은 검사를 중복 실행하는 구간은 실제 증거 계약을 유지하는 경우에만 통합한다. 검사를 생략해 CI 시간을 줄이지 않는다.

### R63 — API 기준선과 실제 마이그레이션을 고정한다

대상: `scripts/check-api-compatibility.sh`, 새 API inventory/consumer fixture와 검사, `docs/API_BREAKAGE_6_0.md`, migration 문서, 정책/CI.

1. `InnoFlow`, `InnoFlowCore`, `InnoFlowSwiftUI`, `InnoFlowTesting`의 공개 API inventory를 생성한다. 선언 추가/삭제뿐 아니라 signature, generic constraint, actor/sendability, visibility 변경을 분류한다. 자동 생성 결과를 자동 승인 기준선으로 삼지 않는다.
2. 정확한 공개 `5.1.1` ref와 현재 후보를 별도 checkout/package에서 소비한다. 각 버전에 맞는 macro-first 사용 코드를 준비하고 migration 수정 목록을 남긴다. 네트워크/태그 해석 실패는 baseline 성공이 아니다.
3. 공통 지원 시나리오의 상태 전이·effect 취소/완료·scope 수명·output 의미를 비교한다. 6.0 전용 기능은 기존 버전과 억지 동등 비교하지 않고 신규 계약으로 검증한다.
4. 의도한 breaking change마다 이행 예제·회귀·문서 항목을 연결한다. 설명되지 않는 차이 또는 안정 API의 우발적 변경은 차단한다. API inventory의 소유자 검토는 별도 승인 기록으로 남긴다.

### R64 — 사용자가 복사하는 문서와 샘플까지 검증한다

대상: README/DocC/가이드의 Swift 예제, `docs/contracts/doc-parity.json`, 새 snippet manifest/compile checker, sample/consumer, 문서/CI 게이트.

1. 배포 대상 문서의 코드 블록을 전수 조사해 runnable/partial/expected-compile-failure/versioned-historical로 분류한다. 새 블록이 무분류로 생기면 실패한다. 역사적 버전 예제에는 버전과 비복사용 상태를 표시한다.
2. runnable은 실제 public import와 지원 도구 체인으로 컴파일·필요 시 실행한다. partial은 명시한 harness에서 검증하고, 실패 예제는 예상 진단을 대조한다. 넓은 제외 glob이나 이름뿐인 allowlist로 통과시키지 않는다.
3. macro-first 작성법, scope 삭제/재삽입, 취소의 협조적 한계, 출력/진단 예제가 실제 계약과 일치하게 고친다. 문서 속 API를 대신 작성한 별도 fixture만 검사하지 않는다.
4. DocC link/build, canonical sample 및 독립 소비자 검사를 수행한다. sample 화면 상호작용을 주장하는 검증은 실제 sample 실행 증거를 남기고 build 통과와 구별한다. 물별 검증은 추가하지 않는다.
5. F7의 `Examples/InnoFlowSampleApp/CLAUDE.md`도 문서 inventory에 포함한다. mutable Observable class의 Sendable 설명과 동시성 예제를 actor isolation/소유권 계약에 맞춰 수정하고, 문서에서 추출한 실제 snippet과 올바른 대조를 Swift 6.3/6.4로 컴파일한다. `@unchecked Sendable` 추가나 warnings 비활성화로 해결하지 않는다.
6. R68/R69 선택 계약을 canonical sample에서 실행한다. 같은 helper의 다른 row 선택, 상태 변경, 삭제/재삽입, 화면 이탈/복귀와 부모 수명 변경의 표시 결과를 확인한다. 실제 지원되는 sample 플랫폼/form factor를 먼저 분류하고 iPhone/iPad/Mac처럼 제공되는 경로를 검증한다. tvOS/watchOS/visionOS에 앱이 없으면 sample UI 통과로 적지 않고 독립 runtime 소비자 검증과 구분한다.

### R65 — 배포 검증과 실제 공개를 분리한다

대상: `.github/workflows/cd.yml`, `release-evidence.yml`, 관련 workflow/policy self-test, `check-release-sync.sh`, `check-api-compatibility.sh`, `STABLE_VERSION`, `RELEASING.md`.

1. `cd.yml`에 기본값 false인 명시적 공개 입력을 설계한다. `publish-release`는 승인된 공개 dispatch·정확한 태그·모든 gate 성공을 함께 요구한다. tag push나 입력 누락/false, 증거 검증만 수행한 dispatch로는 공개되지 않아야 한다.
2. 기존 producer의 exact tag SHA, trusted runner/intake, 승인·provenance·immutable artifact 검증을 유지한다. 공개 입력을 추가한다고 증거 승인을 생략하지 않는다. 검증 전용 실행에도 coverage/sanitizer/platform/prerequisite를 동일하게 적용한다.
3. pre-tag candidate metadata와 공개 stable metadata의 전환 순서를 명시한다. 현재 stable을 6.0으로 먼저 바꾸면 아직 없는 6.0 API 태그를 요구하는 순환을 해결한다. 검토된 candidate API inventory와 실제 published baseline을 구분하며 `INNOFLOW_REQUIRE_API_BASELINE=0` 같은 우회로 해결하지 않는다.
4. pre-tag/정확한 tag/태그 누락·이동/잘못된 버전/이미 공개된 버전 각각의 lifecycle 테스트를 추가한다. 최종 검증 후 metadata를 다시 고쳐 후보를 바꾸는 순서는 허용하지 않는다.
5. 공개 기본값 false, 검증 실패/누락/skipped/취소, 증거 SHA 불일치, 임의 branch, provenance 변조는 publish를 막는 음성 대조가 있어야 한다. actionlint와 기존 workflow self-test도 통과해야 한다.

선택: 이번 목표가 공개 전 정지이므로 명시적 verify-only 경로를 우선한다. protected environment 승인만으로 멈추는 방식은 원격 설정에 의존하므로 대체안이며, 적용한다면 코드 검사뿐 아니라 실제 protection 확인이 필요하다.

### R66 — 최종 후보를 고정하고 정식 로컬 증거를 수집한다

1. R68/R69 및 R59~R65의 코드·테스트·문서·정책·workflow를 함께 검토한다. 필요한 commit 권한을 확인하고 정확한 경로만 반영한다. 로컬 원본의 무관한 변경은 보존하며 최종 검증은 clean isolated checkout에서 수행한다.
2. 릴리스 노트/metadata/API 기준선/필수 ID를 먼저 확정한다. snapshot 이후 tracked 보고서나 정책을 수정하지 않는다. digest·receipt·실행 보고서는 후보 내용 밖의 evidence 저장소에 보관한다.
3. R62 runner로 전체 local-preflight를 수집한다: Debug/Release, macro source fallback·compile contract, Swift 6.3/6.4, 독립 소비자/Catalyst/sample, 5 SDK/필수 runtime, coverage, 정책이 요구하는 TSan/ASan, timing/performance 계약, DocC·정적/음성 대조, R63/R64 신규 검사.
4. focused sanitizer 53개나 과거 781개 도구 체인 성공을 전체 필수 검사의 대체로 쓰지 않는다. 실제 policy의 명령·범위와 inventory를 기준으로 수행한다. 임계값은 기존 계약을 유지하고 통과를 위해 낮추지 않는다.
5. 원본 hash·도구 체인·OS/SDK·명령·commit/content/policy digest가 같은 후보인지 최종 verifier로 확인한다. 원본이 없는 과거 결과는 참고 이력이다. 후보가 변하면 새 snapshot을 만들고 새 후보의 필수 증거를 다시 수집한다.
6. 실패 시 해당 attempt를 보존하고 고친 뒤 재검증한다. 실패한 gate를 optional로 바꾸거나 문서에서 지워 완료 처리하지 않는다. 모든 필수 local ID가 일치해야 AC-R066 완료다.
7. 종합 검토 M01~M24를 그대로 작업 추적에 사용하고 각 행에 변경 영향·필수 증거 ID·fresh/reused·미검증 이유를 갱신한다. F1~F7의 원래 반례와 정상 대조, C1 결정 기록을 함께 확인한다. 필수 local 미실행/실패가 하나라도 남으면 로컬 완료가 아니며 원격·태그·공개 gate는 다음 승인 단계로 명확히 분리한다.

### R67 — 정확한 원격 후보를 검증하고 승인 지점에서 인계한다

**A까지:**

1. 별도로 허용된 commit/push/PR 절차로 main 대상 PR CI를 실행한다. source SHA와 merge-result SHA가 다르면 둘을 구분하고 최종 tag 후보가 실제 검증된 내용인지 확인한다. merge 후 내용이 바뀌면 R66으로 돌아간다.
2. 최신 후보의 required CI 결과와 main 보호 규칙을 조회한다. 누락·stale 성공·관리자 bypass를 통과로 보지 않는다. 규칙 수정이 필요하면 권한/승인을 받아 적용하고 읽기 검증한다.
3. push를 실행한 경우 remote parity와 원래 worktree 보존을 먼저 확인한다. 이후 전역 지침의 XcodeBuildMCP cleanup을 수행하되 활성 build를 종료하지 않는다. 회수 용량·최종 디스크 여유 또는 건너뛴 이유를 기록한다.
4. A 인계표에 후보 SHA/digest, local manifest, PR/CI URL, API 검토 상태, 남은 태그 전용 gate와 공개 승인 여부를 기재한다. 태그 승인 전에는 여기서 멈춘다.

**공개 태그 생성이 별도로 승인된 경우에만 B까지:**

5. 정확한 후보에서 `6.0.0` 태그를 생성·공개하고 tag SHA를 확인한다. 다른 ref로 이동하거나 실패한 공개 태그를 강제로 재사용하지 않는다. 이후 문제는 공개를 중단하고 새 버전/복구 절차를 소유자와 결정한다.
6. 태그 전용 evidence producer를 승인된 intake로 실행한다. immutable artifact/run ID와 후보 digest·producer provenance를 확인한다. 단순 fixture 통과는 이 단계의 대체가 아니다.
7. `publish=false`인 Release Gate를 해당 tag/evidence run ID로 실행한다. 정확한 SHA의 remote-ci, tag-api-baseline, 승인·provenance를 포함해 pre-publication 전체 검증을 확인한다. tag push 당시 evidence run ID 부재로 난 실패와 후속 검증 성공을 구분해 기록한다.
8. B 인계표에는 공개 태그 노출 사실, 성공한 검증 run, artifact 보존 기간/위치, 공개되지 않은 GitHub Release 상태, 실행할 공개 절차를 명시한다. 최종 공개 승인이 없으면 `publish-release`를 실행하지 않는다.

GitHub Release 공개와 그 뒤 `public-package-install` 등 post-publication 검사는 이번 실행 계획의 완료로 대신하지 않는다. 최종 공개를 승인받은 다음 수행할 별도 절차로 남기며 사전에 PASS로 기록하지 않는다.

## 5. 실행 체크리스트와 보고 규칙

- [ ] 환경 확인: 실제 Swift 6.3/6.4·runtime·디스크·작업 격리·trusted runner/보호 설정 담당자 식별.
- [ ] R68 selector 의미 격리·안전한 cache/등록 수명·Debug/Release 및 소비자 회귀.
- [ ] R69 부모 해제 관찰 계약 결정과 선택한 의미의 코드/회귀/문서 일치.
- [ ] R59 실제 실행 대상·명령 계약 및 SDK no-build 차단.
- [ ] R60 이벤트 순서·고유 식별자·도구 체인별 결과 검증.
- [ ] R61 정확한 플랫폼 inventory와 삭제 관찰 직접 회귀.
- [ ] R62-A directory/file/broken symlink 및 변조 거부, 정상 artifact 통합 대조.
- [ ] R62-B 원본 보존형 evidence runner와 안전한 재개.
- [ ] R63 네 product API 검토 및 5.1.1 migration consumer.
- [ ] R64 문서 코드 블록 inventory/컴파일과 DocC/sample.
- [ ] R65 검증 전용 CD와 metadata/API/태그 lifecycle 정합성.
- [ ] R66 clean 최종 후보의 모든 local-preflight 증거.
- [ ] R67-A 정확한 후보의 원격 CI·규칙 확인, 공개 태그 전 인계.
- [ ] R67-B 별도 태그 승인 후 producer/pre-publication PASS, GitHub Release 직전 인계.

각 단계는 `구현 → 직접 반례 및 정상 대조 → 관련 게이트 → 문서/상태 갱신`으로 닫는다. 구현 묶음/commit 경계도 위 순서를 따른다. 빠른 회귀를 먼저 돌리고 전체 비용이 큰 행렬은 R66에서 고정 후보에 수집한다. 시간 단축을 위해 필수 runtime·원본 보존·실패 검사를 생략하지 않는다.

### 검증 비용과 재작업을 줄이는 실행 규칙

- 개발 중에는 바뀐 경로의 정식 회귀·음성/양성 대조·static gate를 먼저 실행하고, source fallback/독립 consumer/전체 sanitizer·runtime는 필요한 통합 시점과 R66에 배치한다. 빠른 검사 통과는 최종 검증 완료가 아니다.
- build 산출물 cache와 테스트 결과 재사용을 구분한다. toolchain/SDK/의존성/설정이 맞는 build cache는 활용할 수 있지만 receipt 재사용은 R62의 엄격한 동일 후보 조건을 만족해야 한다.
- 같은 SwiftPM build directory, DerivedData, simulator를 공유하는 무거운 작업은 동시에 실행하지 않는다. 다른 작업의 프로세스를 종료해 공간/lock을 확보하지 않는다.
- 검토 E01의 713+68, E02의 173, E03의 125를 새 고정 정답으로 복사하지 않는다. 새 테스트와 조건부 지원 범위를 반영한 approved inventory가 기준이다.
- 단계별 소요 시간을 기록하고 중복 build/test 원인을 분리한다. CI 단축 목표는 같은 필수 test ID·실패 차단·원본 보존을 유지한 재사용이며 coverage/sanitizer/플랫폼 삭제가 아니다.

### 계획 자체의 반례 점검과 완료 지표

| 이 계획을 형식적으로 만족해도 남을 수 있는 잘못된 구현 | 차단 조건 |
| --- | --- |
| 새 select 값은 맞지만 이전 handle의 resolver를 덮어씀 | AC-R068: 기존/신규 handle 동시 보관 후 독립 갱신 |
| selection 충돌은 없지만 매 호출마다 strong cache가 계속 늘어남 | AC-R068 + NFR-004: 반복 생성/해제·registry/cache 회수와 자원 대조 |
| 순서만 맞춘 가짜 로그나 4개 subset으로 PASS | AC-R059/060/061: 실제 target/action·test identity·정확한 inventory 모두 일치 |
| directory symlink를 거부하지만 recorder 이후 원본을 교체해 재사용 | AC-R062: immutable attempt·재검증·원본/receipt/후보 결합 및 변이 통합 대조 |
| 문서와 다른 수제 fixture만 컴파일해 F7 누락 | AC-R064: 실제 코드 블록 추출·미분류 0·지원 toolchain별 실행 |
| 부모 수명 계약을 문서에서 조용히 축소 | AC-R069: D2 소유자 결정·근거·소비자 기대 확인 필수 |
| 24개 행에 미검증 사유만 쓴 뒤 release-ready 선언 | AC-R066/067: 기록 종료와 필수 gate 통과를 구별하고 승인 단계별 미충족 ID 명시 |

SC-PRE-01: F1~F7 각각 수정 전 반례와 수정 후 기대 결과·정상 대조가 연결되고 미연결 발견 0건. SC-PRE-02: C1의 미결정 의미 0건(해결 방식/승인 포함). SC-PRE-03: M01~M24 누락 0행, 해당 승인 단계의 필수 실패/미실행 0개. SC-PRE-04: 최종 candidate/policy/command/environment identity가 다른 증거의 혼합 0건. SC-PRE-05: 검증 전용·실패·취소·누락 조건에서 공개 부작용 0건. 수치만 맞추기 위해 테스트 또는 요구사항을 제거하지 않는다.

## 6. 선택적 개선 — 필수 릴리스 작업과 분리

| 항목 | 제안 작업 / 적용 조건 | 6.0 필수와의 경계 |
| --- | --- | --- |
| OPT-01 장기 자원 계측 | queue high-water·cache/observer 수·active effect·dropped output의 반복 workload 보고서. 기존 계측으로 가능한지 먼저 확인하고 공개 API 추가는 별도 검토 | R68의 누수/무한 보관 방지는 필수. 운영 dashboard나 새 DevTools는 선택 |
| OPT-02 업무형 backpressure/취소 복구 예제 | canonical sample에서 bounded 입력, 협조적 취소, 재시도 시 domain state 복구를 설명 | R64의 기본 정확성 검증은 필수. 새 저장소/네트워크/영속 복원 엔진 도입은 비목표 |
| OPT-03 selection 진단 가이드 | identity 선택 기준, stale handle 재생성, 부모 소유권 설명과 사용 사례 | F1 및 승인된 C1 계약을 설명하는 최소 migration 문서는 필수. 추가 튜토리얼은 선택 |

선택 항목은 필수 차단 조건을 닫은 뒤 별도 범위로 결정한다. 예정 버전·일정을 임의로 확정하지 않는다. 새 확정 결함이 나오면 기존 root cause/행렬에 연결해 재개하고, 단순 편의 기능은 릴리스 목표를 계속 늘리는 이유로 삼지 않는다.

완료 보고는 구현 상태, local 증거 상태, remote 상태, A/B 승인 경계, 미충족 ID와 이유를 따로 표시한다. 외부 환경·권한 때문에 멈춘 단계는 BLOCKED이며 다른 단계의 PASS로 상쇄하지 않는다. 모든 기능에 예외가 전혀 없다고 보장하는 대신, 명시된 계약·반례·지원 행렬과 남은 검증 경계를 보고한다.
