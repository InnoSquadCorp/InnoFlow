# Diagnostics 문자열 경계 후보 D

> **2026-10-04 기능 통합 상태:** 이 문서는 보존된 성능 trial의 역사적
> 소스·가설·검증 기록이다. S/I2/D2 최적화는 채택하지 않았으며 기능 후보의
> 전체 `Sources/`는 e15dfac8e0c97edb4706ac35595f22fc2cff5c1d와 동일하다.
> 후속 A-only 3,312개 수집은 완료됐고 69개 비교 중 3개 동등·66개 미입증이다.
> 이 결과는 후보 성능 채택 증거가 아니며 자동 표본 확대를 허용하지 않는다.
> 아래의 “현재 후보”, 미실행 상태와 예정 단계는 각 기록 시점에 해당한다.
> 최신 통합 경계는 [기능·CI 통합 기록](../reviews/FUNCTIONAL-CI-INTEGRATION-2026-10-04.md)을 따른다.

## 상태와 범위

- 기준은 `e15dfac8e0c97edb4706ac35595f22fc2cff5c1d`다. 새 로컬 후보 D이며 **아직 채택하지 않았다**
- 제품 변경은 `Sources/InnoFlowCore/StoreDiagnostics.swift`의 `snapshot(activeLimit:)`뿐이다. S/I, Store, ID 생성, collection lookup, Testing 구현은 기준과 같다
- 기존 B `64b2678`의 v8 결과 및 실패 결론은 유지한다. 문자열 변경이 비슷하다는 이유로 이전 결과를 새 후보의 증거로 재사용하거나 B의 유리한 부분을 사후 채택하지 않는다
- 새 성능 타이밍을 실행하지 않았다. 아래 검증은 동작·공개 API·정적 경계의 증거이며 성능 개선, allocation 감소, 비회귀 또는 release 준비 완료를 주장하지 않는다

## 좁은 소스 가설

기준은 정렬 비교 closure를 실행할 때마다 양쪽 `DispatchID.description`을 구한다. D는 각 active ID의 문자열과 snapshot을 tuple로 한 번 만들고, 보관한 문자열끼리 비교한다. 정렬 뒤 같은 prefix를 선택하고 snapshot만 돌려준다.

ID의 숫자 순서로 바꾸지 않는다. 숫자 `1, 2, ..., 12`의 기존 문자열 순서는 `1, 10, 11, 12, 2, ..., 9`다. 기존 lock 경계, limit 정규화, history의 독립 chronological 복사, dropped count 및 모든 active snapshot 값은 유지한다.

이는 반복 변환을 줄이는 소스 가설이다. tuple/key 저장과 최종 map 비용이 추가되며, 특히 active ID가 하나면 기준 comparator가 실행되지 않아도 D는 문자열을 만든다. `activeLimit == 0`도 원래처럼 전체 active 정렬 경로를 지난다. 이 비용의 손익은 미래의 사전 고정 cohort에서 따로 판단해야 한다.

## 동작 검증

동일한 새 테스트를 기준과 D 각각에 적용했다. Swift 6.3 및 6.4에서 strict Linux adapter로 **각각 43 tests / 5 suites**가 통과했다.

- `DiagnosticsRingConsistencyTests`: nil/음수/0/1/부분/전체/초과/Int.max limit, 제출 순서와 문자열 순서의 분리, active/queued/cancelled/sequence 값, nil sequence, 조회의 비변이성
- 보관한 snapshot은 종료·늦은 이벤트·새 제출 이후에도 유지되며, 종료한 ID가 다시 active가 되지 않는다
- 빈 active set, history wrap, 정확한 dropped count, 동시 제출과 종료의 기존 검증도 포함한다
- 명시적으로 선택한 다른 suite는 `RuntimeConsistencyTests`, `CompletionRelayConsistencyTests`, `RunLaneSnapshotConsistencyTests`, `EffectRunSchedulerTests`다

검증 generator는 위 5개 test 파일을 명시적으로 요구한다. 이전 B/C 전용 파일을 암묵적으로 기대하거나 파일이 없다는 이유로 선택한 suite를 조용히 건너뛰지 않는다. Linux의 checked Sendable `Mutex` adapter와 Apple logging guard 외의 제품 소스는 원문을 그대로 쓴다. baseline은 지정한 git SHA에서 모든 Core/Testing 소스를 읽고, D와 같은 테스트를 사용한다.

별도 공개 소비자는 `@testable`이나 package API 없이 실제 Store에서 12개 dispatch를 만들고 gate로 실행을 유지한다. 새 프로세스의 ID가 1~12임을 실제 rawValue/description으로 검증한 다음 **literal 배열**로 문자열 순서를 대조한다. 정렬 구현을 복제하지 않으며 counter reset, unsafe 접근, 대량 ID 생성이 없다. 10개 limit, active 값, limit과 무관한 history, 종료와 retained snapshot도 확인한다. 라이브러리와 소비자는 서로 다른 package 이름, Swift 6, `-O`, `enable-testing` 없이 빌드한다. 이 공개 소비자는 기준/D × Swift 6.3/6.4 네 조합 모두 통과했다.

두 compiler 각각의 공개 API dump는 `ABIRoot.tool_arguments`의 실행 경로를 제외한 모든 JSON 노드가 기준과 정확히 같다. 변경한 Swift 두 파일의 6.3/6.4 strict format lint와 `git diff --check`도 통과했다.

## 음성대조와 증거 경계

검증용 mirror에서만 숫자 정렬, limit 무시, queued count를 0으로 바꾸는 세 잘못된 구현을 만들었다. Swift 6.4에서 모두 컴파일된 뒤 각각 공개 소비자의 `lexical-order`, `active-limit`, 회귀 테스트의 `queuedRunCount` 대조에서 의도대로 실패했다. 컴파일 실패를 음성대조 성공으로 세지 않았다. 제품 후보나 봉인된 v8 artifact는 변경하지 않았다.

검증 파일과 영수증의 위치는 작업 복구 루트의 `evidence/diagnostics-boundary-20261004/`다. `source-freeze.json`은 정확한 후보 SHA와 전체 Sources map을 고정하며 `RECOVERY-MANIFEST.json`은 작은 로컬 복구 묶음의 입력을 설명한다. 소스나 테스트를 바꾸면 영향받는 검증과 freeze를 다시 만들어야 한다.

## 정적 gate와 통합

제품 후보 커밋은 소스·회귀 테스트·이 문서만 포함한다. 단독 D의 원본 inventory로 `principle-gates.sh --static`을 실행하면 새 test source hash 때문에 막힌다. 별도 검증 overlay에서 AST inventory 972 / runtime 325와 정책 hash/count를 맞추면 static gate가 통과한다. 이 overlay는 **D 제품 후보에 포함하지 않는다**. 중앙의 compiler별 조건 선택 inventory 수정과 최종 통합 때 source/count/hash를 한 번 정확히 재생성해야 한다.

Apple 원본 OS lock, OSLog, SwiftUI, UI 및 Apple 공개 API/실행 검증은 이 Linux 증거에 포함되지 않는다. 원격 CI와 main 전용 32 Release Preflight는 별도다. 채택은 독립 검토와 미래의 사전 고정 cohort 이후에만 결정하며, 이 후보만 원격 push하거나 Library에 업로드하지 않는다.
