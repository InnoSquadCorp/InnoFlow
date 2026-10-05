# Collection reconciliation 경계 후보 I

> **2026-10-04 기능 통합 상태:** 이 문서는 보존된 성능 trial의 역사적
> 소스·가설·검증 기록이다. S/I2/D2 최적화는 채택하지 않았으며 기능 후보의
> 전체 `Sources/`는 e15dfac8e0c97edb4706ac35595f22fc2cff5c1d와 동일하다.
> 후속 A-only 3,312개 수집은 완료됐고 69개 비교 중 3개 동등·66개 미입증이다.
> 이 결과는 후보 성능 채택 증거가 아니며 자동 표본 확대를 허용하지 않는다.
> 아래의 “현재 후보”, 미실행 상태와 예정 단계는 각 기록 시점에 해당한다.
> 최신 통합 경계는 [기능·CI 통합 기록](../reviews/FUNCTIONAL-CI-INTEGRATION-2026-10-04.md)을 따른다.

2026-10-04. 기준 e15dfac8e0c97edb4706ac35595f22fc2cff5c1d의 독립 후보다. 제품 변경은 OptionalChildLifetime.swift와 ReducerComposition.swift뿐이다. Store, ProjectionObserverRegistry, diagnostics, Testing 소스는 기준과 같다. 기존 B64b2678/C8e3c402, v8 원자료와 판정은 그대로 보존한다. 이 문서는 성능 채택 증거가 아니며 새 timing을 실행하지 않았다.

## 확인한 원인

A는 `@inlinable ForEachReducer.reduce` 안에서 작성한 `first(where:)` closure를 Core의 erased reader에 전달한다. 봉인 A consumer에는 Array<Row>/CountedRows별 specialized closure가 있다. B는 같은 선형 검색을 비-inlinable `inIndexedLifetimeScope` 안으로 옮겼다. 봉인 B consumer에는 해당 specialization이 없고 Core는 generic `Sequence.first(where:)`를 호출한다. Core의 predicate 기계코드에는 associated-type/conformance witness, Identifiable.id, Equatable 호출이 남아 있다.

실제 B registry 경로의 별도 진단 hook은 sparse first/middle/last에서 direct fallback 1회, index build 0회를 기록했다. eight에서는 indexed reader 8회, index build 1회, 순회 1,000회를 기록했다. hook은 이미 실행된 분기를 세며 resolver를 다시 부르지 않는다. 따라서 단일-owner 회귀를 잘못된 index 분기 선택으로 설명할 수 없다.

공식 Swift6.4, `-O -whole-module-optimization`, 별도 모듈/cache를 사용한 외부 consumer에서 한 번의 동기 tick 동안 allocator 요청을 관찰했다. 아래는 counter 없는 plain Array의 malloc/calloc/realloc/posix_memalign 요청 합계다. setup, metadata warmup, JSON 출력은 집계 밖이다. 숫자는 bytes, RSS, live heap 또는 elapsed 시간이 아니다.

| Plain Array tick | 봉인 A | 봉인 B | I |
|---|---:|---:|---:|
| dense 1 | 4 | 5 | 4 |
| dense 32 | 35 | 75 | 44 |
| dense 128 | 131 | 269 | 142 |
| dense 512 | 515 | 1,039 | 528 |
| dense 1,000 | 1,003 | 2,016 | 1,017 |
| sparse first | 4 | 5 | 4 |
| sparse middle | 4 | 505 | 4 |
| sparse last | 4 | 1,004 | 4 |
| sparse eight | 11 | 1,024 | 11 |

별도 allocation stack probe에서 B의 반복 allocation은 generic Sequence.first → IndexingIterator/Array subscript read 경로에 연결된다. A/I의 sparse-last는 모두 4요청이고, B는 1,004요청이다. CountedRows에서도 같은 원소별 증가가 관찰되므로 counter collection만의 현상이 아니다. generic reader 경계가 추가 비용을 만드는 근거이며, 이 비용이 이전 wall 회귀의 몇 퍼센트인지 또는 I가 wall gate를 통과할지는 측정하지 않았다.

## 소스 가설과 선택 규칙

- 선형 lookup과 dense index builder를 모두 inlinable ForEachReducer 호출부의 closure로 둔다. 외부 consumer의 구체적 Collection/ID/Element에 대한 specialization을 유지한다
- owner가 없는 Store 준비 경계는 기준 그대로이며, 한 owner는 원래 erased read/first 경로를 사용한다
- 여러 owner가 있어도 해당 collection의 절반을 초과하는 distinct addressed element가 없으면 선형 read를 쓴다. 전역 owner 수는 값싼 상한 검사에만 쓰고, 실제 결정은 같은 projection prefix와 collection key path의 distinct element 수로 한다. 같은 element의 여러 slot이나 다른 scope owner를 밀도로 오인하지 않는다
- 절반 기준은 전체 index가 addressed element당 최대 2개 row를 저장하도록 제한하는 일반적인 공간 상한이다. 특정 ID, 이름, 고정 collection 크기나 관측한 시간 crossover를 사용하지 않는다. 시간상의 최적 crossover를 입증한 값도 아니다
- density가 충분할 때만 typed dictionary를 한 번 만들고 first duplicate를 보존한다. dictionary는 이미 계산한 instance identity를 저장하지 않고 현재 element 값을 저장한다. 각 owner의 slot/instance projection과 invalidation은 계속 수행한다
- cache는 각 recursive reconciliation의 지역 값이다. action 사이 또는 다른 parent owner 사이에 state/index를 보존하지 않는다. prefix/key-path isolation, 제거·교체, 재정렬, 재진입은 기존의 최종 composed state를 사용한다
- IdentifiedArray의 O(1) reader와 공개 API는 그대로 둔다. unsafe pointer, unchecked Sendable/소유권, lifetime 검사 생략을 추가하지 않는다

CountedRows의 한 tick element reads는 A의 dense 1/32/128/512/1,000에서 1/528/8,256/131,328/500,500, I에서는 1/32/128/512/1,000이다. sparse first/middle/last/eight는 A/I 모두 1/501/1,000/4,001이다. owner-free는 0회다. 이 작업량 진단을 elapsed 개선이라고 해석하지 않는다.

## 정확성 검증과 잘못된 구현 대조

공식 Swift6.4와 Swift6.3에서 각각 strict Linux adapter로 47 tests, 5 suites, 매개변수를 포함한 136 cases를 통과했다. 새 CollectionReconciliationBoundaryTests는 5 tests/26 cases다. 추가 suite는 CollectionLifetimeConsistencyTests, OptionalChildLifetimeConsistencyTests, OwnedSynchronousEffectConsistencyTests, CompletionRelayConsistencyTests다.

실제 Store/TestStore의 generic collection와 IdentifiedArray에서 다음을 확인했다: first duplicate, parent에 의한 제거·교체·재진입, 재정렬, nested/same-ID sibling와 parent isolation, 매 action 새 state, 동기 follow-up/output suppression, scheduler/raw-ID isolation, noncooperative effect의 물리적 완료. 기존 actor/lock 경계는 바꾸지 않았다.

같은 semantic oracle 3 tests/6 cases는 기준 e15와 I 모두 통과했다. 별도 adapter의 잘못된 소스는 다음처럼 실패했다. 단순 count 기대값만 깨뜨리는 대조가 아니라 owner identity와 격리 상태를 검사한다.

| 잘못된 변경 | assertion 실패 |
|---|---:|
| duplicate ID의 마지막 element로 덮어쓰기 | 6 |
| cache key에서 scope prefix 제거 | 4 |
| action/parent 사이 cache 재사용 | 16 |
| 최종 state reconciliation 생략 | 14 |

잘못된 구현을 제거한 adapter는 같은 3 tests/6 cases를 다시 통과했다. 원본 Sources 및 다른 worker의 파일은 이 대조에 사용하거나 수정하지 않았다.

## 근거 위치와 한계

재현 도구와 원자료는 VM의 `flow-recovery-20261004/evidence/collection-boundary-20261004/`에 보존한다. 주요 파일은 build_diagnostic.py, run_probes.py, LookupProbe.swift, AllocationProbe/, previous-b-hook-probe.json, 각 arm의 probe.json/probe.sil, 봉인 바이너리 disasm, array-last allocation stacks, strict64-final.log, strict63-final.log, run_controls.py, control-results.json이다. 최종 source/artifact hash와 정확한 local commit은 외부 source-freeze.json에 기록한다.

- malloc interposer는 glibc의 해당 진입점 요청 수를 센다. 모든 가능한 allocator API나 live-object 수를 측정하지 않는다. stack probe와 계수 probe는 timing용이 아니다
- I는 dense 32 등에서 A보다 index/grouping allocation이 남는다. owner 수·scope 깊이·ID hash·collection 특성에 따른 총 시간은 아직 미검증이다. single-owner allocation이 같다는 사실도 시간 동등성을 보장하지 않는다
- 복구된 Ruby 3.3.8/actionlint로 `principle-gates.sh --static`을 실행했다. action pins, job timeouts, CI efficiency, coverage workflow는 통과했고 release-evidence-policy는 새 Swift test source inventory 때문에 중단됐다. 전체 static gate PASS를 주장하지 않는다. 새 suite의 계약 inventory/원격 runtime gate 연결은 S/I 최종 통합의 정확한 선언 목록에서 재생성한다
- 엄격한 Linux adapter는 checked Sendable Mutex 경계를 사용한다. Apple 원본 os lock, SwiftUI, UI, native API/runtime, CI-only 32 Release Preflight는 이 근거로 닫히지 않는다
- 독립 safety review, 최종 source/arm 동결, 사전 방법 검토와 새 cohort admission이 남아 있다. 이전 v8 표본을 I에 재사용하거나 이전 gate/표본/판정을 바꾸지 않는다. source 가설 변경은 새 측정 전 다시 동결해야 한다
