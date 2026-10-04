# 기능·CI 전용 통합 경계

2026-10-04. 기능·CI 변경을 미채택 성능 trial과 분리한다. 이 문서는
소스 범위와 검증 계약이며 Apple 실행 또는 릴리스 준비 완료 증거가 아니다.

## 제품 소스와 보존

- 기능 기준은 `e15dfac8e0c97edb4706ac35595f22fc2cff5c1d`이며 전체
  `Sources/`를 그 기준과 byte-identical하게 유지한다. P0 동기 owned effect와
  물리적 완료, stable 5.1.1 migration, API 정리, ANSI/loader/UI CI 수정은 유지한다
- S/I2/D2 최적화와 원래 operation-count 테스트는
  `9008e338d9c2dca6c30e876b476c299000bf651b`에 변경 없이 보존한다
- 제외한 제품 변경은 Store, ProjectionObserverRegistry,
  OptionalChildLifetime, ReducerComposition, StoreDiagnostics의 후속 최적화다
- A-only 3,312개 수집은 완료됐다. 69개 비교 중 3개는 동등, 66개는 미입증이며
  동등성 구간과 분리된 비교는 0개다. 후보 timing은 0개이고 자동 표본 확대는
  하지 않는다. CPU8 steal counter 증가가 있어 host 무간섭을 주장하지 않는다
- 기존 trial 문서의 source freeze, 원자료와 판정은 각 기록 시점에 그대로
  묶인다. 기능 후보의 실행 증거로 재명명하거나 재사용하지 않는다

## 의미 회귀와 연산량 oracle의 분리

추가 25개 선언 중 23개를 원문 그대로 유지한다. 다음 두 선언은 보존된
trial의 혼합 테스트에서 의미 시나리오만 추출하고 다른 이름으로 식별한다.

| 보존된 trial 선언 | 기능 후보 선언 | trial에 보존한 연산량 oracle |
| --- | --- | --- |
| `CollectionReconciliationBoundaryTests/denseReadsCurrentCollectionOncePerAction(testing:count:)` | `CollectionReconciliationBoundaryTests/denseOwnersPreserveLifetimeAcrossActions(testing:count:)` | tick 후 `reads == count`, reverse 후 누적 `reads == count * 2` |
| `CollectionMultiScopeReconciliationTests/denseScopesKeepDistinctOwnersAcrossActions(testing:groups:)` | `CollectionMultiScopeReconciliationTests/denseDirectScopesPreserveOwnerLifetimes(testing:groups:)` | tick 후 `reads == groups * 2` |

두 기능 테스트는 원래 인자 범위, Store/TestStore 양쪽 실행, 모든 owner
기대값 및 tick·순서 변경·교체·제거·재진입 동작을 유지한다. 연산량 기준을
늘리거나 범위 비교로 완화하지 않으며 skip도 추가하지 않는다. 기준 e15의
선형 first 검색 비용을 dense index의 기능 요구로 취급하지 않는다.

arbitrary late observer의 실제 old/new State, 공개 empty dependency pack의
호출·반환값, 등록과 해제, Optional nil, 재진입, Observation 순서,
duplicate ID의 첫 요소, 동일 ID와 상대 경로의 격리, 취소를 무시하는
작업의 물리적 완료 보호를 유지한다. 나머지 sparse/singleton/duplicate-slot
테스트의 정확한 읽기 횟수 assertion도 변경하지 않는다.

`Tests/Fixtures/CollectionMultiScopeConsumer`는 기존 public API만 쓰는 독립
소비자로 보존한다. 이 fixture는 현재 자동 CI 호출 대상이 아니므로 별도
실행 기록이 필요하다. evidence에 보존된 public empty-pack 및 diagnostics
소비자도 최종 기능 소스를 대상으로 검증하며 원래 trial 증거는 보존한다.

## 인벤토리와 CI 증거 계약

SwiftSyntax로 최종 소스의 AST inventory를 다시 생성한다. 추가 선언 수는
25개이며 조건부 3개를 포함한 union 994, Swift 6.3 991, Swift 6.4 994,
full-principle 1,989가 예상된다. focused inventory는 37 suites,
Swift 6.3 344 / Swift 6.4 347 선언이다. 실제 최종 AST와 ID/hash를 대조하며
이 숫자에 맞추기 위한 threshold 변경을 하지 않는다.

didSet 3개는 compiler 6.4 및 OS27 capability 계약을 함께 유지한다.
Legacy runtime의 정확한 unavailable ID와 OS27의 실제 Passed 결과를
구별하고, 실제 compiler·simulator/host identity·원본 artifact를 receipt에
결합한다. 다른 skip, 누락·중복 ID, 잘못된 compiler/runtime, 변조된 receipt는
실패해야 한다. 기존 diagnostic 2개, runtime 8개, full-principle 5 runs 및
Release Preflight 32 checks는 유지한다.

순수 fake executor selftest는 임시 PATH에서 정확한 version-only 도구와
fixture 내부 `df -Pk` 응답만 사용한다. 다른 compile/build/disk 호출과
version 실패를 거부하고 기존 low-disk 실패 대조를 유지한다. aggregate
manifest는 헤더와 정확한 두 PASS check ID를 별도로 검사하고 누락·중복·추가
행을 모두 거부하는 대조를 실행한다. 이 fixture의
가상 도구·공간 응답은 native 실행 증거가 아니며 production의 실제 도구,
10GB 공간 요구 또는 32 checks를 변경하지 않는다.

## 검증 구분

로컬 통합은 Sources byte 동일성, 원본 trial 보존, 전체 diff, AST/source hash와
policy 정합성, tooling 양성·음성 대조를 확인한다. Swift 6.3/6.4 strict Linux
adapter의 기능 suite와 public consumer 실행은 별도 source-bound 기록으로
확인한다. 두 단계 모두 최종 소스가 바뀌면 영향을 받는 검증을 다시 수행한다.

Linux adapter는 Apple 원본 lock·SwiftUI·sample UI·실제 OS27 discovery와
result schema를 인증하지 않는다. 정확한 최종 SHA의 Apple CI와 main 전용
32-check Release Preflight가 별도 경계이며 merge/tag/release도 별도다.
