# 선택 테스트 target과 검증 범위

## 구조

제품 코드는 변경하지 않는다. 기존 테스트의 선언과 공유 fixture를 실제 의존성에 따라
옮기고, 배포 product에 포함되지 않는 네 개의 test support target으로 나눈다.
Xcode 26.6은 test target을 다른 target의 의존성으로 허용하지 않는다. 지원 모듈은
`Tests/...` 경로를 명시한 일반 target이며 실행 test target은 7개다. 제품은 지원 모듈을
의존하지 않는다. 지원 모듈은 Core의 기존 public/package API를 일반 import로 사용하고,
지원 모듈 간 helper만 package 접근으로 공유한다. 따라서 기존 일반 Release build가
제품의 testability를 요구하지 않는다. 실행 test target의 `@testable import`와
Debug/Release 및 Xcode runtime 호환성은 실제 테스트와 고정 toolchain CI에서 검증한다.

| 실행 target | Swift 6.4 선언 수 | 범위 |
|---|---:|---|
| InnoFlowCoreTests | 131 | Core 런타임, phase, observation, collection |
| InnoFlowTestingTests | 379 | TestStore, clock, ledger, consistency |
| InnoFlowSwiftUITests | 11 | 독립 binding과 presentation |
| InnoFlowSwiftUIIntegrationTests | 214 | authoring·SwiftUI·Testing 통합, preview, scope, animation |
| InnoFlowInspectorTests | 3 | Inspector graph |
| InnoFlowTests | 167 | authoring, 외부 compile 계약, script 계약, finish, baseline |
| InnoFlowMacrosTests | 89 | 기존 macro expansion 계약 |
| 합계 | 994 | Swift 6.3에서는 compiler 조건에 따라 991 |

이 표는 Swift Testing 선언 수다. 기존 XCTest reporting 계약 2개도
InnoFlowTestingTests에 보존하며 전체 및 Testing 선택 실행에서 함께 실행한다.
실제 discovery는 전체 996개, Testing 선택 762개로 이 두 XCTest ID를 포함한다.

support target은 `InnoFlowCoreTestSupport`, `InnoFlowAuthoringTestSupport`,
`InnoFlowSwiftUITestSupport`, `InnoFlowTestingTestSupport`다. 테스트 선언은 없으며
일반 SDK product build에는 들어가지 않는다. animation fixture는 SwiftUI 의존성을
유지한다. Instrumentation fixture의 module 이름이 바뀌는 assertion 문자열도 함께 맞춘다.

## 선택과 full fallback

`scripts/ci-test-targets.py`는 검증된 CI Plan과 manifest SHA, dependency contract를
사용한다. fast PR에서 단일 제품의 `Sources/<target>/*.swift`만 바뀔 때 역의존 target을
선택한다. 선택 대상은 아래와 같으며 cross-product 계약도 포함한다.

| 변경 제품 | 실행 target | 선언 수 |
|---|---|---:|
| InnoFlowInspector | InnoFlowInspectorTests | 3 |
| InnoFlowSwiftUI | InnoFlowSwiftUITests, InnoFlowSwiftUIIntegrationTests, InnoFlowTests | 392 |
| InnoFlowTesting | InnoFlowTestingTests, InnoFlowSwiftUIIntegrationTests, InnoFlowTests | 760 |

Core, facade, Macros, fixture, tests, manifest, resources, 문서 또는 여러 제품이 섞인
변경은 전체 테스트로 돌아간다. main, release-validation, merge queue, manual 실행도
전체 범위를 유지한다. 알 수 없거나 검토되지 않은 manifest는 선택하지 않는다.

선택 실행은 root `--filter`를 사용하지 않는다. SwiftParser로 root manifest의
product/target 배열을 dependency closure로 줄인 새 private package를 만들고,
실제 `swift package dump-package` graph를 확인한 뒤 테스트한다. 기존 directory를
덮어쓰지 않으며 test resource와 외부 compile/script 계약에 필요한 경로를 복사한다.
`.github`는 복사하지 않아 linter 임시 파일과 consumer copytree가 경쟁하지 않는다.
실제 compile/test 실패를 성공으로 바꾸거나 full 재실행으로 숨기지 않는다.

Debug job의 기존 macro source fallback build는 계속 전체 facade를 빌드한다.
따라서 Inspector private test package가 Core/Inspector만 컴파일해도 Debug job 전체에서
macro compilation이 사라졌다고 해석하면 안 된다. Release, coverage, sanitizer,
compatibility 및 다른 기존 필수 job의 전체 범위와 옵션은 유지한다.

`Require complete package suite for main reuse`가 실제 성공한 full 결과만 main 재사용
증거가 된다. selected 실행에서 이 step은 skip되므로 selected 결과를 전체 증거로
재사용할 수 없다. missing/skipped/failed marker를 거부하는 회귀 검사를 추가한다.

## 선언 및 릴리스 증거 계약

SwiftSyntax inventory는 실행 target 7개와 support target 4개를 모두 검증한다.
원래 994개 semantic ID와 compiler 조건을 유지하고 소스 digest를 갱신한다.
기존 runtime 347개 ID도 유지하며 suite별 module 소유권과 discovery/filter를 함께
검증한다. 분리된 module에 추가된 consistency test도 inventory에서 누락될 수 없다.

Swift 6.4의 실제 전체 Debug 실행은 7개 결과를 출력한다. full-principle의 예상
구성은 Debug 7 + Release 7 + isolated timing 1이다. 기존 Swift 6.3의 단일 실행기
계약은 유지하며 분리 후 실제 Swift 6.3 전체 실행은 정확한 head의 고정 hosted CI에서 확인한다.
기존 SwiftSyntax compatibility matrix에는 Inspector private package를 생성·실행하는
검증을 추가하여 full PR에서도 manifest 도구와 선택 경로를 두 고정 컴파일러로 확인한다.
이 단계는 Inspector 3개와 AST 도구의 검증이며 Swift 6.3 전체 991개 runtime 검증을
대신하지 않는다. 두 matrix의 새 단계 성공도 main/Dependabot 재사용 증거에 고정한다.
기존 TSAN/ASAN 필터의 동일한 53개 ID는 6/33/14개로 나뉜 3개 결과를 출력하므로
증거의 정확한 실행기 수만 1에서 3으로 맞춘다. 53개 min/max, suite/filter,
skip·failure 거부 기준을 유지하며 잘못된 실행기 수와 누락된 테스트를 거부한다.

## 로컬 검증 환경과 제한

2026-10-09 Mac에서 Xcode 27.1 (27A9275), Swift 6.4.0, arm64를 사용했다.
호스트 OS는 macOS 26.7.1이므로 전체 실행에서 OS 27 전용 3개 선언이 skip된다.
994개 선언을 포함한 결과와 실제 실행된 991개를 구분한다. 이 결과는 skip을
허용하지 않는 OS 27 release qualification receipt가 아니다. 기존 2개 known issue도
baseline과 동일하다. Swift 6.3/CI 고정 Xcode 및 OS 27 runtime/preflight는 hosted 검증이 필요하다.

로컬 결과와 동일 조건의 성능 측정은 아래에 기록한다. 전체 CI의 critical path나
hosted runner 대기시간 감소를 로컬 private test package 결과로 추정하지 않는다.

## 검증 결과

초기 draft head `48048ceec94f6af281eba00b0784b33afcc2d142`에서
전체 Debug·Release 및 세 선택 패키지 실행, 실제 discovery 집합 동등성, 20 SDK graph build,
동일 53개 TSAN/ASAN, 전체 coverage(95개 파일, 87.15%)와 기존 negative control을 확인했다.
독립 리뷰가 선언·fixture·원본 로그·graph 및 fallback/reuse 증거를 대조했다.
최종 Python 397개 회귀(이 Mac에서 Linux 전용 1개 skip), CI efficiency/release 정책과
negative control, 실제 manifest graph, swift-format 및 pinned actionlint 15개 workflow를 통과했다.

지원 모듈의 일반 target/import 보정 후 전체 Debug·Release를 다시 실행해 각각 994개
선언(실제 991개 통과, OS 27 전용 3개 skip)과 XCTest 2개를 확인했다. 기존 일반
Release build도 testability 강제 없이 통과했다. private Inspector 3개 실행,
SwiftUI·Testing의 실제 compile/discovery 및 전체 996/선택 3·392·762개의 정확한
집합 일치를 확인했다. Python 401개 회귀(Linux 전용 1개 skip), 문서 예제의 외부 target
42개와 정확한 Swift fence 113개, 정책·inventory·format 및 기존 pinned actionlint도
통과했다. 고정 Xcode 26.6/27.0 CI 결과와 OS 27 release qualification은 로컬 결과와
구분한다. compatibility 단계의 graph 검사 삭제, 일반 Release build 삭제·testability 강제,
조건부 skip 및 단계 삭제를 거부하는 negative control 5개도 추가했다.


## 동일 조건 build/discovery 측정

아래 측정은 초기 draft head `48048ceec94f6af281eba00b0784b33afcc2d142`의
구조를 대상으로 했다. 이후 고정 Xcode 호환성을 위한 support target/import 수정 후의
실행 시간으로 재사용하지 않는다.

Mac/Xcode/Swift/SDK 및 `--jobs 1 -Xswiftc -warnings-as-errors` 조건을 고정하고 직렬 실행했다.
fresh local scratch와 기존 global SwiftPM dependency/prebuilt cache를 사용했다.
`swift test --verbose list`의 compile/link/discovery 시간이며 테스트 실행과 private package 생성·복사는 포함하지 않는다.
증분은 세 패키지에서 동일한 Inspector source 파일에 주석을 추가해 컴파일을 무효화한 경우다. 일반적인 기능 변경의 link 비용을 대표한다고 주장하지 않는다.

| 패키지 | clean 중앙값(초) | 증분 중앙값(초) | 무변경 중앙값(초) |
|---|---:|---:|---:|
| baseline | 123.47 | 3.63 | 3.23 |
| split-full | 139.44 | 4.62 | 4.43 |
| selected-inspector | 35.20 | 3.12 | 2.65 |

각 종류를 3회 측정했다. 분리 후 전체 경로는 비용이 늘었으며 Inspector 선택 경로는 줄었다.
전체 CI의 필수 macro/facade build, Release/coverage/sanitizer/SDK gate, queue와 network cold-cache 비용은 이 표에 포함되지 않는다.
raw log와 명령/SHA는 task의 `stage2/benchmark`에 보관한다.

## 실제 warm 테스트 실행 (각 1회)

동일한 host/toolchain, Debug, `--jobs 1 --skip-build --no-parallel -Xswiftc -warnings-as-errors`로 직렬 실행했다.
빌드가 끝난 바이너리의 테스트 실행이며 compiler/consumer subprocess 비용은 실제 테스트 비용에 포함한다.
단일 관측값으로, 반복 측정 중앙값이나 일반적인 성능 개선으로 해석하지 않는다.

| 패키지 | 실제 시간(초) | Swift Testing 선언 | OS skip | XCTest |
|---|---:|---:|---:|---:|
| baseline | 238.36 | 994 | 3 | 2 |
| split-full | 227.03 | 994 | 3 | 2 |
| selected-inspector | 1.33 | 3 | 0 | 0 |
| selected-swiftui | 243.29 | 392 | 0 | 0 |
| selected-testing | 249.76 | 760 | 0 | 2 |

SwiftUI·Testing의 선언 수 감소가 실제 실행시간 개선으로 이어지지는 않았다.
외부 compile 계약과 통합 suite를 유지하므로 이 범위의 비용을 생략하지 않는다.
Inspector의 단일 관측 결과와 build/discovery 중앙값만 해당 측정 범위에서 비교한다.
