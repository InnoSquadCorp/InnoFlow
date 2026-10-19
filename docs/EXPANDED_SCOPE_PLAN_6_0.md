---
date: 2026-10-03
project: InnoFlow
design: 6.0.0 통합 확장 범위 — 기술 깊이로 TCA 넘어서기
owner: Claude (초안 작성)
decision-owner: 프로젝트 소유자
status: Draft
reviewed-by: []
approved-by:
approved-at:
document-depth: expanded
---

# InnoFlow 6.0.0 통합 확장 계획

> **Draft.** 작업 계획이며 구현 완료나 릴리스 승인이 아니다. 릴리스 절차와
> 증거 정책의 정본은 계속 [RELEASING.md](../RELEASING.md)다. 이 문서는 6.0.0
> 후보의 **범위**를 넓힌다. [사전 배포 실행 계획](PRE_RELEASE_EXECUTION_PLAN_6_0.md)의
> R59~R69 증거 요구와 CLAUDE.md의 CI 전용 검증 규칙은 그대로 유지한다.

## 1. 문서 관리

| 항목 | 값 |
|---|---|
| 상태 | Draft (리뷰·승인 기록 없음) |
| 작성 | Claude, 2026-10-03 평가 세션 |
| 결정권자 | 프로젝트 소유자 |
| 기준 커밋 | main `1389926` |
| 범위 결정 | 6.1·6.2로 나누지 않고 6.0.0 한 번에 포함 (§10 R-1) |
| 관련 문서 | [RELEASING.md](../RELEASING.md), [CLAUDE.md](../CLAUDE.md), [API_BREAKAGE_6_0.md](API_BREAKAGE_6_0.md), [PERFORMANCE_BASELINES.md](PERFORMANCE_BASELINES.md), [FRAMEWORK_COMPARISON.md](FRAMEWORK_COMPARISON.md) |
| 문서 깊이와 이유 | expanded. 메이저 창이 6.0뿐인 공개 API 결정 15건, 릴리스 증거 정책 변경, 워크스트림 10개 간 조정이 필요하고, 잘못되면 6.x 내내 되돌릴 수 없다 |

## 2. 목적과 맥락

**목적.** 6.0.0 메이저 릴리스 하나에 성능·테스트 도구·DX·문서·효과 수명·동시성
개선을 모두 담아, 기능 폭이 아니라 기술 깊이로 TCA 1.26과 공개된 TCA 2.0 베타의
방향을 넘어선다.

**배경.** 2026-10-03 평가 루브릭(10점 만점 축별 점수 × 가중치)의 결과다.

| 축 (가중치) | InnoFlow 6.0 RC | TCA 1.26.2 | 이 계획의 목표 |
|---|---:|---:|---:|
| A 타입 계약 (15) | 9 | 8.5 | 9.5 |
| B Swift 6 동시성 (15) | 8.5 | 8 | 9 |
| C 효과·수명 제어 (10) | 8.5 | 8.5 | 9.5 |
| D 테스트 도구 (15) | 8.5 | 9.5 | 10 |
| E SwiftUI·DX (10) | 6.5 | 8 | 8.5 |
| F 성능 (10) | 5 | 7.5 | 9 |
| G 문서·릴리스 (10) | 8 | 9 | 9 |
| **기술 점수 (A~G)** | **78.8** | **84.7** | **92.6** |

TCA 2.0은 유료 회원 전용 베타라 같은 루브릭으로는 약 87.6으로만 추정한다.
점수는 결과를 요약한 값일 뿐 수용 기준이 아니다. 판정은 §7의 수치 목표와 §11
추적표의 증거로 한다.

**비목표 (컨셉 경계).**

- 내비게이션 스택·라우팅 상태(InnoRouter 담당), DI 그래프와 `@Dependency` 계열
  (InnoDI 담당, [ADR](adr/ADR-no-builtin-di-container.md)), 전송·세션(InnoNetwork 담당),
  `@Shared` 계열의 영속 공유 상태는 InnoFlow에 넣지 않는다.
- `some ReducerOf<Self>` 별칭과 `Output = Never` 자동 합성은 CLAUDE.md 계약 1(세 번째
  제네릭 명시)을 바꾸므로 제외한다. 소유자가 따로 결정하면 다시 검토한다.
- MainActor 밖에서 도는 headless Store는 InnoFlow의 범위를 넓히는 결정이므로 7.0 후보로 둔다.
- 릴리스 스크립트의 대규모 재작성은 패키지 내용과 무관하므로 태그 이후 별도로 진행한다(§8.6).

**대표 시나리오.**

1. 5.1.1 앱이 Fix-It과 codemod만으로 6.0에 이행하고, 고빈도 액션 화면의 `send`
   비용이 기존의 1/10 이하로 준다.
2. 검색 피처를 `.latest` run lane, typed Output, PhaseMap으로 작성한다. 테스트는
   phase 전이 커버리지 100%와 seed 탐색 1,000스텝을 통과하고, effect 원장으로
   대체·취소 순서를 단언한다.
3. 뷰가 사라지면 그 뷰가 시작한 dispatch 트리만 취소되고, 다른 작업은 계속된다.
4. 개발 빌드에서 Flow Inspector로 현재 phase, 활성 dispatch, run lane 상태를 본다.

## 3. 근거 상태

### 확인된 사실 (2026-10-03)

| ID | 사실 | 출처 |
|---|---|---|
| F-1 | Swift 6.4 / Xcode 27.0, `-warnings-as-errors`에서 런타임 테스트 731개(59 suite)와 매크로 테스트 68개가 debug(4분 5초)와 release(4분 47초) 모두 통과했다 | 로컬 실행, 릴리스 증거 아님 |
| F-2 | Release Preflight는 한 번도 성공하지 않았다. 9/30의 두 번은 모두 28/32에서 끝났고, 실패한 4건은 `runtime-ios-18.5`, `runtime-tvos-18.5`, `runtime-watchos-11.5`, `runtime-visionos-2.5`로 같다. 실패 메시지는 `iOS 18.5 (universal) is not available for download`다 | GitHub Actions run 36650422297, 36703581250 |
| F-3 | 이후 런타임 준비 코드([hosted-release-preflight.rb:33](../scripts/hosted-release-preflight.rb), :119)와 정책 JSON은 바뀌지 않았다 | `git diff 5a17eeb..HEAD` |
| F-4 | 러너 이미지별 구성: `xcode-27-arm64` 20260921.0210에는 Xcode 27.0/27.1/27.2β와 27.x 시뮬레이터만 있다. `macos-26-arm64` 20260907.0351.1에는 Xcode 26.0.1~26.6과 26.x 시뮬레이터만 있다. `macos-15-arm64` 20260907.0337.1에는 Xcode 16.0~16.4와 26.0.1~26.3이 있고, **iOS 18.5·tvOS 18.5·watchOS 11.5·visionOS 2.5 시뮬레이터가 사전 설치**돼 있다 | actions/runner-images 이미지 Readme |
| F-5 | 저장소 environment는 `github-pages` 하나뿐이고, [cd.yml:328](../.github/workflows/cd.yml)이 참조하는 `release`는 없다. 태그 보호 룰셋 `release-tags`는 활성 상태다 | `gh api .../environments`, `.../rulesets` |
| F-6 | `send` 실측값(µs, 7회 중앙값, release, 관찰자 없음): 5.1.1은 4.37 / 6.0 RC는 5.33 / 6.0 RC + 시제품 패치는 1.25 / TCA 1.26.2는 0.74. `send` + 동기 후속 10회는 각각 46.4 / 54.2 / 9.4 / 28.0. 5.1.1에 같은 패치를 넣으면 0.49 / 4.0 | 세션 벤치마크 |
| F-7 | 6.0 RC의 send 경로 CPU 중 63%(5.1.1은 71%)를 제네릭 `Store<R>`의 `@Observable` 접근자가 key path를 매번 런타임에 만드는 데 쓴다([Store.swift:301](../Sources/InnoFlowCore/Store.swift), :312, :313). 패치 후 남은 비용은 drain 마감 부기 32%, FlowTask activity 16%, 관찰자 refresh 8%, `withMutation` 8%다 | `sample` 프로파일 |
| F-8 | 시제품 패치(key path 캐시, drain 루프에서 `_state` 직접 사용과 `withMutation` 1회)는 스크래치 사본에서 테스트 799개를 모두 통과했다 | 로컬 실행 |
| F-9 | 다음 결함은 대조군과 함께 재현했다. D1(trailing throttle + 핸들 폐기 시 diagnostics active 누수, 요청 1건부터 재현, `.run`·debounce는 정상), D2, T1, T2, M1, M2(정의는 §5.3) | 스크래치 프로브 |
| F-10 | Sources 전체에 `@unchecked Sendable`, `nonisolated(unsafe)`, `assumeIsolated`, `@preconcurrency`가 하나도 없다 | grep |
| F-11 | TCA 1.26.2는 2026-08-28에 릴리스됐다. TCA 2.0은 2026-04부터 유료 회원 전용 베타이며 `@Feature`, `addTask`, onMount/onDismount, DebugSnapshots, StoreActor, NonisolatedNonsendingByDefault 채택을 공개했다 | pointfreeco 릴리스 노트, Point-Free 블로그 206 |

### 작업 가정

| ID | 가정 | 진행 근거 | 검증 시점 |
|---|---|---|---|
| A-1 | `macos-26` 러너에서 Xcode 26.6으로 iOS 18.5 등 4개 런타임을 내려받아 import할 수 있다 | Xcode 26은 iOS 18 시뮬레이터를 지원한다. 다만 다운로드 카탈로그가 실제로 제공하는지는 확인하지 못했다 | W0-1, 1주 차 |
| A-2 | 관찰 key path 캐시는 알림 의미를 바꾸지 않는다 | 기존 테스트 799개 통과(F-8) | W1-1에 알림 횟수·순서 테스트 신설 |
| A-3 | send 0.5µs 이하를 달성할 수 있다 | 같은 패치를 넣은 5.1.1이 0.49µs(F-6)이고, 남은 비용 구성이 확인됐다(F-7) | W1 반복 측정 |
| A-4 | 소유자가 8주 동안 PR 약 30개를 리뷰할 수 있다 | 기존 6.0 작업의 PR 속도 | 매주 점검 |
| A-5 | 6.0 출시 전에 TCA 2.0 정식판이 나와도 비교 기준은 크게 흔들리지 않는다 | 2.0의 공개 일정이 없다 | M4에서 재확인 |

### 미확인

| ID | 미확인 사항 | 영향받는 결정 | 해소 시점 |
|---|---|---|---|
| U-1 | `macos-15` 이미지의 Xcode 26.3에 들어 있는 Swift 버전(6.3 미만이면 InnoFlow를 빌드할 수 없다) | D-13 대안 C | W0-1 |
| U-2 | 현 툴체인에서 XCTest 테스트 안에서 `Issue.record`를 호출하면 실패로 기록되는지 | W4-3 설계 | W4-3 첫 작업 |
| U-3 | 공개 클로저 파라미터 타입에 `@concurrent`를 붙였을 때 Swift 6.3 소비자의 소스 호환성 | D-12 | W8-1 픽스처 |
| U-4 | TCA 2.0 정식판의 API와 성능 | §2 비교 기준 | M4 |

## 4. 현재 시스템과 제약

- **제품.** `InnoFlowCore`(컴파일러 플러그인 없는 런타임), `InnoFlow`(매크로 파사드),
  `InnoFlowSwiftUI`, `InnoFlowTesting`. 외부 의존성은 swift-syntax(`603.0.0..<605.0.0`) 하나다.
- **계약.** CLAUDE.md 계약 1~18이 정본이다. 계약을 바꾸는 PR은 CLAUDE.md, 테스트,
  `scripts/principle-gates.sh`, CI를 같은 브랜치에서 갱신해야 한다.
- **릴리스.** 32개 검사는 GitHub 호스티드 러너의 `Release Preflight`에서만 실행한다.
  소유자 Mac에 런타임을 설치하거나 로컬에서 execute/resume을 실행하지 않는다. 태그와
  GitHub Release 공개는 각각 따로 승인받는다.
- **semver.** 6.0 태그 이후에는 `STABLE_VERSION` 승격과 함께 API 호환 게이트가 필수가 된다.
  **공개 API 형태는 태그 전에 확정해야 한다.**
- **문서 게이트.** README·DocC의 Swift 펜스를 바꾸면 펜스 원장
  (`docs/contracts/doc-swift-fence-review.tsv`)과 RELEASING.md의 인벤토리 수치를 함께
  갱신해야 한다. 4개 언어 README와 release-sync 검사도 맞춰야 한다.
- **툴체인.** Swift 6.3이 최소이고 Xcode 26.6이 주 툴체인이다. Swift 6.3.3 Release 빌드에는
  `StoreOutputHub.deinit` SIL 크래시 우회가 들어 있다.

## 5. 설계 — 워크스트림

### 5.0 공통 규칙과 컨셉 체크리스트

모든 항목은 아래 여섯 가지를 통과해야 PR을 병합할 수 있다.

1. 내비게이션, 전송, DI, 영속을 InnoFlow 안으로 들이지 않는다.
2. 비즈니스 전이의 소유자는 계속 리듀서다.
3. 명시적이고 opt-in이다. 숨은 전역 상태나 암묵 동작이 없다.
4. 런타임 진단은 bounded·payload-free를 유지한다. 테스트 전용 도구는 예외다.
5. 규칙은 매크로 진단, 테스트, principle gate로 강제한다. 문서에만 적어 두지 않는다.
6. InnoFlowCore는 컴파일러 플러그인 없는 런타임으로 남는다.

공개 API를 바꾸는 PR은 같은 PR에서 [API_BREAKAGE_6_0.md](API_BREAKAGE_6_0.md),
MIGRATION.md, 이행 소비자 픽스처(`Tests/Fixtures/MigrationConsumer`)를 갱신한다.

크기 기준: S는 반나절 이하, M은 1~2일, L은 3~5일(에이전트 보조 기준)이다.

### 5.1 W0 릴리스 인프라 (P0, 크리티컬 패스)

| ID | 작업 | 변경 위치 | 수용 기준 | 크기 |
|---|---|---|---|---|
| W0-1 | 레거시 런타임 프로비저닝 진단. 임시 `workflow_dispatch` 워크플로를 `macos-26`(Xcode 26.6)에서 실행한다. 4개 런타임 각각 `-downloadPlatform`(arm64, 실패 시 universal) → `-importPlatform` → `simctl list runtimes`를 수행하고, 런타임 하나로 focused runtime inventory를 스모크 실행한다. `macos-15`에서는 Xcode 26.3의 `swift --version`도 기록한다(U-1) | `.github/workflows/runtime-provisioning-probe.yml`(임시) | 4개 런타임 각각 성공 여부와 정확한 오류를 아티팩트로 남김 | S |
| W0-2 | D-13 결정에 따라 정책과 매트릭스를 바꾼다. 추천안은 4개 레거시 런타임 검사를 `macos-26`/26.6/Swift 6.3 job으로 옮기는 것이다 | `scripts/hosted-release-preflight.rb:33`(minimum 집합), `docs/contracts/release-evidence-policy.json`, `scripts/hosted-release-preflight-selftest.rb`, RELEASING.md 19단계, CLAUDE.md·AGENTS.md CI 문단 | selftest의 음성 대조 통과. 검증기가 정확한 런타임+Xcode 쌍만 수락 | M |
| W0-3 | W0-2 병합 직후 중간 main SHA에서 Preflight 시험 실행 #1. 후보 증거는 아니다 | — | 32/32 성공, 또는 실패마다 원인 PR이 있음 | S + 대기 약 8.5시간 |
| W0-4 | `release` environment를 만들고 required reviewer와 태그 전용 배포 규칙을 설정한다(관리자 작업) | GitHub 설정 | `gh api .../environments`에 `release`와 보호 규칙이 보임 | S |
| W0-5 | CHANGELOG 날짜 강제. `INNOFLOW_REQUIRE_RELEASE_TAG=1`일 때 `## [6.0.0] - YYYY-MM-DD`만 허용한다 | [check-release-sync.sh:152](../scripts/check-release-sync.sh) + selftest | `Unreleased` 상태로 태그 검사를 돌리면 실패 | S |
| W0-6 | Ruby 2.7 이상 요구를 명시하고, `principle-gates.sh` 시작 시 버전 검사와 명확한 오류 메시지를 넣는다. 현재 macOS 기본 Ruby 2.6에서는 `check-ci-efficiency.rb:92`의 `filter_map`이 실패한다 | CONTRIBUTING.md, `scripts/principle-gates.sh` | Ruby 2.6에서 실행하면 안내 메시지와 함께 종료 | S |

### 5.2 W1 성능 (F 5 → 9)

| ID | 작업 | 변경 위치 | 수용 기준 | 크기 |
|---|---|---|---|---|
| W1-0 | 벤치마크 하네스를 만든다. 루트 패키지 그래프 밖에 독립 패키지 `Benchmarks/InnoFlowBenchmarks`를 둔다. 비교용 `Benchmarks/Comparison`은 TCA를 정확한 버전으로 핀하고 CI에서 non-blocking 추세 job으로 돌린다. 시나리오: S1 send 1회 / S2 send + 동기 후속 10회 / S3 1,000행 컬렉션 스코프에서 행 1개 갱신(관찰자 1,000개) / S4 SelectedStore 100개 + 무관 필드 갱신 / S5 `@BindableField` 바인딩 갱신 / S6 TestStore send→receive 왕복 | `Benchmarks/`, `docs/PERFORMANCE_BASELINES.md`, CI | S1~S6 기준선을 기록하고 추세 job이 동작 | M |
| W1-1 | Store 관찰 key path 캐시(F-7, F-8). 인스턴스에 `@ObservationIgnored` key path를 캐시하고, drain 루프에서는 `_state`를 직접 쓰면서 action당 `withMutation`을 한 번만 부른다. 공개 `state` getter도 캐시된 key path로 `access`하는 수동 접근자로 바꿔 dynamic member 읽기 비용까지 없앤다 | [Store.swift:301](../Sources/InnoFlowCore/Store.swift) 부근 | 관찰 알림 횟수·순서 동일성 테스트 신설(`withObservationTracking`, 애니메이션 경로 포함). S1 1.25µs 이하 | M |
| W1-2 | ScopedStore(`cachedState`, `isActive`)와 SelectedStore(`cachedValue`, `isActive`)에 같은 기법을 적용한다 | ScopedStore.swift:313~, SelectedStore.swift:22~ | S3·S4가 기준선 대비 2배 이상 개선 | M |
| W1-3 | drain 마감 부기를 줄인다. 계측이 꺼져 있으면 스냅샷과 이벤트를 만들지 않고, stride 같은 제네릭 메타데이터를 상수로 캐시하고, action 1개짜리 drain에 fast path를 둔다 | [StoreActionQueue.swift:72](../Sources/InnoFlowCore/StoreActionQueue.swift) | 프로파일에서 이 비중이 32%에서 5% 이하로 | S |
| W1-4 | FlowTaskTracker 부기를 줄인다. activity 토큰을 `Set<UUID>`에서 단조 정수로 바꾸고, diagnostics가 없으면 onFinish/onCancel 클로저를 할당하지 않는다 | [FlowTask.swift:166](../Sources/InnoFlowCore/FlowTask.swift), :172, :207 | 프로파일에서 이 비중이 16%에서 5% 이하로 | M |
| W1-5 | D-1 결정에 따라 DispatchID를 단조 `UInt64`로 바꾼다. `EffectTimingRecorder.Entry.dispatchID`와 JSONL 스키마도 함께 바꾼다 | [DispatchContext.swift:9](../Sources/InnoFlowCore/DispatchContext.swift), EffectTimingRecorder.swift:45 | send 경로에서 RNG 호출 0회 | M |
| W1-6 | ProjectionObserverRegistry에 관찰자 0개 fast path를 넣고, bucket을 제자리 갱신해 등록 시 O(n²) 복사(리뷰 D4)를 없앤다 | [ProjectionObserverRegistry.swift:357](../Sources/InnoFlowCore/ProjectionObserverRegistry.swift) | 등록 1,000건이 선형 시간 | S |
| W1-7 | diagnostics가 있을 때만 취소 대상 dispatch를 계산한다(리뷰 D3) | [StoreEffectBridge.swift:294](../Sources/InnoFlowCore/StoreEffectBridge.swift) 호출부 | diagnostics가 없으면 취소당 runtime 왕복 1회 | S |
| W1-8 | (선택) 벤치마크로 효과가 확인된 핫패스에만 `@inlinable`/`@usableFromInline`을 붙인다 | 핫패스 한정 | 효과 측정값과 API 인벤토리 반영 | M |

목표: S1 0.50µs 이하, S2 6.0µs 이하. S3·S4는 기준선 대비 2배 이상 개선하고 TCA의 대응 시나리오 이하로 맞춘다.

### 5.3 W2 정확성 (리뷰 결함 전수)

| ID | 결함 | 위치 | 수정과 수용 기준 | 크기 |
|---|---|---|---|---|
| D1 | trailing throttle에서 핸들을 버리면 StoreDiagnostics의 active가 누수된다(재현됨) | [FlowTask.swift:231](../Sources/InnoFlowCore/FlowTask.swift) | 공유 task 수명 동안 tracker를 강하게 보유하거나, tracker deinit 때 미종료면 종료를 기록한다. 핸들을 버려도 active=0 | S |
| D2 | `perform`이 호스트가 취소하지 않은 `CancellationError`를 삼킨다(재현됨) | [EffectTask.swift:468](../Sources/InnoFlowCore/EffectTask.swift), :511, :540 | 호스트 취소가 없으면 failure를 전달한다. 동작 변경이므로 MIGRATION에 적는다 | S |
| C1 | 사전 취소된 요청이 lane 용량을 점유한다(후보) | [EffectRunScheduler.swift:100](../Sources/InnoFlowCore/EffectRunScheduler.swift) | 재현 → admission 시 토큰 취소를 확인하고 즉시 반환. 계약 12 | M |
| C2 | `.latest`에 sequence 단조성 가드가 없다(후보) | EffectRunScheduler.swift:137 | 재현 → debounce처럼 sequence를 비교. 늦게 도착한 오래된 요청이 새 요청을 밀어내지 않음 | M |
| C3 | `onChange`의 merge 순서가 Store와 TestStore에서 다르다(후보) | ReducerOnChange.swift:31 | 문서화 + 패리티 테스트. merge는 동시 실행이라는 의도를 유지 | S |
| D5 | diagnostics 이력의 `removeFirst`가 O(capacity)다 | [StoreDiagnostics.swift:276](../Sources/InnoFlowCore/StoreDiagnostics.swift) | 링 버퍼로 교체 | S |
| D6 | scheduler `finish`의 방어 경로가 잘못돼 있다 | EffectRunScheduler.swift:256 | 수정 + 단위 테스트 | S |
| T2 | exhaustive `finish()`가 action만 보고하고 output은 빠뜨린다(재현됨) | TestStore+Finish.swift:254 (action이 있으면 output 확인 전에 반환) | 둘 다 보고 | S |
| M1 | `strictPhaseTotality`가 백틱 case를 잘못 오류로 판정한다(재현됨) | InnoFlowMacro+PhaseTotalityDiagnostics.swift:76, :193 | 이름 정규화. 대조 테스트 포함 | S |
| M2 | raw identifier case에서 매크로가 잘못된 코드를 생성한다(재현됨) | InnoFlowMacro+OutputPathSynthesis.swift:376, CasePathSynthesis | 유효한 멤버 이름을 생성하거나 명확한 진단을 낸다 | M |
| P3 묶음 | deinit 메시지의 scheduled 수 누락, dead code `nextActionWithinTimeout`, `assertNoBufferedActions` reporter 경로, 진단 placeholder, `Swift.Never` 거부, explicit reduce Fix-It이 `Never` 하드코딩, macOS `fullScreenCover`의 도달 불가 분기 | 리뷰 목록 | 항목별 수정 + 회귀 테스트 | M |
| 매크로 후보 | `os(OSX)`·공백 변형을 배타 조건으로 오판, `renamed:` availability 복사, Phase enum 내부 `#if` 미검사(fail-open) | OutputPathSynthesis.swift:89, :683, PhaseTotalityDiagnostics.swift:63 | 재현 → 수정 또는 의도 문서화 | M |

### 5.4 W3 공개 API 확정 (태그 전에만 가능)

결정 항목 D-1~D-15는 §6에 있다. W3은 그 결정을 구현에 반영하는 작업이다.
1주 차 안에 결정을 끝내야 W4·W6·W7을 시작할 수 있다. 결정마다 API 인벤토리,
MIGRATION, 이행 소비자 픽스처, compile contract 테스트를 같은 PR에서 갱신한다.
마지막으로 W3-Z에서 `swift package diagnose-api-breaking-changes 5.1.1`과 공개 심볼
인벤토리를 재생성하고 전 항목을 분류한다.

### 5.5 W4 테스트 도구 — 따라잡기 (D 8.5 → 9.5)

| ID | 작업 | 수용 기준 | 크기 |
|---|---|---|---|
| W4-1 | T1 의미를 확정하고 구현한다(D-7). `.off` 모드 `receiveOutput`이 `receive`처럼 중간 action을 reduce한다 | 재현 프로브가 통과하고, 기존 `.off` 테스트의 의미가 문서화됨 | S |
| W4-2 | `TestStore.send`가 `@discardableResult` `TestStoreDispatch`를 반환한다(D-6). `finish(timeout:)`, `cancel()`, `isFinished`를 제공하고 scoped store에도 적용한다 | 계약 8(dispatch 범위 취소·대기)을 TestStore에서 검증하는 테스트가 Store와 같은 결과를 냄 | L |
| W4-3 | 실패 보고 패리티(D-11). `Test.current`가 있으면 `Issue.record(_:sourceLocation:)`, 없으면 XCTest의 `XCTFail`로 보낸다. 공개 파라미터를 `fileID`/`filePath`/`line`/`column`으로 통일한다 | XCTest 픽스처에서 `XCTExpectFailure`로, Swift Testing에서 `withKnownIssue`로 실패 위치가 호출 지점인지 확인(U-2) | M |
| W4-4 | Scoped `receiveOutput`에 exact/predicate overload를 추가하고 `.off`·timeout·취소 테스트를 넣는다 | 루트 TestStore와 오버로드 집합이 같음 | S |
| W4-5 | 리뷰에서 찾은 테스트 공백을 채운다. TestStore의 `.dropWhileRunning`·거절된 admission·두 send에 걸친 `.latest`, finish 중 취소, deinit output 보고, 세 번째 제네릭 진단 3종, `presentationBinding` 직접 호출, 애니메이션 typed output 보존 단언, 합성 reducer의 invariant, strict totality의 비리터럴 인자 | 항목마다 회귀 테스트 | L |
| W4-6 | flaky 위험을 없앤다. StoreEffectRuntimeTests.swift:1414의 고정 100ms 대기는 `waitForNowReads`로 바꾸고, `waitUntilAsync` 결과를 버리는 2곳은 단언으로 바꾸고, StoreScopeSelectionTests의 20ms sleep 21곳은 결정적 대기로 바꾼다 | 고정 sleep을 grep gate로 막고 예외는 목록화 | M |
| W4-7 | 구조적 diff. Mirror 기반으로 `state.items[3].title: "a" → "b"` 같은 경로 diff를 보여 준다 | 중첩 컬렉션 diff 스냅샷 테스트 | M |

### 5.6 W5 테스트 도구 — 앞지르기 (D → 10, InnoFlow 고유)

| ID | 작업 | 설계 요점 | 수용 기준 | 크기 |
|---|---|---|---|---|
| W5-1 | Phase 전이 커버리지 | `PhaseCoverageRecorder(Feature.phaseMap)`를 TestStore에 **명시적으로** 넘긴다(전역 상태 없음). `send/receive(_:through:)`가 관측한 (from, to, trigger) 전이를 스레드 안전하게 누적한다. 결과는 `report()`(covered/uncovered), `assertPhaseCoverage(minimum: .all)`, 미검증 전이를 강조한 Mermaid로 본다. 지금의 [assertPhaseMapCovers](../Sources/InnoFlowTesting/PhaseMap+Testing.swift)는 선언 커버리지만 본다 | 샘플 PhaseMap 피처에서 미검증 전이를 정확히 보고하고, 병렬 실행에서도 집계가 결정적 | L |
| W5-2 | seed 기반 상태 탐색 | `TestStoreExplorer`가 상태를 보고 action을 고르는 가중 생성기(clock advance 포함)와 SplitMix64 PRNG로 무작위 시퀀스를 실행한다. 검사 항목: 기존 `addInvariant`, PhaseMap 불법 전이(디버그 크래시가 아닌 테스트 실패 경로), 예외. 실패하면 delta debugging으로 최소 시퀀스를 찾고, seed와 함께 복붙 가능한 `TestStoreScenario`로 출력한다. `TestStoreScenario.seed`(D-8)를 재현 키로 쓴다 | 의도적 버그를 심은 픽스처에서 1,000스텝 안에 발견. 같은 seed는 같은 시퀀스를 만들고, 최소화 결과가 재현됨 | L |
| W5-3 | effect 원장 | TestStore 전용으로 dispatch별 타입 이벤트를 모은다: `.admitted(EffectAdmission)`, `.started`, `.superseded`, `.rejected`, `.cancelled(cause)`, `.finished`, `.failed`. 기존 instrumentation 이벤트를 테스트에서만 수집하고 `TestStoreDispatch`(W4-2)로 조회한다. 런타임 StoreDiagnostics는 payload-free를 유지한다(계약 14) | `.latest` 대체, `.serial` 대기·거절, dispatch 취소를 원장으로 단언하는 테스트 | M |
| W5-4 | 샘플과 문서 | 샘플 앱 테스트에 커버리지·탐색·원장 사용 예를 넣고 DocC에 "Advanced testing" 문서를 추가한다 | 문서 펜스 컴파일 게이트 통과 | S |

새 계약 후보: 커버리지·탐색·원장은 테스트 전용이며 런타임 phase·effect 의미를 바꾸지 않는다.
탐색은 같은 seed와 같은 생성기에서 같은 시퀀스를 보장한다.

### 5.7 W6 매크로와 이행 DX

| ID | 작업 | 수용 기준 | 크기 |
|---|---|---|---|
| W6-1 | 세 번째 제네릭 Fix-It. [InnoFlowMacro.swift:138](../Sources/InnoFlowMacros/InnoFlowMacro.swift)의 `throw`를 Diagnostic + FixIt으로 바꾸고, nested `Output` 유무에 따라 `, Never` 또는 `, Output`을 넣는다. "Expected" 문구도 실제 형태로 바꾸고, 무관한 Remediation 문구는 없앤다 | 진단 3종의 메시지와 Fix-It 적용 결과를 스냅샷 테스트로 고정 | M |
| W6-2 | codemod `Tools/innoflow-migrate`. SwiftSyntax 실행 파일로 루트 그래프 밖에 둔다. 변환 대상: body 제네릭, 명시적 `Reduce<…>`/`CombineReducers<…>`, `assertNoMoreActions()`→`finish()`, W3의 API 변경(serial `UInt`, FlowScope, alert 제목, TestStore 파라미터) | MigrationConsumer V5 소스에 codemod를 적용하면 수동 수정 0건으로 6.0 후보에서 컴파일됨(CI job) | L |
| W6-3 | 진단 메시지 정비. placeholder를 실제 이름으로, 충돌 멤버 이름 표시, `Swift.Never` 허용 | 매크로 테스트 | S |

### 5.8 W7 SwiftUI와 DX (E 6.5 → 8.5)

| ID | 작업 | 수용 기준 | 크기 |
|---|---|---|---|
| W7-1 | alert/confirmationDialog 제목을 SwiftUI와 같은 세 가지 오버로드(`LocalizedStringKey`, `StringProtocol`, `Text`)로 바꾼다(D-10) | 리터럴이 지역화 키로 해석되는지 테스트 | S |
| W7-2 | presentation 헬퍼 6종을 README 4개 언어, DocC, 샘플에 문서화한다. iOS 전용 `fullScreenCover` compile contract를 둔다 | release-sync와 펜스 게이트 통과 | M |
| W7-3 | 뷰 수명 dispatch modifier `.innoFlowTask(store, action:)`, `.innoFlowTask(store, id:, action:)`. 나타날 때 send하고, 사라지거나 id가 바뀌면 **그 dispatch만** 취소한 뒤 종료를 기다린다. 내부는 SwiftUI `.task`와 FlowTask다 | 다른 dispatch와 store 전체는 영향을 받지 않음(계약 8·13과 일관). 핵심 함수 단위 테스트와 샘플 사용 | M |
| W7-4 | 개념 계층화. README·DocC 첫 화면은 Level 1(Reduce, Store, `@BindableField`, TestStore)만으로 구성한다. Level 2는 Scope, ForEach, select, Output이고, Level 3는 FlowTask, run lane, FlowScope, PhaseMap, Diagnostics, Inspector다. 샘플 앱 화면 순서도 같은 계층을 따른다 | Level 1만으로 완결되는 예제를 compile contract로 보장 | M |
| W7-5 | Flow Inspector를 새 product `InnoFlowInspector`로 만든다(D-14). DEBUG에서 쓰도록 권장한다. 보여 주는 것: PhaseMap 그래프와 현재 phase, StoreDiagnostics 스냅샷(활성 dispatch, 최근 기록, run lane). payload-free 진단만 쓴다. tvOS·watchOS는 축소 UI를 주거나 미지원을 명시한다 | 샘플 앱에서 동작. PrivacyInfo, API 인벤토리, 플랫폼 빌드 매트릭스 반영 | L |

### 5.9 W8 동시성 (B 8.5 → 9)

| ID | 작업 | 수용 기준 | 크기 |
|---|---|---|---|
| W8-1 | effect 실행 격리를 명시한다(D-12). `.run`, `.perform`, scheduled run의 operation 클로저 타입에 `@concurrent`를 붙여, 앞으로 InnoFlow나 소비자가 NonisolatedNonsendingByDefault를 켜도 사용자 effect가 MainActor로 끌려오지 않게 한다 | upcoming feature를 켠 소비자 픽스처에서 effect가 MainActor 밖에서 실행됨을 단언(U-3) | M |
| W8-2 | InnoFlow 내부 타깃에 NonisolatedNonsendingByDefault를 적용할지 평가한다 | TSan, 전체 테스트, 벤치마크를 비교해 채택 여부를 결정하고 기록. 채택하지 않아도 공개 의미는 W8-1로 고정됨 | M |
| W8-3 | unsafe escape 0건 유지 gate. `@unchecked Sendable`, `nonisolated(unsafe)`, `assumeIsolated`, `@preconcurrency`를 Sources에서 grep으로 막는다(F-10) | principle gate와 음성 대조 | S |

### 5.10 W9 문서 (G 8 → 9)

| ID | 작업 | 수용 기준 | 크기 |
|---|---|---|---|
| W9-1 | MIGRATION 누락분을 채운다: closure `select` identity, 공개 enum case 추가, `EffectTask` typealias extension 범위, nested `Output` 암묵 포획, W3 변경 전부 | API 인벤토리의 모든 소비자 변경이 MIGRATION에 대응됨 | M |
| W9-2 | 문서-코드 불일치를 고친다: InnoFlow.swift:14~17의 Never 전용 문구, DocC와 MIGRATION의 "replay" 설명, `receiveOutput` `.zero` 문구 | doc-parity 통과 | S |
| W9-3 | DocC 튜토리얼 1편. 검색 피처로 Level 1→3을 따라가며 커버리지와 탐색까지 다룬다 | 튜토리얼 코드를 펜스 컴파일 게이트에 등록 | L |
| W9-4 | 성능 문서: 방법론과 TCA 대비 결과표를 싣고 FRAMEWORK_COMPARISON.md를 갱신한다 | W1-0 측정값과 일치 | S |
| W9-5 | README 4개 언어, RELEASE_NOTES, CHANGELOG(날짜), SECURITY 지원표, API_BREAKAGE를 재생성한다 | release-sync, doc-parity, 펜스 원장 통과 | M |

## 6. 비싼 결정과 대안 (태그 전에 확정)

| ID | 결정 | 추천 | 가장 강한 대안 | 틀렸을 때 비용 | 되돌리기 |
|---|---|---|---|---|---|
| D-1 | DispatchID 표현 | 프로세스 단조 `UInt64`로 바꾸고 `init(rawValue:)`를 비공개로 한다 | UUID 유지(프로세스 간 상관에 유리) | 6.x 내내 send마다 RNG 비용이 들거나 표현이 고정됨 | 7.0에서만 |
| D-2 | `EffectAdmission` 종료 상태 | `.cancelledBeforeStart`와 `.superseded`를 추가해 수명주기를 완결하고, "case 추가는 메이저에서만"을 정책으로 명문화한다 | struct 기반 확장형 kind | 6.x에서 상태를 표현할 수 없음 | 7.0에서만 |
| D-3 | `DispatchDiagnosticKind` 확장성 | enum을 유지하고, 필요한 case를 지금 추가하고, 추가는 메이저에서만 한다고 문서화한다 | struct + 정적 상수 | 진단 확장 때마다 breaking | 7.0에서만 |
| D-4 | `.serial(maxPending:)` 타입 | `UInt`로 바꾸고 `.invalidCapacity`를 없앤다. 음수는 컴파일 타임에 막힌다(A축). 계약 12를 수정해야 한다 | `Int` 유지(현행 계약) | 런타임 거절 경로가 남음 | 7.0에서만 |
| D-5 | FlowScope 생성 방식 | `init`을 비공개로 하고 `withFlowScope`만 남겨 렉시컬 소유를 타입으로 강제한다. 지금 직접 생성하는 곳은 테스트뿐이다. 계약 13을 수정해야 한다 | 현행 + 문서화 | 소유 규약 위반이 가능함 | 7.0에서만 |
| D-6 | `TestStore.send` 반환 타입 | `@discardableResult` `TestStoreDispatch` | 별도 API(`sendTracked`) 추가 | API가 둘로 나뉘거나 계약 8을 테스트로 검증할 수 없음 | 7.0에서만 |
| D-7 | `.off` 모드 `receiveOutput` | `receive`처럼 중간 action을 reduce | 현행 유지 + 문서화 | 출시 후 바꾸면 기존 테스트가 깨짐 | 7.0에서만 |
| D-8 | `TestStoreScenario.seed` | W5-2 탐색의 재현 키로 의미를 부여 | 제거 | 동작 없는 공개 필드가 남음 | 7.0에서만 |
| D-9 | 시나리오 `advance` 기본값 | `onceSleepersReach`를 필수로 만들어 결정적으로 대기 | 기본값 1 | yield 기반 대기로 flaky 시나리오가 생김 | 7.0에서만 |
| D-10 | alert/dialog 제목 타입 | SwiftUI와 같은 3종 오버로드 | `Text`만 | 지역화 불가가 고정됨 | 7.0에서만 |
| D-11 | 테스트 보고 파라미터 | `fileID`/`filePath`/`line`/`column` | 현행 `#file`/`#line` | 실패 위치가 부정확함 | 7.0에서만 |
| D-12 | effect operation 격리 | 클로저 타입에 `@concurrent` 명시 | 미명시(현 Swift 6 의미에 의존) | 언어 기본값이 바뀌면 effect가 MainActor로 끌려올 위험 | 7.0에서만 |
| D-13 | 레거시 런타임 검증 경로 | (A) W0-1이 성공하면 `macos-26`/26.6으로 이동 | (B) 핀 버전 변경(소유자 정책 결정) / (C) `macos-15`의 사전 설치 런타임 + Swift 6.3 툴체인(U-1에 의존, 가장 복잡) | 릴리스가 계속 막힘 | 정책 파일로 언제든 |
| D-14 | Inspector 제공 형태 | 별도 product `InnoFlowInspector` | InnoFlowSwiftUI에 포함, 또는 별도 레포 | 코어와 SwiftUI 모듈 비대화 | 마이너에서 추가는 가능, 제거는 7.0 |
| D-15 | nested `Output` 이름의 암묵 포획 | 문서화하고 진단 메시지에 명시 | opt-out marker 추가 | 무관한 `Output` 타입을 가진 5.x 피처가 혼란 | 마이너에서 marker 추가 가능 |

## 7. 비기능·운영 계약

| 영역 | 기준선 (2026-10-03) | 목표 | 측정 방법 |
|---|---|---|---|
| S1 send 1회 | 5.33µs | ≤ 0.50µs | W1-0 하네스, 7회 중앙값, Apple silicon / macOS 26 / Swift 6.4 `-c release`, 관찰자 없음 |
| S2 send + 동기 후속 10회 | 54.2µs | ≤ 6.0µs | 같음 |
| S3 1,000행 스코프 갱신, S4 select 100개 | W1-0에서 측정 | 2배 이상 개선하고 TCA 대응 시나리오 이하 | 같음 + Comparison 패키지 |
| 관찰 의미 | 현행 | 알림 횟수·순서 동일 | W1-1 신규 테스트 |
| 테스트 결정성 | 고정 sleep 다수 | 고정 sleep 0건(예외 목록화) | grep gate + 리뷰 |
| 동시성 위생 | unsafe escape 0건 | 0건 유지 | W8-3 gate |
| 진단 | bounded·payload-free, D1 누수 있음 | 누수 0, ring buffer | DispatchDiagnosticsTests 확장 |
| 이행 | Fix-It 없음 | Fix-It + codemod로 V5 픽스처 수동 수정 0건 | CI job |
| 릴리스 | Preflight 성공 0회 | 동결 SHA에서 32/32 | Release Preflight run ID |

## 8. 일정, 통합, 릴리스

### 8.1 마일스톤 (가정: 에이전트 작업 흐름 3개 병렬, 소유자 리뷰 하루 1시간 이상, Preflight 재실행 1회 이하)

| 마일스톤 | 기간 | 산출물 | 종료 조건 |
|---|---|---|---|
| M0 결정·진단 | 10/5~10/9 | D-1~D-15 결정, W0-1 진단, W1-0 기준선, 후보 C1~C3와 매크로 후보 재현 | §9의 열린 결정이 모두 닫힘 |
| M1 기반 | 10/12~10/23 | W0-2·W0-4·W0-5·W0-6, W1-1~W1-7, W2 전체 | 시험 Preflight #1이 32/32, S1 ≤ 1.0µs |
| M2 API·이행·따라잡기 | 10/19~10/30 | W3 구현, W6, W4 | 이행 소비자 CI 통과, API 인벤토리 초안 |
| M3 차별 기능 | 10/26~11/13 | W5, W7, W8 | 샘플에서 커버리지·탐색·원장·Inspector 동작, S1 ≤ 0.5µs |
| M4 문서·통합 검증 | 11/9~11/20 | W9, API 인벤토리 최종 분류, 성능 재측정, 시험 Preflight #2 | 모든 게이트 green, §11 증거 수집 |
| M5 동결·릴리스 | 11/23~11/27 | 후보 SHA 동결 → main CI → Release Preflight → 태그 승인 → producer → verify-only Release Gate → 공개 승인 | RELEASING.md 19~21단계 |

**태그 목표는 2026-11-27 ± 1주**다. 크리티컬 패스는 둘이다.

1. **W0.** M1 안에 시험 Preflight #1을 통과하지 못하면 기능 작업과 무관하게 릴리스가 막힌다.
2. **D-1~D-15 결정.** 결정이 늦어지면 W4·W6·W7이 시작하지 못한다.

### 8.2 PR 전략

- 워크스트림 항목 하나를 PR 하나로 만든다. 계약 변경 PR은 CLAUDE.md, 테스트, principle gate, CI를 함께 바꾼다.
- 성능 PR에는 바꾸기 전후 벤치마크 결과를 PR 본문에 붙인다.
- 공개 API PR은 API 인벤토리와 MIGRATION 변경을 같은 PR에 담는다.

### 8.3 동결과 검증

- M4가 끝날 때 후보 SHA를 한 번만 동결한다. 동결 뒤 바꾸면 새 SHA와 새 Preflight가 필요하다.
- 시험 Preflight 두 번(#1, #2)은 후보 증거가 아니다. 인프라 결함을 미리 찾기 위한 것이다.

### 8.4 안전 밸브 (소유자 승인 시에만)

기본값은 전부 6.0.0에 포함하는 것이다. M4가 1주 넘게 밀리면 아래 항목만 6.0.x/6.1로
옮길지 소유자가 결정한다. 이 항목들은 공개 API가 6.0에서 이미 확정됐고, 나중에 추가해도
breaking이 아닌 것들이다.

- W7-5 Inspector(새 product 추가는 마이너에서도 가능)
- W9-3 튜토리얼
- W1-8 선택적 inlinable
- W5-4 고급 문서

D-1~D-15와 W4-2, W4-3, W8-1처럼 API 형태를 정하는 항목은 옮길 수 없다.

### 8.5 롤백과 복구

- 태그 전: 항목별 PR revert로 되돌린다. 공개 API 결정을 되돌리면 MIGRATION과 인벤토리도 함께 되돌린다.
- 태그 후: 회귀는 6.0.x 패치로 고친다. 태그는 불변이다(release-tags 룰셋).

### 8.6 정리 작업 (태그 이후)

- 임시 진단 워크플로(W0-1)를 삭제한다.
- 릴리스 스크립트(약 18.7k줄)를 줄인다. 언어를 통일하고 중복을 없앤다. 패키지 내용과 무관하다.
- 공개 직후 `STABLE_VERSION`을 6.0.0으로 승격한다(RELEASING.md 규칙 그대로).

## 9. 열린 이슈

| 이슈 | 선택지·부족한 증거 | 담당 | 다음 단계 | 막는 것 |
|---|---|---|---|---|
| D-1~D-15 결정 | §6 | 소유자 | M0 결정 회의 | W3, W4, W6, W7 |
| 레거시 런타임 경로 | W0-1 결과, U-1 | 소유자 + 구현 담당 | 진단 워크플로 실행 | W0-2, 릴리스 |
| XCTest 보고 동작 | U-2 | 구현 담당 | W4-3 첫 작업으로 픽스처 작성 | W4-3 |
| `@concurrent` 호환성 | U-3 | 구현 담당 | W8-1 픽스처 | D-12 |
| 리뷰 처리량 | A-4 | 소유자 | 매주 점검 | 일정 |

## 10. 해결된 이슈

| ID | 원래 질문 | 결정과 근거 | 결정자·날짜 | 재확인 조건 |
|---|---|---|---|---|
| R-1 | 단계별(6.0 → 6.1 → 6.2)로 나눌지, 6.0.0 한 번에 포함할지 | 6.0.0 한 번에 포함한다. 이행이 한 번으로 끝나고, 되돌릴 수 없는 API 결정을 메이저 창 하나에서 일관되게 내릴 수 있다. 그 대가로 출시일이 약 8주 늦어진다 | 사용자, 2026-10-03 | M4가 1주 넘게 밀리면 §8.4 안전 밸브 논의 |

## 11. 추적성

| 축 | 요구 | 항목 | 증거 | 목표 점수 | 상태 |
|---|---|---|---|---:|---|
| F 성능 | S1 ≤ 0.5µs, S2 ≤ 6µs, S3·S4 2배 이상 | W1-0~W1-8 | 하네스 결과, 프로파일, TCA 비교표 | 9 | 계획 |
| D 테스트 | 따라잡기 + 고유 기능 3종 | W4, W5, D-6~D-9, D-11 | 회귀 테스트, 픽스처, 샘플 | 10 | 계획 |
| E DX | Fix-It, codemod, 계층 문서, 헬퍼, 수명 modifier, Inspector | W6, W7, D-10, D-14 | 매크로 스냅샷, 이행 CI, 문서 게이트 | 8.5 | 계획 |
| G 문서·릴리스 | Preflight 32/32, MIGRATION 완결, 튜토리얼 | W0, W9 | run ID, doc-parity, 펜스 원장 | 9 | 계획 |
| C 효과·수명 | 리뷰 결함 0, admission 수명주기 완결 | W2, D-2, D-4, D-5 | 재현 프로브 → 회귀 테스트 | 9.5 | 계획 |
| A 타입 계약 | 컴파일 타임 계약 확대 | D-4, M1, M2, W6-1 | compile contract 테스트 | 9.5 | 계획 |
| B 동시성 | 격리 명시, unsafe escape 0건 | W8, D-12 | 픽스처, gate | 9 | 계획 |

점수는 §2 루브릭으로 M4가 끝날 때 다시 매긴다. 증거 없는 점수 상향은 하지 않는다.

## 12. 리뷰 게이트

- [ ] 문서 깊이(expanded)가 위험과 조정 비용에 비례한다.
- [ ] 첫 두 절만 읽어도 목적과 범위를 이해할 수 있다.
- [ ] 사실, 가정, 미확인이 분리돼 있다.
- [ ] 되돌리기 비싼 결정과 대안이 명시돼 있다.
- [ ] 비기능 목표에 측정 경로가 있다.
- [ ] 롤아웃, 롤백, 정리가 정의돼 있다.
- [ ] 열린 이슈마다 담당과 다음 단계가 있다.
- [ ] 요구, 결정, 항목, 증거가 추적된다.
- [ ] 지명된 리뷰어가 리뷰를 마쳤다(Reviewed 전).
- [ ] 결정권자가 명시적으로 승인했다(Approved 전).

## 13. 참고

- 2026-10-03 평가 세션: 로컬 테스트, 벤치마크(InnoFlow 5.1.1·6.0 RC·패치본·TCA 1.26.2), `sample` 프로파일, 리뷰 결함 재현 프로브. 스크래치 사본에서만 실행했고 레포는 수정하지 않았다.
- GitHub Actions run 36650422297, 36703581250 (Release Preflight 실패 로그), 37114011835, 37120540957 (2026-10-03 진행 중)
- actions/runner-images: `images/macos/xcode-27-arm64-Readme.md`(태그 xcode-27-arm64/20260921.0210), `macos-26-arm64-Readme.md`, `macos-15-arm64-Readme.md`(2026-10-03 main)
- TCA: https://github.com/pointfreeco/swift-composable-architecture/releases , Performance 문서, https://www.pointfree.co/blog/posts/206-beta-preview-composablearchitecture-2-0
- 저장소 내부: CLAUDE.md 계약 1~18, RELEASING.md, docs/API_BREAKAGE_6_0.md, docs/PERFORMANCE_BASELINES.md, docs/adr/
