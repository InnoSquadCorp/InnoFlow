# Collection 다중 scope 그룹화 보완

> **2026-10-04 기능 통합 상태:** 이 문서는 보존된 성능 trial의 역사적
> 소스·가설·검증 기록이다. S/I2/D2 최적화는 채택하지 않았으며 기능 후보의
> 전체 `Sources/`는 e15dfac8e0c97edb4706ac35595f22fc2cff5c1d와 동일하다.
> 후속 A-only 3,312개 수집은 완료됐고 69개 비교 중 3개 동등·66개 미입증이다.
> 이 결과는 후보 성능 채택 증거가 아니며 자동 표본 확대를 허용하지 않는다.
> 아래의 “현재 후보”, 미실행 상태와 예정 단계는 각 기록 시점에 해당한다.
> 최신 통합 경계는 [기능·CI 통합 기록](../reviews/FUNCTIONAL-CI-INTEGRATION-2026-10-04.md)을 따른다.

2026-10-04. 기존 후보 19285f4b759d9ebfa93e739c727a6c7535c65977 위의 별도 후속 변경이다. 기존 I worktree, source-freeze 및 기록된 evidence hash가 그대로임을 대조했다. 이 후속 후보의 제품 변경은 OptionalChildLifetime.swift 한 파일이다. ReducerComposition과 다른 Sources는 I와 동일하다. State snapshot, diagnostics, Testing 변경을 섞지 않는다.

## 재현과 원인

I는 처음 만나는 collection Key마다 `owners()`로 전체 owner path 배열을 다시 만들고 전부 검색했다. G개 collection scope에 M명의 owner가 있으면 그룹화가 G×M으로 증가한다. root에 여러 owner가 있으므로 단일-owner 빠른 경로로는 이를 막을 수 없다. collection에 row가 하나뿐인 경우에도 불필요한 그룹화가 있었다.

실제 Store에 `Scope(state: \Root.groups[index], ...)`를 설치하고 각 group의 ForEachReducer/OptionalChildLifetime을 구성했다. outer ForEach를 사용하지 않아 기준 A의 outer linear scan과 혼동하지 않는다. 진단 hook은 실제 owner-array materialization, grouping pass, 방문한 owner path, 수행한 projection step만 기록한다. resolver를 다시 실행하지 않는다.

| 그룹 수 | 그룹당 row | A 그룹화 방문 | I 그룹화 방문 | 후속 후보 방문 | 후속 materialization |
|---:|---:|---:|---:|---:|---:|
| 1 | 2 | 0 | 2 | 2 | 1 |
| 8 | 2 | 0 | 128 | 32 | 1 |
| 32 | 2 | 0 | 2,048 | 128 | 1 |
| 128 | 2 | 0 | 32,768 | 512 | 1 |
| 1 | 1 | 0 | 0 | 0 | 0 |
| 8 | 1 | 0 | 64 | 0 | 0 |
| 32 | 1 | 0 | 1,024 | 0 | 0 |
| 128 | 1 | 0 | 16,384 | 0 | 0 |

세 구현의 projection step은 모두 실제 owner당 2회이고 최종 state/tick oracle이 같다. 후속 후보의 grouping은 첫 collection만 있으면 1pass, 여러 distinct collection이 있으면 최대 2pass다. 위 진단에서는 최대 2M owner-path 방문으로 제한된다. I를 같은 bound에 대조하면 6개 조건에서 실패하고, A와 후속 후보는 통과한다. 이는 연산 횟수 검증이며 시간 비교가 아니다.

## 좁은 변경

- owner 수가 적거나 전체 collection 대비 sparse인 기존 빠른 조건을 유지한다. collectionCount≤1도 grouping/index 없이 direct reader를 쓴다
- 첫 eligible Key는 I의 기존 distinct-element scan을 유지한다. 그때 만든 owner-path 배열은 action-local cache에 metadata로 보관한다
- 두 번째 distinct Key miss에서 이 배열을 한 번만 전체 grouping하고, 이후에는 prefix/key-path별 distinct element count를 조회한다. 같은 Key의 반복 조회는 기존 collection entry를 사용한다
- full grouping은 collection projection만 세며, 여러 slot이 같은 element를 주소 지정하면 Set으로 한 번만 센다. 그룹 밀도에 다른 scope나 중복 slot 수를 섞지 않는다
- 첫 key scan과 추가 full grouping 외에 owner 전체를 반복 순회하지 않는다. 긴 nested path에서는 projection 열거와 prefix 구성·해시 비용이 남는다. 모든 경우에 경로 길이와 무관한 O(M)이라고 주장하지 않는다
- cache는 여전히 recursive reconciliation의 지역 값이다. 다른 parent owner나 다음 action에 element 값, group count, owner paths를 남기지 않는다. first duplicate, slot identity 재검증, invalidation, 물리적 task 완료 경계는 그대로다

단일 collection은 전체 grouping dictionary를 만들지 않는다. 기존 I의 비타이밍 진단 19개와 후속 후보를 비교해 element read 수와 allocator 요청 수가 모두 정확히 같았다. dense 1/32/128/512/1,000, owner-free, sparse first/middle/last/eight 및 plain Array 대조를 포함한다. 이 일치는 시간 동등성이나 peak-memory 동등성의 증거가 아니다.

## 검증

공식 Swift6.4와 Swift6.3의 엄격한 Linux adapter에서 각각 51 tests, 6 suites, 156 cases를 통과했다. 기존 47 tests/136 cases에 새 4 tests/20 cases를 더했다. 실제 Store/TestStore로 다음을 확인했다.

- 직접 indexed Scope 1/8/32/128개와 동일 ID row의 격리
- dense/singleton group의 제거, 교체, 순서 변경, 재진입과 매 action 새 state
- 한 element의 두 optional slot을 서로 다른 addressed element로 오인하지 않음
- 한 dense scope를 제거해도 다른 scope의 task와 action은 살아 있고, 취소된 noncooperative task는 실제로 반환할 때까지 미완료 상태를 유지함
- 기존 first duplicate, nested parent/scope, IdentifiedArray, scheduler ID isolation, synchronous follow-up/output 및 completion 계약

동일한 semantic/density 대조 6 tests/24 cases에서 이전 I와 후속 후보는 통과했다. 별도 adapter의 잘못된 구현은 다음과 같이 실패했다.

| 잘못된 변경 | assertion 실패 |
|---|---:|
| element cache key의 scope prefix 혼용 | 40 |
| full grouping에서 distinct element 대신 slot 수 사용 | 2 |
| action/recursive parent 사이 cache 재사용 | 42 |
| duplicate ID를 마지막 값으로 덮어쓰기 | 6 |

잘못된 구현을 제거한 adapter는 같은 대조를 통과했다. slot-count 대조의 두 실패는 밀도/작업량 oracle이며, 이를 lifetime 손상이라고 부르지 않는다. 원래 I의 G×M 비용은 별도의 실제 hook 작업량 대조에서 검출했다.

검증 종료 후 Sources를 수정하지 않았다. 현재 Sources와 strict adapter receipt, release Core와 test Core mirror, 현재 여섯 test source와 실행된 mirror를 해시/내용으로 대조해 모두 같음을 확인했다. 기존 I의 source-freeze가 기록한 source/evidence도 모두 일치한다.

## 공개 consumer와 미완료 경계

`Tests/Fixtures/CollectionMultiScopeConsumer`는 public API만 사용하며 clock·registry hook을 포함하지 않는다. makeGroupsStore로 설치를, tickGroups로 반복 action을 분리했다. 독립 package identity의 Swift6.4 consumer와 strict adapter를 의존하는 Swift6.3 SwiftPM consumer에서 같은 8개 oracle을 통과했다. public fixture에는 변경하지 않는 local `var result` 한 곳의 compiler warning이 남아 있다. 검증한 입력을 보존하기 위해 이후 수정하지 않았다.

128 direct groups × 2 rows를 추가 timing scenario 후보로 준비했다. 실제 시나리오 값, arm, 표본 수, timing 경계와 admission은 후속 독립 방법 검토에서 정해야 한다. 새 timing을 실행하지 않았고 기존 표본·판정·기준을 바꾸지 않았다.

Concurrency safety gate는 통과했다. 전체 static gate는 새 test source inventory에서 멈췄으며, 최종 통합의 실제 선언 목록으로 inventory를 갱신해야 한다. Apple 원본 lock·SwiftUI·native runtime, CI-only 32 Release Preflight, 새 성능 gate와 독립 safety review는 아직 완료되지 않았다. 여러 작은 scope의 상수 비용은 남을 수 있으며, 이번 작업량 감소를 wall/CPU 개선으로 주장하지 않는다.

## 재현 자료

VM의 `flow-recovery-20261004/evidence/collection-multiscope-20261004/`에 다음을 보존한다.

- MultiScopeConsumer.swift, build_core_probe.py, 각 hook arm의 변환 소스와 compile commands/probe.json
- verify_work.py와 work-verdict.json
- single-collection-command.json, single-collection-probe.json, single-collection-verdict.json
- strict64.log, strict63.log, strict-candidate-source-receipt.json
- run_controls.py, control-results.json, 각 control log와 정확한 source hashes
- public consumer compile command/build log와 두 toolchain의 출력
- preservation-and-source-verification.json, 후속 source-freeze.json, 작은 bundle 및 bundle receipt

기존 cache/build 디렉터리를 재사용했고 봉인 성능 자료나 다른 worker의 파일을 삭제하지 않았다. 모델 용량 오류 후에는 완료된 결과와 해시만 검산하고 새로운 build·측정을 시작하지 않았다. 그 전에 시작한 public consumer 실행의 완료 결과만 수거했다.
