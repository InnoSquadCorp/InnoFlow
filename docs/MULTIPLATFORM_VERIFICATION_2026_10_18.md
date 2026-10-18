# Kotlin/Android · TypeScript/React 1.0 검증 계획과 증거 원장

> 역사 기록: 아래는 수정 전 검증 결과다. 후속 수정 승인으로 F1/F2/F3와 API26 probe를
> 수정한 [새 63행 재검증 원장](MULTIPLATFORM_FIX_VERIFICATION_2026_10_18.md)이 현재 판정을
> 대체한다. 아래 FAIL·로그·snapshot과 `verification/2026-10-18/`는 당시 증거로 보존한다.

검증일: 2026-10-18 (Asia/Seoul). 상태: **고정 범위 검증 완료 / 1.0 승인 보류**.
이 문서는 검증을 시작하기 전에 범위와 종료 조건을 고정한 원장이며,
기존 [readiness 요약](MULTIPLATFORM_1_0_READINESS.md)의 포괄적인 통과 판정보다 우선한다.
테스트 통과, 검토 완료, 결함 수정 완료, 공개 출시 승인은 서로 다른 판정이다.

## 1. 기준선과 변경 권한

- 작업 경로: `InnoFlow-worktrees/multiplatform/InnoFlow`.
- 브랜치: `codex/multiplatform-flow`.
- HEAD 및 로컬 `origin/main`: `0a7e685d3749b3dc28c6d5e56b932c9ad7fc0b11`.
  여기에 기존 미커밋 multiplatform 구현을 더한 입력을 검증한다. SHA만으로
  미커밋 입력을 식별할 수 없으므로 파일 해시 목록도 함께 보존한다.
- 시작 시점: 2026-10-18 06:03:55 UTC. 추적/비추적 비무시 파일 786개,
  dirty 경로 128개. 시작 파일 해시 목록의 SHA-256:
  `66d6d029390500b7f6eb6230179f43d6e5c3cc0341b39bb325bb896540abf790`.
- 시작 상태/패치/파일별 해시와 새 실행 로그:
  `/tmp/innoflow-verification-20261018.vkS7JQI8`.
- 이번 요청은 **문서화와 검증**을 허용한다. production 코드, 기존 테스트,
  package/lock/ABI golden/CI의 수정, commit, push, 외부 메시지, tag, 배포는 하지 않는다.
  진단용 재현기는 production source/test 밖의 별도 임시 프로젝트에서 실행한다.
- Swift의 `Sources`, `Tests`, `Examples`, `Benchmarks`, `Tools`, `skills`,
  `Package.swift`, `Package.resolved`, `.swift-format`, `STABLE_VERSION`,
  `AGENTS.md`, `README.md`, Swift CI와 principle-gates 라이브러리는 main과
  무변경이어야 한다. 원래 Swift checkout에는 접근/수정하지 않는다.
- 종료 시 문서의 명시적 변경만 허용 목록으로 제외하고 모든 기존 입력의
  바이트 해시를 비교한다. 외부/다른 작업의 변경이 감지되면 해당 증거를 재평가한다.

## 2. 제품·공개 계약·소비자 목록

| 대상 | 공개/운영 표면 | 검증 소비자와 한계 |
| --- | --- | --- |
| Kotlin `inno-flow-core` | `FlowFeature`, `Reducer`, `Transition`, `Effect`/`EffectId`/`EffectScope`, composition, `FlowStore`, `FlowTask`, instrumentation/queue error | JVM sample/외부 Maven 프로젝트. Kotlin/JVM이며 KMP 전체를 약속하지 않음 |
| Kotlin `inno-flow-ksp` | `@InnoFlow`, processor provider, 생성 factory/타입/가시성/diagnostic | 독립 processor 소비자, 성공/실패 컴파일 fixture, 수동 생성 대조군 |
| Kotlin `inno-flow-testing` | `TestStore` send/state/action/output/finish/close | sample의 결정론적 테스트 + 독립 진단 |
| Kotlin `inno-flow-android` | `ViewModelFlowStore` 소유권/정리 | ViewModel 단위 테스트, 실제 AAR 소비자 |
| Kotlin `inno-flow-compose` | lifecycle-aware state/output collection, 최신 handler | Compose instrumentation, API dump, 외부 Android 앱 |
| Kotlin samples/fixtures | KSP/JVM sample, Android Counter, SavedStateHandle, JVM/AAR 독립 소비자 | 소스 연결이 아닌 로컬 Maven 산출물 설치; device 복원은 별도 증거 |
| TypeScript `@innosquad/inno-flow` | `defineFlow`, `transition`, effect/model/composition, store/task, error/instrumentation | Node unit/독립 진단 + 실제 npm tarball |
| TypeScript `@innosquad/inno-flow-react` | state/selector hook, typed context/provider | React 18.2/19.2, SSR/hydration, StrictMode, store 교체, 실제 Chromium |
| TypeScript `@innosquad/inno-flow-testing` | 구조 비교/custom comparator/trace assertion | 단위/독립 진단 + tarball 타입 소비자 |
| 공유 계약 | `contracts/SEMANTICS.md`, counter-v1/runtime-v1 JSON | 두 새 runtime의 동일 fixture. Swift 6.x 전체 기능 동등성 검증 아님 |
| 패키징/도구체인 | 5개 Kotlin ABI, Gradle/Maven/POM/AAR, 3개 npm exports/types/maps/license | 명시된 최소/유지 라인, 독립 consumer. registry 설치와 분리 |
| CI/release | multiplatform CI, kotlin/npm release, SHA pin/권한/timeout/정확한 SHA 증거 | 정적/negative-control 검증과 실제 hosted/publish 결과를 분리 |

지원 입력은 Kotlin 2.4.10 / KSP 2.3.11 / AGP 9.3.1 / Gradle 9.7.0,
JVM core Java 11 bytecode / Android JDK 17, Android minSdk 23/compileSdk 37,
TypeScript 5.9.3, Node 20.19.0 및 22.23.3, npm 11.19.0,
React 18.2.0 및 19.2.8이다. 설치된 host Node 26.12.0의 성공으로 이 행렬을
대체하지 않는다. 실제 실행 버전/산출물/캐시 재사용은 실행 원장에 기록한다.

## 3. 검증 방식·제외·종료 조건

각 행은 source → 공개 계약 → existing regression → 독립 소비자/필요한
반례를 연결한다. 정상(N), 실패(F), 취소(C), 동시성(Q), 재시도·복원(R),
자원 한계(L), 관측(O), 보안·신뢰 경계(S)를 적용 가능한 곳에 표시한다.
비적용 항목도 아래 제외 사유로 설명한다. 전체 조합을 수학적으로 증명한
것처럼 표현하지 않으며, 실행한 입력/스케줄/환경의 한계를 유지한다.

상태는 `PENDING`(미완료), `PASS`(요구 후조건 충족), `FAIL`(반례 확인),
`LIMIT`(명시적 미검증 경계), `N/A`(설계상 비적용)이다. 증거 성격은
`fresh`(이번 요청), `reused`(동일 입력의 이전 실행), `static`(소스/설정 대조)로
따로 적는다. 의도적 실패 fixture의 exit 1은 탐지 대조군 성공일 수 있으나,
실제 제품 반례가 exit 1인 경우 제품 행을 PASS로 바꾸지 않는다.

종료 조건:

1. 아래 고정 행렬의 모든 행을 증거 또는 구체적 한계로 닫는다.
2. 안전하게 실행 가능한 로컬 검증은 수행한다. 알려진 세 결함도 정상
   대조군과 다시 연결하고, 미검증 경로/fixture 문제와 중복 계산하지 않는다.
3. 신규 의심은 실제 구현 재현 + 정상 대조군 전에는 확정 결함으로 올리지 않는다.
4. 결함, 후보, 선택 개선, 환경 실패, 외부 gate를 분리한다.
5. 원장·요약·재현 명령을 일치시키고 Swift/기존 입력 보존을 증명한다.
6. 실패/외부 gate가 남으면 **검증 작업 종료**와 **출시 보류**를 동시에 기록한다.

제외/명시적 한계:

- Swift 기능 변경/전체 Swift release preflight/OS runtime 설치는 제외한다.
  Swift는 main 바이트 보존만 검증하며 CI-only 정책을 지킨다.
- 실제 서비스 transport/auth/navigation/DI, 앱의 retry/backoff 정책/자동 영속화,
  React Native 장치, KMP Native/JS, CJS는 이 1.0 API의 약속이 아니다.
  실패 후 독립 dispatch 재시도와 Android sample의 명시적 복원은 범위 안이다.
- state는 immutable snapshot이라는 앱 책임을 전제로 한다. mutable 객체의
  deep-copy/실패 rollback, 비협조 I/O 강제 중단, 전역 effect 수 제한은 제공하지 않는다.
- 실제 registry publication/credential 검증, tag/main push CI, physical device,
  설치되지 않은 browser/OS/toolchain의 실행 결과를 추정하지 않는다.
- 보안 범위는 dependency advisory, package 포함 파일, CI 권한/신뢰·비밀 노출
  경계의 제한된 검증이다. 별도의 exhaustive security audit/침투 테스트는 아니다.
- 장시간 soak, heap/CPU benchmark, 모든 interleaving 및 모든 compiler 타입 조합의
  완전 탐색은 약속하지 않는다. 실행된 bounded stress와 구체적 반례만 보고한다.

## 4. 고정 cross-feature 검증 행렬

아래 63개 행은 깊은 검증을 시작하기 전에 고정했다. 발견 사항으로 행을
확장해야 하면 추가 사유와 시점을 남기며 기존 누락을 뒤늦게 숨기지 않는다.

| ID | 검증 후조건 / 위험 축 | 검증 경로 | 상태 · 증거 |
| --- | --- | --- | --- |
| B01 | 기준선/dirty/Swift/기존 입력 보존 (S) | 시작·종료 파일 해시, main diff | PASS · fresh: §7.8, 문서만 변경 |
| B02 | 두 runtime의 portable contract 일치 (N,F,C,R,O) | counter/runtime 공통 fixture | PASS · fresh: §7.1/2, counter 및 runtime 6개 시나리오 |
| B03 | 모든 모듈·공개 API·지원 환경 inventory (S) | source/export/manifest/ABI/doc 대조 | PASS · static+fresh: §2/7.5, 5 Kotlin + 3 npm 전부 대조 |
| B04 | immutable state/비협조 작업/영속화 경계 일치 (F,C,R,L) | 계약 문서·구현·반례 구분 | PASS · static+fresh: SEMANTICS, late-emission tests, §7.3/4 |
| K01 | constructor 인자 거부가 parent job을 누수하지 않음 (F,L) | capacity 1 vs 0 독립 Job probe | FAIL · fresh: F1, children 0/join true vs 1/false |
| K02 | 최신 state 기준 FIFO·다중 producer 직렬화 (N,Q) | JVM regression/8 producers | PASS · fresh: ReleaseContractsTest concurrentProducersSerializeAgainstLatestState |
| K03 | root+descendant effect/action 완료 소유권 (N,Q) | sample/독립 effect mapping probe | PASS · fresh: CounterFeatureTest + runtime-probes.log K03/K11 |
| K04 | reducer 실패가 다른 root를 오염시키지 않음 (F,R) | 실패/후속 성공 dispatch | PASS · fresh: FlowRuntimeTest reducerFailureRejectsOnlyItsDispatchTreeAndStoreRemainsUsable |
| K05 | effect 실패/취소 의미와 독립 재시도 (F,C,R,O) | exception/cancel/timeout 대조 | PASS · fresh: ReleaseContractsTest effectFailureIsObservedAndRetryRemainsUsable + kotlin-native-result.log; timeout 보완은 O1 |
| K06 | root 취소·close·시작 전/late emission 차단 (C,Q) | queued/active/uncooperative regression | PASS · fresh: cancelledAdmission/closeReleasesQueuedDispatches/cancelledIdSuppressesUncooperativeLateEmission |
| K07 | ID latest/all matching 취소, 다른 ID 독립 (C,Q) | ID regression + mapped ID probe | PASS · fresh: cancellationId tests + runtime-probes.log K07 |
| K08 | bounded admission/backpressure/회복 (L,Q,R) | overflow/10,000 actions/stress | PASS · fresh: boundedRootAdmission/effectProducerSuspends + 4,000 concurrent actions |
| K09 | output live order/no replay/drop 관측/close 종료 (N,L,O,C) | collector regression + probe | PASS · fresh: liveOutput/slowLiveOutput/outputCollectorsComplete + nullable/no-replay probe |
| K10 | instrumentation 오류 격리/metric/페이로드 경계 (F,O,S) | throw observer/queue stats + static | PASS · fresh+static: instrumentationFailure/actionQueue tests; payload-free 아님, §7.6 |
| K11 | combine/scope/transition/map 조합 순서·필터 (N,F,C) | 독립 실제 runtime composition probe | PASS · fresh: runtime-probes.log K03/K11; unmatched/zero reducer 대조 포함 |
| K12 | task await/cancel idempotency/owner 취소 (C,Q) | 다중 waiter/취소 waiter/owner probe | PASS · fresh: runtime-probes.log K12 + ownerScopeCancellationFinishesDispatchTasks |
| K13 | TestStore action/output/state/finish 및 실패 탐지 (N,F) | sample + 독립 negative assertions | PASS · fresh: sample trace + runtime-probes.log K13, 잘못된 기대값 3종 거부 |
| G01 | public/internal/object/default/escaped factory compile (N) | 독립 published KSP fixture | PASS · fresh: full-local.log positive; nullable Map/List, star projection 포함 |
| G02 | private/nested/generic/abstract/indirect 진단 (F,S) | 5개 expected-failure fixture | PASS · fresh: full-local.log 5개 지정 diagnostic 확인 |
| G03 | 지원 feature의 state/action/output 타입 rendering (N,F) | plain/function/suspend/generic-inner compile | FAIL · fresh: F2; plain/function/suspend/manual exit 0, inner exit 1 |
| G04 | compiler-plugin-free fallback 및 alias 경계 (N,F) | explicit FlowStore 대조/진단 | PASS · fresh+static: ksp-innerManual exit 0; alias는 direct-spelling 진단, O2 |
| A01 | ViewModel clear가 소유 Store만 닫음 (C,Q) | Android module unit | PASS · fresh+static: viewModelStoreClearClosesOwnedFlowStore; addCloseable/viewModelScope의 소유권 대조 |
| A02 | Compose lifecycle state/output 최신 handler (N,C,O) | 2개 instrumentation/API별 증거 | PASS · fresh: API26/34 각각 2개; state pause/resume, 최신 handler, background output 미재생 |
| A03 | recreation/background-resume 상태 유지 (N,R) | sample instrumentation | PASS · fresh: API26/34 각각 stateSurvivesRecreationAndBackgroundResume 1개 |
| A04 | API 34 실제 process kill 뒤 PID/visible state 복원 (R) | serial별 restoration probe | PASS · fresh: PID 6776→7605, Count 2, screenshot/XML 보존 |
| A05 | API 26 process 복원 증거/ANR 구분 (R,F) | available AVD/환경 확인 후 isolated probe | LIMIT · fresh: 자동 am-kill probe 실패; stopped/동일 UID PID 검증 후 별도 process-kill 복원은 4510→5061, Count 4 PASS (§7.4) |
| A06 | minSdk API 23/current-line 35 runtime (N,R,C) | hosted matrix와 로컬 환경 가용성 | LIMIT · static: 로컬 image/AVD 없음, 아직 unpushed; API26/34로 대체하지 않음 |
| A07 | debug/release 앱·lint·SavedState 단위 검증 (N,F) | Gradle build/test/lint | PASS · fresh: full local build/lint + --rerun-tasks SavedState 1개 |
| T01 | positive finite integer capacity 검증 (F,L) | 기존 invalid-capacity regression | PASS · fresh: rejects invalid capacities, Node20/22 |
| T02 | FIFO/reentrant send, 비재귀 drain (N,Q,L) | 20,000 chain/2,000 burst | PASS · fresh: drains a long reentrant chain / lossless FIFO metrics, Node20/22 |
| T03 | root+descendant 완료와 mapping 소유권 (N,Q) | existing + 독립 composition | PASS · fresh: waits for descendant actions + typescript-probes Node20/22 T03/T10 |
| T04 | reducer/effect 실패 격리와 재시도 (F,R) | 실패/후속 성공 regression | PASS · fresh: reducer/effect failure tests + sibling abort/independent retry probe |
| T05 | prestart/root/close 취소 및 late emission 차단 (C,Q) | regression + waiter probe | PASS · fresh: release-contract tests + T05/T11 external probe |
| T06 | ID latest/all matching 및 다른 ID 독립 (C,Q) | regression + mapped ID probe | PASS · fresh: same-ID/latest tests + T06/T10 signal/ID mapping probe |
| T07 | bounded overflow·회복/queue compaction (L,R) | overflow/large burst/metrics | PASS · fresh: reentrant overflow recovery, 20,000 chain; static splice/drain cleanup |
| T08 | output no replay/unsubscribe/close·undefined (N,C,O) | regression + 독립 output probe | PASS · fresh: typed output test + T08/T09 undefined/no-replay/unsubscribe/close probe |
| T09 | state/output listener 오류 격리·구독 정리 (F,O,S) | 독립 throw/unsubscribe/close probe | PASS · fresh: T08/T09, observerFailed 자체 throw도 격리 |
| T10 | combine/scope order/filter/Effect.map/signal (N,F,C) | 독립 실제 runtime composition | PASS · fresh: T03/T10 및 T06/T10, Node20/22 |
| T11 | task finished await/cancel/multiwait/abort fanout (C,Q,L) | 독립 task probe/기존 burst | PASS · fresh: T05/T11 + 2,000 effects; repeated wait/cancel와 late user-code 실행 구분 |
| T12 | TestStore 구조/Map/Set/Date/undefined/custom 및 negative (N,F) | 4개 unit + 독립 실패 탐지 | PASS · fresh: 4개 unit + wrong state/action/output 및 cyclic custom comparator probe |
| R01 | SSR initial snapshot → hydration live state (N,R) | React unit + tarball SSR/browser | PASS · fresh: hydration unit + 4개 exact browser, SSR 7→client 8 |
| R02 | selector/equality 교체·undefined·불필요 render (N,Q) | selector unit/정적 hook 대조 | PASS · fresh+static: React selector 3개 unit, render-local memo/commit ref 대조 |
| R03 | StrictMode mount/unmount 구독 무누수 (C,Q) | React unit | PASS · fresh: releases StrictMode subscriptions on unmount, store replacement |
| R04 | typed provider/store 교체/미제공 오류 (N,F) | React unit + 독립 boundary probe | PASS · fresh: provider/store replacement units + missing Provider SSR 오류 대조 |
| R05 | tarball browser interaction·console·hydration (N,F) | 실제 Chromium/정확한 DOM 후조건 | PASS · fresh: 4개 exact-* log, Count 7/8/9/8, console/recoverable errors 0 |
| R06 | 잘못된 SSR/UI 수치가 gate에서 거부됨 (F,S) | 정상 vs count×10 mutant | FAIL · fresh: F3, 기존 gate exit 0; 독립 exact probe는 네 값 오류로 exit 1 |
| R07 | Node20/22 × React18/19 소비자 행렬 (N) | 독립 설치/typecheck/SSR/build/browser | PASS · fresh: 네 tarball 소비자 + 별도 정확한 SSR/DOM 검사 (§7.2) |
| P01 | core/testing/KSP ABI baseline 일치 (S) | 3개 JVM ABI gate | PASS · fresh: full-local.log checkKotlinAbi 3개 실행, 기존 compiler outputs 일부 재사용 |
| P02 | Android/Compose 실제 AAR ABI·negative golden (S,F) | 2개 AAR gate/selftest | PASS · fresh: 2개 실제 AAR comparison + 잘못된 임시 golden 거부 |
| P03 | Maven JVM consumer 무 project substitution (N,S) | independent refresh-dependencies test | PASS · fresh: refresh 후 --rerun-tasks test 1개, 6 tasks 실행 |
| P04 | Maven AAR 앱 consumer test/release build (N,S) | independent Android fixture | PASS · fresh: test 1개 + release APK, 74 tasks 실행 |
| P05 | npm exports/types/maps/license/불필요 파일 제외 (N,S) | pack/publint/ATTW/maps/consumer errors | PASS · fresh: 3개 package validation/타입 소비자; ESM-only, CJS 의도적 제외 |
| P06 | Node20/22 clean install+typecheck+28 regressions (N,F) | scoped exact Node/npm | PASS · fresh: 각 Node에서 ci + test, 5 files/28 tests, npm 11.19.0 |
| P07 | toolchain pin/checksum/bytecode/SDK/dependency 범위 (S) | wrapper/manifest/resolution/classfile | PASS · fresh+static: Java major 55/61, wrapper/distribution 진위 대조; legacy wrapper 보완은 O3 |
| C01 | workflow 구조/action pin/timeout/권한 (F,S) | canonical actionlint/정적 policy | PASS · fresh+static: actionlint 1.7.12, 18 workflows, pins/timeouts 성공 |
| C02 | 정확한 SHA·main-push CI 선행 증거/negative (F,S) | helper 10개 실패 대조군 | PASS · fresh: passing control + 10개 잘못된 CI evidence 거부 |
| C03 | untrusted PR/비밀·publish 분리 (S) | 3개 workflow source trust review | PASS · static: CI read-only, checkout credential 미보존; publish는 tag push+exact main CI로 제한 |
| C04 | dependency advisory scan 및 제한 명시 (S) | npm audit + JVM graph 검토 | PASS · fresh: npm audit 0; 5개 Kotlin 모듈의 Maven runtime 38개 OSV match 0, known-vulnerable control 6개 탐지 (§7.6) |
| C05 | package/runtime payload·secret 책임 경계 (S,O) | packed file list/instrumentation source | PASS · static+fresh: pack allowlist/maps/license; runtime 기본 전송/로그 없음, instrumentation payload redaction은 앱 책임 |
| C06 | 실제 hosted CI가 같은 candidate를 검증 (N,S) | 아직 unpushed인 입력의 evidence 유무 | LIMIT · static: 미커밋/비추적 구현이므로 HEAD의 과거 CI는 이 입력 증거가 아님 |
| C07 | 공개 registry 설치/권한/릴리스 완료 (N,S) | 실제 publish 후 remote-only consumer 필요 | LIMIT · not executed: publish/tag 승인 없음; 로컬 consumer를 registry 설치로 계산하지 않음 |
| X01 | Swift release/runtime 회귀 판정 제외 (N,C,R) | main parity만 수행, CI-only 정책 | N/A · 명시적 scope 제외; 바이트 보존 B01은 fresh 검증 |
| X02 | 비지원 platform/서비스/soak·보안감사 구분 (S,L) | 명시된 제외와 광고 계약 대조 | N/A · §3의 비지원 기능, 전체 보안/성능/미래 버전·모든 browser 조합 증명은 제외 |

## 5. 실행 순서와 증거 명명

1. B01/B03: 입력 동결, manifest/public surface, 기존 증거의 동일 입력 확인.
2. contract/static/CI gate 후 full local producer + JVM/AAR 독립 consumer.
3. Node 20.19.0/22.23.3 각각 clean install/test/pack,
   React 18.2.0/19.2.8 각각 독립 packed browser.
4. 기존 F1/F2/F3 정상/실패 대조와 기존 unit이 다루지 않는 composition,
   task waiter, observer 오류, TestStore 실패 탐지를 외부 probe로 검증.
5. device 환경/부하 확인. 이미 설치된 AVD 한 대씩만 사용하고, 타 작업의
   emulator/build/compiler는 중단하지 않는다. 실패는 app/fixture/system으로 분류한다.
6. manifest/hash/Swift parity 재검증, 모든 행 상태/한계와 readiness 동기화.

이전 증거 위치 (재사용 여부는 실행 원장에서 개별 판정):

- E0: `/var/folders/xx/clb9plsj0gs91v_nvvvxtscw0000gn/T/innoflow-1.0-final.KgjBAnzAv8`
  — 앞선 구현 검증의 전체 producer/consumer/Node/device 결과.
- E1: `/var/folders/xx/clb9plsj0gs91v_nvvvxtscw0000gn/T/innoflow-review-20261018.ElsbEsg76Z`
  — 앞선 읽기 전용 검토의 F1/F2/F3 대조 재현과 source 보존 결과.
- E2: `/tmp/innoflow-verification-20261018.vkS7JQI8`
  — 이번 문서화/검증의 시작 snapshot 및 실행 로그. 임시 로그는 영구 배포
  artifact가 아니므로 핵심 명령/관측/해시는 이 문서에도 남긴다.

## 6. 알려진 실패·후보·선택 개선

### 확정 결함: 제품 2건 + 검증 도구 1건 (모두 미수정)

| ID | 위치 / 영향 | 실제 구현 재현과 정상 대조군 | 수정 후 재개방할 검증 |
| --- | --- | --- | --- |
| F1 · P2 · K01 | `kotlin/inno-flow-core/src/main/kotlin/com/innosquad/innoflow/FlowStore.kt:45-49`. capacity 검사보다 먼저 `SupervisorJob(parent)`을 생성해 constructor 예외 뒤 회수할 Store가 없음. 부모 완료/종료를 붙잡음 | 같은 로컬 Maven core JAR에서 capacity 1은 children=0 / parentJoined=true. capacity 0은 IllegalArgumentException 뒤 children=1 / parentJoined=false. 명세 assertion 모드는 exit 1 | resource 생성 전 입력 검증 또는 실패 시 정리. 0/음수/무제한 값 거부 뒤 parent child 0과 join 완료, 정상 Store 생성/close 대조를 production regression에 통합한 다음 K01 재실행 |
| F2 · P2 · G03 | `kotlin/inno-flow-ksp/src/main/kotlin/com/innosquad/innoflow/ksp/InnoFlowProcessor.kt:140-156`. top-level 비generic feature가 `Outer<String>.Inner<Int>` state를 쓰면 generic owner와 inner 인자를 잘못 평탄화함 | `innerManual` explicit FlowStore compile exit 0. 같은 feature의 annotation/generated factory는 `Outer.Inner<Int, String>` 형태가 되어 compile exit 1. plain/function/suspend-function 대조는 전부 exit 0 | owner-aware type rendering 또는 지원하지 않는 state shape에 정확한 계약/diagnostic. generic-inner 성공 컴파일과 기존 nullable/nested/star/function/visibility fixture 회귀 검사 |
| F3 · P2 · R06 | `typescript/scripts/test-packed-consumer.mjs:53,55,57`, `typescript/consumer-fixture/smoke.mjs:11`. substring matching이 `Count: 80/90` 및 SSR 70을 8/9/7로 오인함. CI/릴리스 소비자 검증 신뢰도 문제 | 외부 복사본의 표시만 count×10으로 바꿈. package bytes는 현재 산출물과 동일. 기존 gate 정상/잘못된 복사본 모두 exit 0. 별도 exact probe는 정상 7/8/9/8 통과, 잘못된 70/80/90/80 네 값 모두 거부하고 exit 1 | 정확한 text/DOM assertion 및 의도적 잘못된 UI negative control을 정식 gate에 통합. 그 뒤 네 Node/React 소비자와 SSR/browser gate 재실행 |

재현 코드는 [진단 재현 자료](verification/2026-10-18/REPRODUCERS.md)에 남긴다.
위 결함은 새로운 생산 코드로 고친 것이 아니다. 기존 suite가 green이어도
이 세 행은 FAIL이며, 임시 exact browser probe 통과가 정식 gate 수정을 대신하지 않는다.

### 미해결 후보 / fixture·환경 결과

- A05: API26의 자동 process-restoration probe는 실제 PID 종료 조건에서
  실패했다. Activity는 `state=STOPPED`, `stopped=true`, `haveState=true`였고,
  sample process는 `previous`, oom adj 700 상태로 남았다. 이 실행의 screenshot은
  정상 launcher이며 ANR dialog나 sample crash를 관찰한 결과가 아니다.
  **원래 자동 probe는 실패로 유지**한다. 별도 same-UID process-kill 대조는
  새 PID/정확한 값 복원에 성공했다. API23/35의 동일 도구 이식성은 실제
  hosted 실행 전 미확정이며, 이 관찰을 API23/35 제품 결함으로 일반화하지 않는다.
- 신규 제품 후보를 재현 없이 확정 결함으로 승격한 항목은 없다. 모든
  Kotlin 타입/동시성 스케줄/장시간 부하를 완전 탐색했다는 의미는 아니다.
- 앞선 E0의 metaspace 부족/System UI ANR는 과거 환경 이력이다. 이번
  정상 회귀 결과와 섞지 않으며, 위 API26 PID 종료 실패와도 다른 현상이다.

### 선택 개선 (결함 수에 포함하지 않음)

- O1: Kotlin `withTimeout`의 `TimeoutCancellationException`은 native coroutine
  취소로 처리될 수 있다. 이번 probe의 uncancelled effect error는 task 실패와
  `dispatchFailed`를 만들었고, timeout/명시적 취소는 정상 완료, 이후 retry는
  state 1이었다. domain timeout을 실패로 만들려면 앱에서 명시적으로 변환해야
  한다. InnoFlow 결과 계약의 예제/회귀 문서를 보강할 수 있으나 이 동작을
  자체 runtime 결함으로 계산하지 않는다. [Kotlin 1.11 공식 계약](https://kotlinlang.org/api/kotlinx.coroutines/kotlinx-coroutines-core/kotlinx.coroutines/with-timeout.html).
- O2: FlowFeature supertype을 typealias로 직접 표기한 경우도 direct-implementation
  diagnostic을 받는다. 현재 processor의 의도적 direct-spelling 제한이며 수동
  생성 fallback은 가능하다. 지원/진단 문구를 더 명확히 하거나 alias 지원을
  별도 설계할 수 있다.
- O3: 실행 distribution은 checksum으로 고정한 Gradle 9.7.0이지만 wrapper JAR는
  공식 8.10–8.12.1 계열과 같은 `2db75c…`이다. 공식 9.7.0 wrapper의 `7a9ce7…`와
  다르다는 이유만으로 위변조로 판정하지 않았다. 기존 JAR는 공식 checksum
  목록에 일치하고 이전 wrapper로 새 Gradle 실행은 허용된다. 향후 wrapper
  파일을 한 버전으로 정렬하고 CI wrapper 진위 gate를 고정할 수 있다.
  [공식 checksum 목록](https://gradle.org/release-checksums/),
  [이전 wrapper 호환과 업그레이드 계약](https://docs.gradle.org/current/userguide/gradle_wrapper.html#sec:upgrading_wrapper).
- O4: 실제 검증한 exact Node/React 조합을 계속 유지하고 새 지원 라인 채택 시
  행렬을 다시 열어야 한다. `node >=20.19`, `react >=18.2 <20` 선언을 모든
  현재/미래 minor·patch·browser 조합의 실행 증거로 해석하지 않는다.

## 7. 실행 원장과 최종 판정

### 7.1 Kotlin/Android producer·소비자·공통 계약

아래 새 실행은 E2에 보존했다. 작업 디렉터리는 repo root다.
`JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home`,
`ANDROID_HOME=/Users/changwooson/Library/Android/sdk`를 명시했다.

```bash
npm exec --yes --package=node@22.23.3 --package=npm@11.19.0 -- ./scripts/test-multiplatform.sh
./kotlin/gradlew -p kotlin :sample:test :inno-flow-android:testDebugUnitTest :android-sample:testDebugUnitTest --rerun-tasks --console=plain
./kotlin/gradlew -p kotlin/consumer-fixture test --rerun-tasks --console=plain
./kotlin/gradlew -p kotlin/android-consumer-fixture testDebugUnitTest assembleRelease --rerun-tasks --console=plain
```

| 로그 | Exit / 실제 관측 | 증거 경계 |
| --- | --- | --- |
| `full-local.log` | 0; producer build/lint/5 ABI/local Maven, JVM/AAR consumer, KSP fixtures, AAR API negative controls, CI evidence helper, npm audit/test/pack/browser 모두 수행 | producer 260 tasks 중 23 실행/237 up-to-date. 성공은 F1/F2/F3 부재 증명 아님 |
| `kotlin-unit-fresh.log` | 0; 74 tasks 모두 재실행, sample 24 + ViewModel 1 + SavedState 1 = 26 tests | XML failures/errors/skipped 0; 06:09:58–06:10:01 UTC 새 실행 |
| `jvm-consumer-fresh.log` | 0; 6 tasks 재실행, published-artifact test 1개 | source/project dependency substitution 없이 core/testing/KSP 로컬 Maven 소비 |
| `aar-consumer-fresh.log` | 0; 74 tasks 재실행, unit 1개 + release APK | Android/Compose 실제 AAR 소비; 기기 실행/registry 설치 증거는 별도 |

JVM/Android 단위 suite의 실행 inventory는 CounterFeatureTest 3,
FlowRuntimeTest 9, ReleaseContractsTest 11, RuntimeConformanceTest 1,
ViewModelFlowStoreTest 1, SavedStateTest 1, 두 독립 consumer 각 1이다.
총 **28개 단위/소비자 tests**, device tests와 독립 진단 group은 이 수에 더하지 않는다.
공통 runtime JSON의 6개 시나리오는 한 테스트 안에서 각각 실행되므로
시나리오 수를 별도 JUnit test 수처럼 중복 계산하지 않는다.

KSP positive fixture는 public class/internal object/default-package object/
escaped package·object, nested nullable generic와 star projection을 포함한다.
private/generic-feature/nested-feature/indirect/abstract 5개는 지정 diagnostic과
nonzero exit를 모두 요구했다. 추가 `plain`, `function`, `suspend`, `innerManual`
각 compile exit 0, `inner` exit 1(F2), `alias` exit 1(지원 제한)을
`ksp-<case>.log`에 따로 보존했다. 의도된 negative diagnostic과 F2의
잘못된 생성 코드 컴파일 오류를 구분한다.

### 7.2 TypeScript/React: 지원 하한과 대표 라인

각 Node에 npm 11.19.0을 scope한 `npm ci`, `npm test`를 새로 실행했다.
Node22는 full-local, Node20은 `node20-install.log`/`node20-tests.log`에 있다.
양쪽 모두 strict source/test typecheck, build, **5 files / 28 tests**,
Vite production consumer와 세 package publint/ATTW/map/파일 검증이 통과했다.
28개는 core 17, React 7, testing 4다. CJS/node10 ATTW resolution은
ESM-only 계약에 따른 의도적 제외이며 경고를 전체 호환 PASS로 바꾸지 않는다.

실제 tarball을 각각 별도 프로젝트에 설치해 typecheck/SSR/Vite build/browser를
실행했고, 정식 gate의 F3를 보완하는 **독립 exact 검사**도 모두 새로 실행했다.
이는 진단 보완이지 정식 gate의 수정이 아니다.

| Node / React | 소비자 artifact 폴더 (OS TMPDIR 아래) | 정확한 독립 후조건 / 로그 |
| --- | --- | --- |
| 22.23.3 / 19.2.8 | `innoflow-packed-consumer-OLa6Bw` | SSR 7, hydration 8, Increase 9, Decrease 8; `exact-node22-react19.log` exit 0 |
| 22.23.3 / 18.2.0 | `innoflow-packed-consumer-KrmRZt` | 동일 후조건; `exact-node22-react18.log` exit 0 |
| 20.19.0 / 18.2.0 | `innoflow-packed-consumer-Vyknab` | 동일 후조건; `exact-node20-react18.log` exit 0 |
| 20.19.0 / 19.2.8 | `innoflow-packed-consumer-L3PEYG` | 동일 후조건; `exact-node20-react19.log` exit 0 |

Chromium **156.0.8078.4**, headless에서 `getByRole('status').textContent()`의
정확한 값을 비교했다. SSR은 JavaScript를 끈 독립 page로 확인했고,
hydrate page의 recoverable/page/console errors는 0이었다. 각 screenshot을 보존했다.
다른 browser engine/physical mobile browser의 실행 증거로 확대하지 않는다.

### 7.3 기존 suite 공백을 보완한 독립 진단

외부 임시 프로젝트/파일만 사용했으며 production tests에 통합하지 않았다.
재현 자료와 setup은 [REPRODUCERS.md](verification/2026-10-18/REPRODUCERS.md)에 있다.

- `runtime-probes.log` exit 0: 정상 constructor 대조, composition order,
  scope state/action/output lifting/filter, unmatched action/zero reducer,
  mapped effect ID 취소와 다른 ID 독립, 복수 finish waiter/대기자 취소,
  nullable/no-replay output/close, TestStore의 잘못된 기대값 세 종류 탐지 통과.
  F1은 관측 결과로 FAIL을 출력한다. `runtime-expected-failure.log`는
  같은 실행에 명세 assertion을 켜 F1 때문에 **exit 1**인 정상 탐지 결과다.
- `kotlin-native-result.log` exit 0: 일반 exception 실패/관측,
  native timeout/명시 취소 정상 완료, 후속 독립 retry state 1의 대조.
  Kotlin `finish()`의 await waiter 취소를 root 취소 API와 혼동하지 않는다.
- `typescript-probes-node20.log`, `typescript-probes-node22.log` 각각 exit 0,
  **7개 독립 group**. composition/ID+signal mapping, output undefined/no replay,
  state/output/observerFailed 오류 격리, unsubscribe/close, 다중 waiter,
  logical cancellation 뒤 늦은 사용자 코드 실행과 emission 차단의 차이,
  실패 sibling abort/재시도, TestStore negative/cyclic custom comparator,
  missing Provider 오류와 valid Provider SSR을 검증했다.
- `browser-mutant-current-gate.log` exit 0은 **F3 실패의 증거**다.
  같은 mutant의 `exact-mutant-expected-failure.log`는 SSR 70 / UI 80→90→80을
  정확히 기록하고 네 불일치로 exit 1이다. 정상 screenshot의 8과 mutant의
  80을 시각적으로도 대조했다. wrong fixture를 정상 runtime 결함으로 계산하지 않는다.

### 7.4 Android 실제 runtime과 process restoration

API34 `Small_Phone_API_34`를 emulator-5580, API26 `Hestia_API_26`을
emulator-5582에서 **한 대씩** cold-start했다. 기존 user data를 wipe하지 않았고,
다른 앱/build/compiler를 중단하지 않았다. 각 device의 fingerprint,
instrumentation XML, crash buffer와 screenshot을 E2에 복사했다.

```bash
ANDROID_SERIAL=<owned-serial> ./kotlin/gradlew -p kotlin :inno-flow-compose:connectedDebugAndroidTest :android-sample:connectedDebugAndroidTest --no-parallel --console=plain
python3 scripts/check-android-restoration.py --serial <owned-serial>
```

- API34: `android-api34-instrumentation.log` exit 0, 실제 Compose 2 + sample 1,
  실패/skip 0. `android-api34-restoration.log` exit 0, PID **6776→7605**,
  정확한 **Count 2** 복원. 원본 screenshot/XML 폴더는
  `innoflow-android-restoration-69_qq21j` (OS TMPDIR).
- API26: `android-api26-instrumentation.log` exit 0, 실제 Compose 2 + sample 1,
  실패/skip 0. 자동 `android-api26-restoration.log`는 **exit 1**, PID가
  종료되지 않아 실패했다. 실패 folder `innoflow-android-restoration-s0_q23zd`를
  보존했다. API26 자동 gate를 통과로 보고하지 않는다.
- API26 별도 대조: Activity STOPPED와 저장 상태, PID의 정확한 `/proc/<pid>/cmdline`,
  debug 앱의 같은 UID `run-as`를 확인하고 **해당 sample PID만** 종료했다.
  `force-stop`은 사용하지 않았다. `android-api26-manual-control.log` exit 0,
  PID **4510→5061**, 화면 **Count 4** 복원. 이는 실제 process-death 복원 증거지만
  기존 자동 probe의 portability나 API23/35 gate 통과를 대신하지 않는다.
- target sample crash를 새 crash buffer에서 관찰하지 않았다. 이전 System UI
  ANR 이력은 재사용한 환경 설명일 뿐 이번 실패의 원인으로 단정하지 않는다.
- 두 owned emulator는 검증 뒤 `adb -s <serial> emu kill`로 정상 종료했고,
  최종 `adb devices`는 비어 있었다. AVD/SDK/user data를 삭제하지 않았다.

로컬 설치 phone image는 API26/34뿐이다(API36은 Wear). API23/35 x86_64 hosted
matrix, physical device는 미검증이다. 이 입력은 unpushed이므로 hosted 증거를
만들기 위해 commit/push하거나 runtime image를 추가 설치하지 않았다.

### 7.5 API·패키징·도구체인 식별

core/testing/KSP의 JVM ABI 3개와 Android/Compose의 **실제 release AAR**에서
추출한 ABI 2개를 대조했다. Android API selftest는 임시 golden만 바꿔 거부를
확인했고 production golden에는 손대지 않았다. `javap -verbose`의 core class
major는 **55(Java11)**, Compose는 **61(Java17)**이다. producer/consumer
toolchain 및 compiler metadata 호환성은 §2 exact 입력 범위의 증거다.

핵심 산출물 SHA-256 (전체 목록 `producer-artifacts.sha256`):

| 산출물 | SHA-256 |
| --- | --- |
| core 1.0.0 JAR | `34f5d836f535125d135e7d2ce9879fa73f17c5c19bc7290ce7b294611d60892e` |
| KSP 1.0.0 JAR | `52db826ebb2e2862a0faa36f154c541e3fc5a4c04c6c3a58d64d90bfbe7bb7a6` |
| Android 1.0.0 AAR | `8786bf68dbf0fbfd15d9dc18edf0a1f81985c25e7624ab626f4706dabf18c204` |
| Compose 1.0.0 AAR | `508239a05482539abc0f17dfa8704a5581fa96cbe91b956fc19432baa806930f` |
| sample debug APK | `17c9439b8d6d345dd816f6622fd313e99573dfbdaf7da22987c8770d67b6164c` |

Gradle distribution 9.7.0 pin의
`84fbba45c7f4c64abc77460e1c00f541e9f960e3c7ed2538f1ede19eacd873ae`를
공식 checksum과 새로 대조했다. wrapper JAR도 공식 구버전 checksum과 일치했다(O3).
이미 캐시된 Gradle distribution을 다시 다운로드한 cold-download 증거는 아니다.
npm 세 tarball에는 README/LICENSE/source/JS/declaration maps가 있고 test source와
tsbuildinfo는 없다. pub-lint/type/resolve 결과를 실제 독립 설치와 함께 검증했다.

### 7.6 관측·보안·CI 신뢰 경계

- `actionlint.log`: pinned actionlint 1.7.12, 18 workflows 성공.
  `action-pins.log`, `workflow-timeouts.log`: 성공.
  `full-local.log`의 CI helper passing control와 10 negative cases 성공.
  이전 SHA/PR/fork/in-progress/failure/cancelled/skipped/없는 run/더 새 실패를
  성공 증거로 받아들이지 않는지 확인했다.
- source trust review: 일반 CI의 contents read-only, checkout credential 미보존,
  tag-push 조건과 정확한 main-push SHA 확인 뒤 publication, manual dispatch는
  validation만 수행함을 대조했다. 실제 npm/GitHub Packages credential/조직 권한,
  provenance 발급, tag push와 public registry consumer는 실행하지 않았다.
- npm fresh audit는 **0 known vulnerabilities**였다. 다섯 Kotlin 모듈의
  Maven resolved runtime coordinates 38개는 OSV querybatch로 조회해 match 0이었다.
  known-vulnerable Log4j 1.2.17을
  **질의만 하는** 대조군으로 두어 6개 advisory 탐지를 확인했다. 실제 입력
  목록/조회 시각/결과는 [maven-advisories.json](verification/2026-10-18/maven-advisories.json)에 남겼다. 해당 취약 버전을
  다운로드하거나 실행하지 않았다. [OSV 공식 API 계약](https://google.github.io/osv.dev/post-v1-querybatch/).
- advisory 결과는 알려진 DB match의 시점별 관측이다. build/test/plugin 전체
  graph, undisclosed vulnerability, exploitability, 침투/심층 보안 감사의 PASS가 아니다.
- instrumentation은 Kotlin/TypeScript 모두 action/state/output payload를 받을 수
  있다. **payload-free telemetry라고 주장하지 않는다.** 기본 구현은 전송/로그를
  하지 않으며 앱이 custom observer의 redaction/retention을 책임진다.
  observer throw가 state/effect 의미를 바꾸지 않는지는 실제 실패 대조로 확인했다.
- JVM/Android/TS core는 transport/secret storage/HTML injection을 구현하지 않는다.
  packed allowlist와 source를 대조했으나 secret scanner/전체 security scan을
  실행한 것처럼 주장하지 않는다.

### 7.7 재사용한 증거와 미검증 경계

E1 종료 snapshot과 E2 시작 snapshot은 `cmp`로 **완전히 동일**했다. 기존
세 결함은 이번 요청에서 모두 재실행했고, local unit/consumer/device/Node/browser
역시 새로 실행했다. E0/E1을 이번 실행으로 둔갑시키지 않았다. E0의 환경 실패
이력만 재사용 설명이며, Gradle build의 up-to-date 산출물은 표에 따로 표시했다.

남은 경계는 A05의 정식 API26 자동 process-kill probe, A06의 실제 API23/35,
C06의 같은 최종 candidate hosted CI, C07의 실제 publish/registry-only consumer다.
기타 §3의 제외(physical device/다른 browser/지원 행렬 밖 조합/soak/전체 보안)를
PASS로 간주하지 않는다. commit/push/tag/publication이 필요한 항목은 검증
요청을 그 권한으로 확대하여 닫지 않았다.

### 7.8 보존 확인과 판정

최종 입력/문서 검증 결과와 행렬 집계는
[results.json](verification/2026-10-18/results.json)에 남긴다.
계획상 63개 행을 **54 PASS / 3 FAIL / 4 LIMIT / 2 N/A**로 닫는다.
FAIL 3건이 수정되었다는 주장은 없으며 **공개 1.0.0 승인 보류**다.
이 범위의 검증 종료는 모든 결함/환경/지원 조합을 완전히 검증했다는 뜻이 아니다.

production source/tests/fixtures/package/lock/ABI/CI에는 이번 요청의 변경이 없다.
Swift는 위 main과 동일하다. 문서에만 검증 범위·결함·재현/증거를 추가했다.
commit/push/tag/publication은 하지 않았으며, post-push Xcode cleanup 실행 조건도
발생하지 않았다. 구체적 수정 승인 뒤 F1/F2/F3 영향 행을 다시 열고, 최종 변경
입력으로 회귀/소비자/hosted/registry gate를 새로 검증해야 한다.
