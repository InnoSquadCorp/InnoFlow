# W0/W9 Preflight 로컬 검증 개선

2026-10-03. 이 문서는 검증 도구 수정과 소스 기대 목록을 기록한다.
수정 후보의 Apple 실행 결과 또는 릴리스 승인서는 아니다.

> 아래 수치와 실행 상태는 `99a68db` 당시의 역사적 기록이다. 이후 `1545318`에서
> animated lifetime 회귀 선언 2개(총 6개 parameter case)를 추가하여 `0c693e2`의
> 소스 기대값은 host 955, full-principle 1,911, focused 308로 갱신했다.
> 이는 Apple 실행 결과가 아니며, 최신 정책과 inventory 파일이 현재 기대값의 기준이다.
> 이 문서 이후 Ready PR 게시와 Apple CI 검증이 시작되었으므로 마지막 절의 미게시 상태도
> 작성 당시를 나타낸다.

## 기존 main 실행: 21 PASS / 11 FAIL

대상은 [Release Preflight 37120540957](https://github.com/InnoSquadCorp/InnoFlow/actions/runs/37120540957),
main `138992674025cb6faa69d224c30580e0fce63e85`이며 현재 구현 후보와 다르다.
실패한 11개 진단 ZIP의 GitHub SHA-256 확인 후 원본 로그와 진단 JSON을 판독했다.

- 4개 27.0 simulator 검사: `enumerate-tests`가 제한 없이 host-only
  `InnoFlowMacrosTests.xctest`를 함께 발견하려다 bundle 생성 오류로 종료
- 3개 host 검사: 실제 테스트는 성공했으나 정확한 개수 정책이 오래되어 receipt 검증 실패
  - Swift 6.3: 799개, 1 run, 정책 791개
  - Swift 6.4: runtime 731 + macro 68 = 799개, 2 runs, 정책 791개
  - full-principle: 799 × 2 + timing 1 = 1,599개, 5 runs, 정책 1,583개
  - 기존 parser로 재판독한 실패 사유는 각각 maximum 초과 하나뿐
- 4개 legacy simulator 검사: iOS/tvOS 18.5, watchOS 11.5, visionOS 2.5가
  hosted Xcode 27 download catalog에서 arm64/universal 모두 제공되지 않아
  provisioning exit 70. 테스트 단계에 도달하지 못했으므로 제품 테스트 실패로 해석하지 않는다

legacy runtime의 다른 설치·실행 경로는 검증하지 않았다. 런타임 요구사항,
32개 필수 검사, runner routing, 보안 설정, exact-SHA/raw-artifact 검증은 완화하지 않았다.

## 발견 target과 focused 목록

발견 명령에 `-only-testing:InnoFlowTests`를 추가했다. 해당 target 전체를
발견하므로 새 `*ConsistencyTests` suite 누락을 계속 차단한다. 실행 명령은
검토된 suite만 선택한다. host macro 검사는 Swift 6.3/6.4 및 full-principle에
그대로 남는다.

[focused 목록](contracts/runtime-test-inventory.json)은 32 suites / 306 identifiers다.
현재 compiled Linux mirror의 발견 목록에서 CollectionLifetimeConsistencyTests
9개를 추가했다. 기존 5개 non-mirror suites는 수정되지 않은 소스와 기존 검토
목록을 유지한다. 전체 SwiftSyntax 소스 목록의 focused subset도 정확히 306개다.
8개 runtime 정책 모두 같은 목록 SHA-256에 묶인다.

mock xcodebuild 양성 fixture는 정확한 target 제한을 요구한다. 제한을 제거한
변이 fixture는 host-only bundle 오류와 status 65를 내며 실행 단계로 진행하지
못한다. 누락/다른 target, 누락·중복·변경 ID, 미검토 consistency suite, disabled
검사, 실패·skip·warning 결과는 각각 음성 fixture로 차단한다.

## 정확한 전체 개수 산출

원래 정책 목적은 정상 종료를 확인하는 데 그치지 않고 모든 Swift Testing
lifecycle과 summary/leaf/suite 개수, 필수 이름, 정확한 개수 범위를 일치시켜
부분·중복 실행을 차단하는 것이다. `RELEASING.md`의 Swift Testing evidence
계약과 `release-evidence-output-parser.rb`를 그대로 보존한다.

SwiftSyntax AST로 두 root test target의 실제 `@Test` 선언을 추출했다.
문자열 안의 fixture 선언·주석·resource 파일과 XCTest는 이 개수에서 제외하며,
parameterized test는 인수 개수가 아니라 선언 하나로 센다.

| 소스 | Runtime | Macro | Swift Testing 합계 |
| --- | ---: | ---: | ---: |
| 정책 기준 `41e92d9` | 723 | 68 | 791 |
| 원격 main `1389926` | 731 | 68 | 799 |
| 현재 로컬 후보 | 864 | 89 | 953 |

기준→main 차이는 CompiledHarnessCacheTests의 실제 추가 8개다.
main→후보는 추가 155개와 제거 1개, 순증 154개다. 제거한
`serialRejectsInvalidCapacity()`는 capacity의 UInt 전환에 따른 교체이며
`serialAcceptsMaximumCapacity()`가 추가되었다. 완전한 추가·제거 이름 목록은
[검토 이력 JSON](contracts/swift-test-inventory-review.json)에 있다.

AST의 원격 main 799 선언과 실제 로그 799 terminal 수가 일치하고, 중복 display
이름을 합친 796개 이름 집합도 서로 정확히 일치한다. 유일한 선언-level
조건부 테스트는 `CompiledHarnessCacheTests/preservesProcessIsolation()`의
`os(macOS) || os(Linux)`이며 두 host macOS gate에서 활성이다.

따라서 [전체 소스 목록](contracts/swift-test-inventory.json)에 기반한 기대값은
host 953, full-principle 953 × 2 + 1 = 1,907이다. 최소=최대 조건을 유지하고
수치만 올려 기존 로그를 통과시키지 않는다. 정책 검사는 전체 test source 및
Package.swift 해시, 파일 집합, 선언 ID 중복, 조건부 선언 검토, 목록 해시와
산출값을 함께 확인한다. 소스가 변경되면 재생성과 검토 전에는 실패한다.

`report-swift-test-inventory.sh`는 재생성용 JSON을 stdout으로만 출력한다.
정책은 자동 수정하지 않는다. 재검토 후 해당 목록과 3개 정책 pin/개수를
함께 갱신해야 한다. source expectation은 Apple discovery/실행을 대체하지 않는다.

## 별도 sample 기대값

`sample-swift-6.3`은 root953/full-principle1907과 분리한다. 원격 main의
원래 sample 44개 선언을 같은 AST 방식으로 재확인했고, 현재는 기존 44개에
새 4개가 더해진 정확히 48개다. 두 AdvancedTesting 테스트와 optional-child,
view-owned task 예제 테스트가 추가되었으며 제거는 없다.
[별도 sample 목록](contracts/sample-test-inventory.json)의 source/manifest 해시와
선언 수에서 최소=최대48을 산출했다. [추가·제거 이력](contracts/swift-test-inventory-review.json)의
sample 항목에서 네 실제 이름을 확인할 수 있다. Apple sample 실행 PASS를
뜻하지 않으며 기존 1-run/필수 suite 조건을 유지한다.

## 로컬 검증 결과

- runtime runner 양성/음성 selftest, focused result Python 10 tests: PASS
- runtime matrix orchestration selftest: PASS
- release policy selftest: PASS. count만 상향, source 변경·파일 추가,
  focused ID 누락 후 hash 재-pin, discovery target 제거/변경을 각각 거부
- AST inventory selftest: PASS. parameterized 선언 1회, 조건부 metadata,
  문자열/주석/resource/XCTest 제외, 결정성, 잘못된 Swift 구문 거부
- release output parser selftest: PASS. 추가 passing bundle/누락 bundle 및
  parameter case 개수를 선언 수로 잘못 합산하는 경우 거부
- hosted preflight 격리 fixture: PASS (`ruby -rrubygems` 사용)
- 일반 preflight 격리 selftest: Linux의 xcodebuild 부재로 BLOCKED.
  실제 릴리스 preflight `execute/resume`를 실행한 것이 아님
- shell/Ruby 구문 검사와 `git diff --check`: PASS

## 남은 검증 경계

- 현재 후보의 Swift 6.3/6.4 Apple 전체 실행, debug/release 결과, 실제 XCTest
  fallback fixture 및 8개 simulator의 정확한 발견/실행 결과는 미검증
- XCTest 위치 fixture 1개는 Swift Testing 953에 합산하지 않는다
- Linux mirror의 311 runtime + 9 macro discovery 또는 별도 macro 89 결과를
  전체 Apple 테스트 PASS로 해석하지 않는다
- 원격 재실행, push/PR/tag/release, runtime 설치, 보안 설정 변경을 하지 않았다
- 최종 SHA의 완전한 32개 PASS receipt와 원본 artifact가 있어야 릴리스 gate를 닫을 수 있다
