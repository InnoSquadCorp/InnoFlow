# Core 성능 후속 분리 계획

> Historical snapshot: claims, dates, SHAs, counts and pending steps below apply
> only to the recorded revision. Published 6.0.2 and current release rules are
> described in the [documentation index](../DOCUMENTATION.md). This record is not
> current publication status or evidence that a later revision passed.

> **2026-10-04 기능 통합 상태:** 이 문서는 보존된 성능 trial의 역사적
> 소스·가설·검증 기록이다. S/I2/D2 최적화는 채택하지 않았으며 기능 후보의
> 전체 `Sources/`는 e15dfac8e0c97edb4706ac35595f22fc2cff5c1d와 동일하다.
> 후속 A-only 3,312개 수집은 완료됐고 69개 비교 중 3개 동등·66개 미입증이다.
> 이 결과는 후보 성능 채택 증거가 아니며 자동 표본 확대를 허용하지 않는다.
> 아래의 “현재 후보”, 미실행 상태와 예정 단계는 각 기록 시점에 해당한다.
> 최신 통합 경계는 [기능·CI 통합 기록](../reviews/FUNCTIONAL-CI-INTEGRATION-2026-10-04.md)을 따른다.

2026-10-04. 사용자 승인: 추가 리뷰의 계획 수립, 수정과 검증, 전체 묶음 완료 후 기존 PR53 반영. 이 문서는 새 소스 가설을 고정하며 새 측정 실행을 승인하는 문서는 아니다.

## 기준과 보존

- 현재 Ready 수정본은 e15dfac8e0c97edb4706ac35595f22fc2cff5c1d다. 제품 Sources는 이전 비교 기준 A인 3743a3f와 동일하다. P0 동기 계약, stable migration, 공개 API 정리 및 CI 수정은 유지한다
- Core 후보 64b2678과 Testing 후보 8e3c402는 채택하지 않는다. 전체 v8의 4,864개 표본은 유효하며, 큰 개선과 함께 실제 회귀도 확인됐다. 원자료·실행파일·소스·분석·독립 영수증을 동결해 보존한다
- Core의 8개 비회귀 실패 중 7개는 95% 구간 하한도 +5%를 넘는다. owner-free dispatch, 작은 owner 집합, sparse collection 및 동기 action 체인에 추가 비용이 있다. 동일 바이너리 대조 4개 실패와 이를 혼동하지 않는다
- Testing token은 최소 5% 개선에 미달했으므로 후속 후보에서 제외한다. 원자료가 없는 기존 “TestStore 2.2배” 수치는 재현·반박했다고 주장하지 않는다
- 기존 표본을 새 후보에 재사용하거나 통과할 때까지 같은 비교를 반복하지 않는다. 기준 완화와 유리한 결과만의 사후 채택을 하지 않는다

## 1. 원인 분리

세 부분을 별도 소스로 평가한다. 기능·연산 횟수·소유권·SIL/기계코드·allocation 진단은 시간 개선 증거와 구별한다.

### S: 관찰자가 없는 State snapshot

기준의 Store와 ProjectionObserverRegistry 두 파일만 대상으로 한다. collection lookup, diagnostics, Testing는 기준 그대로 둔다.

이전 후보는 reducer closure 안에서 generic Optional State를 갱신해 밖으로 전달했다. 봉인된 기계코드에서는 관련 closure의 간접 호출 지점이 증가했지만 직접 heap allocation은 확인되지 않았다. 먼저 값 전달·소유권·generic witness 호출을 좁혀 조사한다. heap 복사나 allocation을 원인으로 단정하지 않는다.

정확성은 기존/신규/해제된 관찰자, willSet 중 등록, root Observation callback 순서, selected/scoped 값, animated path, Optional State nil, 재진입을 실제 관찰값으로 대조한다. 새 등록의 값 갱신을 빠뜨리지 않아야 하며, 특정 snapshot 구현을 강제하는 테스트로 구현을 흉내 내지 않는다. lifetime preparation·취소·물리적 완료를 생략하지 않는다. unsafe pointer 또는 unchecked 소유권 우회는 사용하지 않는다.

### I: collection 수명 lookup

기준의 OptionalChildLifetime과 ReducerComposition을 대상으로 한다. State snapshot, diagnostics, Testing는 기준 그대로 둔다.

기존 읽기 횟수 감소에도 sparse elapsed 시간이 3.39~3.73배가 된 원인을 조사한다. 기존 single-owner fallback이 실제 선택되는지, erased/generic reader 경계와 인덱스 구축·조회 비용이 무엇인지 구분한다. 필요한 경우 실제 registry 경로에서 비타이밍 관측 hook으로 확인하고 resolver를 재실행해 상태를 바꾸지 않는다.

owner가 없거나 적을 때 불필요한 인덱스 작업을 하지 않는 일반적인 선택 규칙을 검토한다. 특정 측정 ID·컬렉션 크기·시나리오 이름을 위한 특례는 금지한다. first duplicate semantics, 제거·교체·재진입, 동일 ID 형제/부모 격리, 중첩 scope, action별 새 snapshot, 물리적 완료를 재현과 잘못된 구현 대조로 확인한다. 인덱스는 action 사이에 오래된 상태를 보존하지 않는다.

### D: diagnostics 문자열

이전 문자열 사전 계산은 독립된 세 번째 변경으로 보존하되 지금 S/I에 섞지 않는다. 기존 정확한 lexical ordering·activeLimit·값 검증을 유지한다. 채택하려면 최종 후보의 사전 정의된 비교를 통과해야 한다.

## 2. 작은 후보와 코드 검토

1. 별도 worktree에서 S와 I의 원인 증거를 먼저 기록한다
2. 좁은 소스 후보와 전후 정확성·대조를 만들고 독립 안전성 검토를 받는다
3. 실패한 이전 묶음에서 유리한 부분만 사후 선택하지 않는다. 최종 후보의 정확한 source SHA, Sources map 및 포함한 변경을 다시 고정한다
4. Swift 6.3/6.4 및 엄격한 Linux adapter에서 해당 계약을 재검증한다. Apple의 원본 lock·SwiftUI·UI·공개 API 검증은 원격 CI로 따로 닫는다

## 3. 다음 측정의 admission

- 새 소스 가설과 비용 귀속에 맞는 arm 구성은 구현·검토 후, 새 효과를 보기 전에 독립 방법 검토로 고정한다
- 기존 19개 사용 시나리오 및 sparse/owner-free/관찰자 있음/없음 대조를 유지한다. 변경과 무관한 시나리오를 빠뜨려 회귀를 숨기지 않는다
- 최소 개선 5%, 비회귀 상한 5%, 동일 바이너리 대조 허용 구간 [1/1.02, 1.02]를 완화하지 않는다. pointwise/동시 보장과 CPU/wall을 구분한다
- 필요한 표본 수는 새 효과를 관측하기 전에 고정한다. 기존 A/A 변동은 정밀도 설계에만 사용하고, 원래 v8 결론을 바꾸거나 표본을 합치지 않는다. 계산 방법·최대 실행 예산·중단 규칙을 함께 기록한다
- 실제 compiler/linker invocation, transitive module flags, enable-testing 여부, toolchain/runtime 및 binary hash를 대칭으로 확인한다. 검증 build와 측정 artifact를 분리한다
- startup 영수증은 타이머 밖에서 실제 실행 이미지와 연결한다. 같은 고정 cohort를 완료한 뒤 raw-first 검산과 독립 통계 재계산으로 판단한다
- DI/Router와 실제 quiet 구간을 합의하며 고정 checkpoint의 원자료와 작은 manifest를 복구 보관한다

## 4. 종료와 PR

정확성과 새로운 사전 gate를 모두 통과한 소스만 로컬 단계 commit으로 통합한다. 미해결 성능은 미완료로 명시한다. P0·API·migration·CI의 완료 상태와 구별하고, 추가 묶음이 모두 닫히기 전 PR53에 일부를 게시하지 않는다. main 전용 32 Release Preflight 및 merge/tag/release는 별도 권한과 증거가 필요하다.

## 5. 13:40 UTC 정확성 검토 이후의 범위

새 시간 표본은 아직 수집하지 않았다. 원래 후보와 새 후보의 변경 목적을 혼동하지 않는다.

- S의 최초 `329c9e2` 후보는 공개 empty-pack `select` 및 package registration의 late-registration 동작을 바꾸어 차단했다. 기존 증거와 소스를 보존하고 채택하지 않는다
- 새 S `f988d7c40e48f9545674e25e98d95ea4847f8c10`는 reducer 전 previousState를 그대로 보존한다. mutation과 didSet 이후 실제 registry가 비었을 때만 현재 State 전달과 빈 refresh 호출을 생략한다. 기존 호출 횟수·반환값·late dependency 재현을 독립 검토에서 복구했다
- arbitrary late dependency 등록을 허용하는 기존 계약에서는 preimage를 일반적으로 버릴 수 없다. 초기 State 0과 1이 같은 최종 0이 된 뒤 동일한 `old != new` dependency를 등록해도 기존 동작은 refresh 0회와 1회를 구별해야 한다. package 접근이라는 이유로 이 차이를 무시하지 않으며, 공개 empty-pack 사례도 별도로 보존한다
- 새 S의 네 Array COW 대조는 모두 10회 복사를 유지했다. 따라서 원래 pre-mutation 큰 State COW 개선 목표는 미해결이다. 이 작은 후단 guard의 성공을 원래 COW 목표 성공으로 바꾸지 않는다
- I `19285f4b759d9ebfa93e739c727a6c7535c65977`는 sparse 경로의 원래 typed scan을 보존하고, 같은 scope의 distinct owner가 collection 절반보다 많을 때만 typed index를 사용한다. S+I의 독립 정확성 검증은 Swift 6.3 73개, 6.4 76개를 통과했다. 시간 개선 증거는 아니다

새 최종 후보의 잠정 최소효과 대상은 dense collection과 diagnostics 문자열 중복 계산이며, 큰 State 시나리오는 원래 미해결 목표와 비회귀 대조로 남긴다. 이 범위 변경은 기존 B의 채택 실패를 바꾸지 않는다. D 소스·최종 결합 소스·실제 build를 고정한 뒤 별도 방법 검토에서 확정해야 한다. 결합 후보를 세 arm으로 측정하면 주장 가능한 것은 결합 패키지의 workload 효과이며, S/I/D 각각의 시간 효과가 아니다.

## 6. A/A 원인 검토와 새 관측기

v8의 `SWIFT_DETERMINISTIC_HASHING=1`은 실제 기록에서 확인됐다. 기본 무작위 hash seed가 원인이라는 설명은 지지되지 않는다. A와 A-prime은 같은 실행파일을 사용했지만 Consumer가 읽는 startup JSON에 각각 길이가 다른 scientific role이 들어갔다. 이 불필요한 입력 차이는 확인됐으며, 기존 A/A 차이의 원인이라는 인과 결론은 아직 없다. CPU/wall 움직임과 균형 잡힌 순서만으로 cache/layout/host 요인을 분리할 수 없다.

새 관측기는 별도 디렉터리와 버전으로 만들고, scientific role은 부모 schedule/nonce/artifact map에만 둔다. child는 role 없는 고정 schema·경로를 사용하되 실제 executable SHA, PID/PPID/start ticks, argv, affinity, boot/namespace, nonce, exclusive atomic receipt 검증을 유지한다. 완전한 실제 환경과 직렬화 bytes/길이를 기록한다. 필수 OS identity 차이는 공개하고 byte-identical 입력이라고 주장하지 않는다.

선택 가능한 다음 단계는 고정 A-only 진단 한 번이다: 21개 시나리오, 같은 baseline 실행파일의 세 역할, 48 rounds, 3,024 processes, 24/48 checkpoints, 전체 단계 45분 상한. 실제 입력·build·observer 검토 전에는 실행하지 않는다. 기술 검증과 통계적 동등성은 구분한다. 모든 63개 A/A 비교를 한 번 공개하며 넓은 구간은 NOT_ESTABLISHED다. 원본 기준 2%를 충족하지 못했다고 capture 실패나 원인 발견으로 바꾸지 않는다. 표본 추가·재실행·중간 효과 열람·표본 선택·역할 편향 보정은 금지한다.

진단이 기술적으로 유효해도 최종 384 rounds 실행을 자동 허용하지 않는다. 실제 후보·입력과 결과의 해석 가능성, 고정 표본·중단·비용 기준을 별도로 검토한다. 구간이 2% 허용 범위와 완전히 분리되면 단순 표본 증가만으로 해소됐다고 가정하지 않는다. 새 효과를 보기 전에 기준과 예산을 동결하며, 진단 표본을 최종 후보 추론에 합치지 않는다.
