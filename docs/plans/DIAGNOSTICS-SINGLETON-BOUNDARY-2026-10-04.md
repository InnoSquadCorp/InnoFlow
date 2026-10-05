# Diagnostics 후보 D2: 정렬이 없는 경계

> **2026-10-04 기능 통합 상태:** 이 문서는 보존된 성능 trial의 역사적
> 소스·가설·검증 기록이다. S/I2/D2 최적화는 채택하지 않았으며 기능 후보의
> 전체 `Sources/`는 e15dfac8e0c97edb4706ac35595f22fc2cff5c1d와 동일하다.
> 후속 A-only 3,312개 수집은 완료됐고 69개 비교 중 3개 동등·66개 미입증이다.
> 이 결과는 후보 성능 채택 증거가 아니며 자동 표본 확대를 허용하지 않는다.
> 아래의 “현재 후보”, 미실행 상태와 예정 단계는 각 기록 시점에 해당한다.
> 최신 통합 경계는 [기능·CI 통합 기록](../reviews/FUNCTIONAL-CI-INTEGRATION-2026-10-04.md)을 따른다.

## 이전 후보와 구별

기준은 `e15dfac8e0c97edb4706ac35595f22fc2cff5c1d`, 이전 D1은 `012294f4d27e45bfbb88b39056d6d422e943584e`다. D1 소스·43-test 검증·복구 묶음을 `evidence/diagnostics-boundary-20261004/`에 그대로 보존했다. D2의 증거는 별도 `evidence/diagnostics-singleton-20261004/`에 기록한다. D1과 D2 모두 아직 성능 채택하지 않은 로컬 후보다.

D1 검토에서 active ID 하나는 sort comparator가 비교할 쌍이 없어도 tuple의 description을 한 번 만든다는 소스 경계를 확인했다. 이는 측정된 시간 회귀라는 주장이 아니다. 좁은 불필요 작업 제거의 목적에 맞게 정렬할 필요가 없는 일반적인 0/1 경계를 별도로 처리한다.

## 구현

`state.active.count <= 1`이면 기존 lock 안에서 정규화한 limit의 prefix를 snapshot으로 만든다. 이 경로에는 description 접근이나 정렬이 없다. ID가 하나 이하이므로 Dictionary의 나열 순서가 결과를 바꾸지 않는다.

`count > 1`이면 D1의 문자열 key 사전 계산·lexical sort·prefix 선택을 그대로 사용한다. 다수 경로에 중간 snapshot 배열을 추가하지 않는다. 두 경로의 snapshot 생성 필드는 같으며, chronology 복사와 dropped count도 유지한다. 제품 Sources 변경은 여전히 `StoreDiagnostics.swift` 하나뿐이다.

분기 및 tuple/key 저장·최종 map의 비용은 남아 있다. `activeLimit == 0`인 다수 경로 최적화 등은 추가하지 않았다. 별도 시간 측정이나 allocation 측정은 하지 않았으며, 새 cohort의 사전 고정과 비회귀 판정 전에는 채택할 수 없다.

## 정확한 검증 범위

동일한 D2 테스트를 e15 기준과 D2에 각각 적용했다. Swift 6.3/6.4의 strict Linux adapter 네 조합 모두 **44 tests / 5 suites**가 통과했다. 이는 D1의 이전 43-test 결과와 별개다.

- 정렬/값 검증을 0/1/24개 active 상태로 실행한다
- 별도 singleton은 activeRunCount=2, queuedRunCount=1, cancellation=true, sequence=77을 만들고 nil/음수/0/1/초과/Int.max limit과 모든 값을 확인한다
- 이전 D1의 retained snapshot, 늦은 이벤트, 빈 상태, ring 및 runtime/scheduler suite를 유지한다
- 실제 공개 Store 소비자는 singleton에서 12개 active dispatch로 전이한다. 단일 값/limit/history 및 literal `[1, 10, 11, 12, 2, ..., 9]` 순서/값/종료를 확인한다. 이 소비자도 기준/D2 × Swift 6.3/6.4 네 조합 모두 통과했다
- 공개 소비자는 별도 package 이름으로 빌드하며 `@testable`, package API, counter reset, unsafe 접근 또는 대량 ID 생성이 없다. 라이브러리/소비자 모두 `-O`, Swift 6, `enable-testing` 없이 빌드한다
- 두 compiler의 공개 API dump는 실행 경로인 `ABIRoot.tool_arguments`를 제외한 모든 JSON 노드가 기준과 정확히 같다. 변경한 두 Swift 파일의 6.3/6.4 strict format lint 및 `git diff --check`도 통과했다

Swift 6.4 음성대조는 validation mirror에서만 numeric order, 다수 active limit 무시, 두 분기의 queued count=0을 만들었다. 모두 컴파일된 뒤 각각 공개 소비자의 `lexical-order`, `active-limit`, 두 값 테스트의 `queuedRunCount` assertion에서 의도대로 실패했다. 컴파일 실패를 대조 성공으로 세지 않았다. 값 대조는 singleton과 0/1/24개 테스트를 함께 실행했다. 제품 소스 및 D1 복구 입력은 변경하지 않았다.

## 남은 경계

원본 inventory의 단독 static gate는 변경한 test source hash에서 의도대로 막힌다. 임시 standalone AST inventory 973 / runtime 326 및 정책 overlay에서는 static gate가 통과했다. overlay는 제품 커밋에 넣지 않았다. 중앙의 compiler별 조건 선택 수정과 최종 S/I/D 통합에 맞춰 AST/count/hash를 다시 생성해야 한다.

Linux checked Mutex adapter는 Apple 원본 OS lock, OSLog, SwiftUI, UI 또는 Apple API/실행을 검증하지 않는다. 해당 원격 CI 및 main 전용 32 Release Preflight는 별도다. D2 `source-freeze.json`과 복구 manifest가 정확한 소스별 증거를 묶는다. 독립 검토 및 미래 사전 고정 cohort 전 채택하지 않으며, 이 작업에서 원격 push/Library 업로드/merge/tag/release를 하지 않는다.
