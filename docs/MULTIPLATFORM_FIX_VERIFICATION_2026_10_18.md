---
status: Draft
reviewed-by: []
approved-by: null
approved-at: null
---

# Multiplatform 수정 및 재검증 — 2026-10-18

실행 상태: **고정 범위 수정·재검증 완료 / 공개 1.0 승인 보류** (2026-10-18).
문서는 Draft이며 maintainer의 Reviewed/Approved 기록은 없다.
이전 [63개 항목 원장](MULTIPLATFORM_VERIFICATION_2026_10_18.md)을 재개방해 동일한 행을 닫았다.
이전 FAIL/미검증 결과와 snapshot은 역사 증거로 보존하며 이 문서의 새 결과로 대체 판정한다.

## 고정 기준선·범위·권한

- 작업 경로: `InnoFlow-worktrees/multiplatform/InnoFlow`, branch `codex/multiplatform-flow`.
- HEAD 및 로컬 origin/main: `0a7e685d3749b3dc28c6d5e56b932c9ad7fc0b11` + 기존 미커밋 구현/검증 문서.
- 시작 입력 796개 / dirty 138개. 전체 시작 manifest SHA-256:
  `14d0a6dee7ceb18afad5fa5e2020d4969d8cffd493170c6f54f2bcd8e77be0f0`.
- 새 raw evidence: `/tmp/innoflow-fixes-20261018.evgcyvL1`.
- 이번 사용자는 F1 constructor Job 누수, F2 generic-inner KSP 생성, F3 SSR/browser
  false-positive, API26 restoration probe의 **수정과 회귀 통합**을 승인했다.
  관련 테스트/CI gate/소비자/문서까지 수정하되 commit/push/tag/publication 권한은 확대하지 않는다.
- Swift source/tests/examples/manifests/locks/Swift CI 및 Swift release preflight는 main 그대로다.
  Swift 관련 변경/런타임 설치/전체 release preflight는 하지 않는다.
- 기존 unrelated dirty 파일과 `docs/verification/2026-10-18/` 역사 자료는 바이트 보존한다.
  변경 경로 allowlist와 종료 시 per-file hash 대조로 증명한다.

## 구현·검증 순서와 종료 조건

1. 네 문제의 실패 입력과 정상 대조를 유지하고 정식 regression/negative-control을 추가한다.
2. 생성자 인자는 Job 부착 전 검증한다. KSP 타입은 generic owner/inner 경계를 보존하며
   nullable/projection/function/default/escaped/visibility 기존 지원도 함께 확인한다.
3. SSR/브라우저 assertion은 정확한 값을 비교하고 SSR 오류와 hydration 뒤 UI 오류를
   **별도 mutant**로 넣어 정식 gate가 실제로 거부하는지 확인한다.
4. Android는 background+saved-state를 확인하고 `am kill`만으로 종료되지 않으면
   numeric PID/정확한 cmdline/same-UID 검증 후 debug sample PID만 종료한다.
   force-stop이나 다른 앱/시스템/build/compiler 종료는 하지 않는다.
5. 동일한 63개 위험 행을 모두 재검증한다: 정상/실패/취소/동시성/재시도·복원/자원 한계/
   관측/신뢰 경계. source·tests·공개 API·독립 소비자·CI/release 경계를 함께 닫는다.
6. Kotlin 5개 ABI, local Maven/AAR 소비자, Node20.19/22.23.3 × React18.2/19.2.8
   tarball/SSR/hydration/browser, 독립 composition/task/output/testing probe,
   Android API26/34 기기 테스트와 정식 process-restoration probe를 새 후보로 실행한다.
7. source/hash/문서/JSON을 대조한다. 모든 행에 fresh/reused/static 또는 정확한 LIMIT/N/A를
   남기며 이전 로그를 수정 후 후보의 새 실행으로 간주하지 않는다.

성공 종료는 네 수정에 대한 회귀 통과와 아래 63개 행의 증거/한계 기록이다.
로컬 검증 통과는 공개 1.0 출시 승인이 아니다. API23/35 hosted runtime, 최종 committed
candidate의 exact-SHA main CI, registry-only 설치/credential/publication은 권한·환경 경계로
남길 수 있지만 PASS로 바꾸지 않는다. physical device/다른 browser engine/모든 미래 버전/
전역 effect cap/비협조 I/O 강제 중단/Swift 기능 동등성/심층 보안·soak는 이전 제외를 유지한다.

## 재개방한 63개 cross-feature 행렬

총 **63행 = 58 PASS / 0 FAIL / 3 LIMIT / 2 N/A**. 미결 행은 없다.
fresh는 이번 후보의 새 실행/관측, static은 소스·계약 대조, reused는 변경되지 않은
입력에 대한 이전 source-review/진단 의미를 가리킨다. Gradle 캐시 재사용은 아래에 분리한다.

| ID | 검증 후조건 / 위험 축 | 검증 경로 | 새 결과 |
| --- | --- | --- | --- |
| B01 | 기준선/dirty/Swift/기존 입력 보존 (S) | 시작·종료 파일 해시, main diff | PASS · fresh: Swift/main diff 0, remote SHA 동일, 796개 시작 입력 보존/변경 allowlist 대조 |
| B02 | 두 runtime의 portable contract 일치 (N,F,C,R,O) | counter/runtime 공통 fixture | PASS · fresh: 두 runtime의 counter + runtime-v1 6개 시나리오 |
| B03 | 모든 모듈·공개 API·지원 환경 inventory (S) | source/export/manifest/ABI/doc 대조 | PASS · fresh+static: 5 Kotlin/3 npm inventory·ABI·exports; 이전 inventory와 변화 경계 대조 |
| B04 | immutable state/비협조 작업/영속화 경계 일치 (F,C,R,L) | 계약 문서·구현·반례 구분 | PASS · fresh+reused static: immutable/논리 취소/명시 영속화 계약 무변경, late-emission·복원 재실행 |
| K01 | constructor 인자 거부가 parent job을 누수하지 않음 (F,L) | capacity 1 vs 0 독립 Job probe | PASS · fresh: red 1실패/정상 대조 통과 → regression 통과; Maven children 0 / parentJoined true |
| K02 | 최신 state 기준 FIFO·다중 producer 직렬화 (N,Q) | JVM regression/8 producers | PASS · fresh: unit 최신 상태·8 producers/4,000 actions |
| K03 | root+descendant effect/action 완료 소유권 (N,Q) | sample/독립 effect mapping probe | PASS · fresh: unit + runtime-probes.log K03/K11 |
| K04 | reducer 실패가 다른 root를 오염시키지 않음 (F,R) | 실패/후속 성공 dispatch | PASS · fresh: reducer failure/후속 독립 성공 unit |
| K05 | effect 실패/취소 의미와 독립 재시도 (F,C,R,O) | exception/cancel/timeout 대조 | PASS · fresh: effect failure/retry/cancel units + native failure/timeout/cancel·retry 3-mode probe |
| K06 | root 취소·close·시작 전/late emission 차단 (C,Q) | queued/active/uncooperative regression | PASS · fresh: cancelled admission/owner close/late emission units |
| K07 | ID latest/all matching 취소, 다른 ID 독립 (C,Q) | ID regression + mapped ID probe | PASS · fresh: ID all/latest units + runtime-probes.log K07 |
| K08 | bounded admission/backpressure/회복 (L,Q,R) | overflow/10,000 actions/stress | PASS · fresh: bounded overflow/10,000 effect sends/burst·metrics units |
| K09 | output live order/no replay/drop 관측/close 종료 (N,L,O,C) | collector regression + probe | PASS · fresh: live order/drop/close units + runtime-probes.log K09 nullable/no replay |
| K10 | instrumentation 오류 격리/metric/페이로드 경계 (F,O,S) | throw observer/queue stats + static | PASS · fresh+static: observer 오류 격리·queue metrics units; payload 책임은 기존 계약 |
| K11 | combine/scope/transition/map 조합 순서·필터 (N,F,C) | 독립 실제 runtime composition probe | PASS · fresh: runtime-probes.log K03/K11 순서·filter·zero reducers |
| K12 | task await/cancel idempotency/owner 취소 (C,Q) | 다중 waiter/취소 waiter/owner probe | PASS · fresh: runtime-probes.log K12 다중 waiter/반복 cancel/finish + owner unit |
| K13 | TestStore action/output/state/finish 및 실패 탐지 (N,F) | sample + 독립 negative assertions | PASS · fresh: TestStore unit + runtime-probes.log K13 세 negative assertions |
| G01 | public/internal/object/default/escaped factory compile (N) | 독립 published KSP fixture | PASS · fresh: published processor positive 11 features; public/internal/default/escaped |
| G02 | private/nested/generic/abstract/indirect 진단 (F,S) | 5개 expected-failure fixture | PASS · fresh: private/generic/nested/indirect/abstract 5 expected diagnostics |
| G03 | 지원 feature의 state/action/output 타입 rendering (N,F) | plain/function/suspend/generic-inner compile | PASS · fresh: 새 7 fixtures + plain/function/suspend/innerManual/inner 외부 compile 모두 성공 |
| G04 | compiler-plugin-free fallback 및 alias 경계 (N,F) | explicit FlowStore 대조/진단 | PASS · fresh: innerManual 성공; FlowFeature-supertype alias는 정확한 expected diagnostic |
| A01 | ViewModel clear가 소유 Store만 닫음 (C,Q) | Android module unit | PASS · fresh: ViewModel ownership unit 강제 실행 |
| A02 | Compose lifecycle state/output 최신 handler (N,C,O) | 2개 instrumentation/API별 증거 | PASS · fresh: Compose 2 tests × API26/34, 0 failures/skips |
| A03 | recreation/background-resume 상태 유지 (N,R) | sample instrumentation | PASS · fresh: recreation/background-resume 1 test × API26/34 |
| A04 | API 34 실제 process kill 뒤 PID/visible state 복원 (R) | serial별 restoration probe | PASS · fresh: 정식 probe PID 7446→7747 / Count 2 / am-kill / screenshot·XML·JSON |
| A05 | API 26 process 복원 증거/ANR 구분 (R,F) | available AVD/환경 확인 후 isolated probe | PASS · fresh: 정식 probe PID 4158→4362 / Count 2 / same-uid-pid-kill; safety 16 controls |
| A06 | minSdk API 23/current-line 35 runtime (N,R,C) | hosted matrix와 로컬 환경 가용성 | LIMIT · fresh environment + static: 설치된 phone AVD는 API26/34; API23/35 hosted 미실행 |
| A07 | debug/release 앱·lint·SavedState 단위 검증 (N,F) | Gradle build/test/lint | PASS · fresh: debug/release APK·lint·SavedState unit; unit --rerun-tasks |
| T01 | positive finite integer capacity 검증 (F,L) | 기존 invalid-capacity regression | PASS · fresh: capacity finite positive safe integer unit / Node20·22 |
| T02 | FIFO/reentrant send, 비재귀 drain (N,Q,L) | 20,000 chain/2,000 burst | PASS · fresh: FIFO/reentrant 20,000 chain/2,000 burst units / 두 Node |
| T03 | root+descendant 완료와 mapping 소유권 (N,Q) | existing + 독립 composition | PASS · fresh: descendant unit + independent T03/T10 / 두 Node |
| T04 | reducer/effect 실패 격리와 재시도 (F,R) | 실패/후속 성공 regression | PASS · fresh: failure/retry units + independent sibling abort / 두 Node |
| T05 | prestart/root/close 취소 및 late emission 차단 (C,Q) | regression + waiter probe | PASS · fresh: prestart/root/close/late emission units + T05/T11 / 두 Node |
| T06 | ID latest/all matching 및 다른 ID 독립 (C,Q) | regression + mapped ID probe | PASS · fresh: latest/all matching units + mapped ID/signal probe / 두 Node |
| T07 | bounded overflow·회복/queue compaction (L,R) | overflow/large burst/metrics | PASS · fresh: overflow/recovery/burst/compaction·metrics units / 두 Node |
| T08 | output no replay/unsubscribe/close·undefined (N,C,O) | regression + 독립 output probe | PASS · fresh: output unit + T08/T09 undefined/no replay/unsubscribe/close |
| T09 | state/output listener 오류 격리·구독 정리 (F,O,S) | 독립 throw/unsubscribe/close probe | PASS · fresh: T08/T09 throwing state/output/observerFailed 및 구독 정리 |
| T10 | combine/scope order/filter/Effect.map/signal (N,F,C) | 독립 실제 runtime composition | PASS · fresh: T03/T10·T06/T10 composition/map/signal/ID / 두 Node |
| T11 | task finished await/cancel/multiwait/abort fanout (C,Q,L) | 독립 task probe/기존 burst | PASS · fresh: T05/T11 multiwait/idempotent cancel·late-work suppression + burst |
| T12 | TestStore 구조/Map/Set/Date/undefined/custom 및 negative (N,F) | 4개 unit + 독립 실패 탐지 | PASS · fresh: 4 unit + 독립 wrong state/action/output/custom cyclic comparator |
| R01 | SSR initial snapshot → hydration live state (N,R) | React unit + tarball SSR/browser | PASS · fresh: React SSR/hydration units + 네 tarball/exact browser checks |
| R02 | selector/equality 교체·undefined·불필요 render (N,Q) | selector unit/정적 hook 대조 | PASS · fresh+static: selector/equality/undefined/render units; hook 구조 무변경 |
| R03 | StrictMode mount/unmount 구독 무누수 (C,Q) | React unit | PASS · fresh: StrictMode mount/unmount unit / 두 Node |
| R04 | typed provider/store 교체/미제공 오류 (N,F) | React unit + 독립 boundary probe | PASS · fresh: provider/store replacement units + missing Provider SSR probe / 두 Node |
| R05 | tarball browser interaction·console·hydration (N,F) | 실제 Chromium/정확한 DOM 후조건 | PASS · fresh: 4 Chromium tarball consumers + 독립 exact 7/8/9/8, console/hydration 오류 0 |
| R06 | 잘못된 SSR/UI 수치가 gate에서 거부됨 (F,S) | 정상 vs count×10 mutant | PASS · fresh: 수정 전 두 mutant 잘못 통과 → 수정 후 SSR 70 / live 80 각각 값 oracle에서 거부 |
| R07 | Node20/22 × React18/19 소비자 행렬 (N) | 독립 설치/typecheck/SSR/build/browser | PASS · fresh: Node20.19.0/22.23.3 × React18.2.0/19.2.8 독립 설치·typecheck·SSR·browser |
| P01 | core/testing/KSP ABI baseline 일치 (S) | 3개 JVM ABI gate | PASS · fresh: core/testing/KSP ABI --rerun-tasks, golden 변경 0 |
| P02 | Android/Compose 실제 AAR ABI·negative golden (S,F) | 2개 AAR gate/selftest | PASS · fresh: Android/Compose AAR ABI --rerun-tasks + wrong-golden 2개 거부 |
| P03 | Maven JVM consumer 무 project substitution (N,S) | independent refresh-dependencies test | PASS · fresh: external JVM Maven test --refresh-dependencies --rerun-tasks |
| P04 | Maven AAR 앱 consumer test/release build (N,S) | independent Android fixture | PASS · fresh: external AAR unit/release APK --refresh-dependencies --rerun-tasks |
| P05 | npm exports/types/maps/license/불필요 파일 제외 (N,S) | pack/publint/ATTW/maps/consumer errors | PASS · fresh: 3 pack/publint/ATTW/source maps/licenses/타입 negative 검증 |
| P06 | Node20/22 clean install+typecheck+28 regressions (N,F) | scoped exact Node/npm | PASS · fresh: Node20·22 각각 npm ci + 28 tests/5 files/typecheck/build |
| P07 | toolchain pin/checksum/bytecode/SDK/dependency 범위 (S) | wrapper/manifest/resolution/classfile | PASS · fresh+reused static: Gradle/JDK 버전·classfile 55/61 확인; pins/checksum/SDK 계약 무변경 |
| C01 | workflow 구조/action pin/timeout/권한 (F,S) | canonical actionlint/정적 policy | PASS · fresh+static: actionlint1.7.12 18 workflows·action pins·timeouts·permissions |
| C02 | 정확한 SHA·main-push CI 선행 증거/negative (F,S) | helper 10개 실패 대조군 | PASS · fresh: exact-SHA/main-push normal + 10 negative evidence controls |
| C03 | untrusted PR/비밀·publish 분리 (S) | 3개 workflow source trust review | PASS · static: publish tag-push 조건/credential 분리/PR read-only/exact-SHA gate 유지 |
| C04 | dependency advisory scan 및 제한 명시 (S) | npm audit + JVM graph 검토 | PASS · fresh bounded advisory scope: npm0; Maven runtime38 OSV0; query-only vulnerable control6 |
| C05 | package/runtime payload·secret 책임 경계 (S,O) | packed file list/instrumentation source | PASS · fresh+reused static: packed whitelist/maps·source payload 책임 경계; 보안감사 주장 없음 |
| C06 | 실제 hosted CI가 같은 candidate를 검증 (N,S) | 아직 unpushed인 입력의 evidence 유무 | LIMIT · fresh: uncommitted/unpushed candidate; 같은 입력의 hosted main CI 증거 없음 |
| C07 | 공개 registry 설치/권한/릴리스 완료 (N,S) | 실제 publish 후 remote-only consumer 필요 | LIMIT · fresh: publication 미수행; registry-only consumer/credential/승인 미증명 |
| X01 | Swift release/runtime 회귀 판정 제외 (N,C,R) | main parity만 수행, CI-only 정책 | N/A · fresh parity only: Swift main 무변경, Swift runtime/release suite는 CI-only 제외 |
| X02 | 비지원 platform/서비스/soak·보안감사 구분 (S,L) | 명시된 제외와 광고 계약 대조 | N/A · static: physical/다른 engine/RN/soak/deep security/Swift 동등성 등 명시 제외 |

## 구현 변경·실행 원장·최종 판정

### 네 수정과 red/green 증거

| ID | 구현/정식 회귀 | 수정 전 실패와 정상 대조 | 수정 후 결과 |
| --- | --- | --- | --- |
| F1 · K01 | FlowStore 초기 init에서 capacity 검사, 부모 Job 부착보다 먼저 수행. ReleaseContractsTest 2개 추가 | 이번 red-constructor.log: 2 tests/1 failed, 정상 생성·close 대조 통과; invalid capacity가 sibling 외 child를 남김 | 잘못된 0/-1/MIN/MAX 뒤 parent·sibling 유지/join; 정상 1/8/1024 send/close. 독립 Maven JAR: capacity 1/0 모두 children=0, parentJoined=true |
| F2 · G03 | KSP renderClass가 inner 자신의 인자를 분리하고 owner를 재귀적으로 렌더링. static nested 경계에서 capture 중단 | 이번 red-ksp-owners.log: fixture 원본이 아니라 generated Owner.Inner<inner,owner> 코드가 실패. 기존 manual 대조는 성공 | 7개 새 feature: state/action/output generic owner, 인자 없는 inner, 다중 inner, 복수 인자, static boundary, nullable/typealias/star/function. 기존 4 feature도 성공. 독립 plain/function/suspend/innerManual/inner 성공 |
| F3 · R06 | smoke.mjs는 SSR output 정확 비교, packed browser는 anchored locator + textContent 정확 비교. 정식 gate를 외부 복사본에서 실행하는 selftest 추가 | 이번 red-packed-oracles.log: 정상 대조와 SSR-only·live-only 잘못된 값이 모두 exit0이어서 selftest가 exit1. live mutant는 SSR/첫 hydration 7을 유지해 hydration 오류와 분리 | Node20/22 selftest 정상 대조 exit0, SSR70 및 live80은 각각 SSR/browser 정확 값 진단으로 거부. install/compile/console 오류만으로는 negative 통과 불가 |
| A05 | import-safe RestorationProbe, 저장된 STOPPED Activity·단일 양수 PID·정확 cmdline·PID 재확인·same-UID kill·실제 소멸/새 PID/정확 화면 검사 | 이전 원장의 API26 am-kill PID 미종료는 역사 red로 재사용. 이번 safety 16개는 normal/native 성공과 잘못된 상태/PID/cmdline/run-as/미종료를 직접 대조 | 정식 probe: API26 4158→4362, API34 7446→7747, 둘 다 Count2. force-stop/다른 앱/시스템 종료 없음 |

확정 3건(제품 2, 검증 gate 1)과 API26 도구 문제는 이 후보에서 corrected다.
이것은 모든 미래 입력에서 무결함이라는 판정이 아니다. 확인되지 않은 새로운 제품 후보를
재현 없이 확정 결함으로 추가하지 않았다.

정식 통합: scripts/test-multiplatform.sh, contracts CI, Node matrix CI와 해당 release workflow가
관련 safety/value negative controls를 실행한다. release 조건·권한은 넓히지 않았고 Swift CI는 그대로다.
Kotlin ABI golden, npm lock/dependency, Swift source/manifest는 바꾸지 않았다.

### 실행 원장·버전·캐시

Raw evidence 접두어는 위 고정한 /tmp/innoflow-fixes-20261018.evgcyvL1이다.
전체 명령/환경과 해시/기기 자료는 [durable evidence](verification/2026-10-18-fixes/README.md)와
[results.json](verification/2026-10-18-fixes/results.json)에 함께 기록한다.

| 새 실행 | 관측/개수 | 대표 로그 |
| --- | --- | --- |
| 최종 scripts/test-multiplatform.sh | exit0, Kotlin producer/consumer/lint/ABI/publish-local/KSP·AAR negative/CI evidence/safety/npm/package/browser 모두 통과 | full-local-final.log |
| Kotlin unit 강제 실행 | sample26 + ViewModel1 + SavedState1 = 28, failure/error/skip0 | kotlin-unit-fresh.log, kotlin-unit-counts.txt |
| 독립 Maven JVM/AAR 강제 실행 | test 각각1, AAR release APK 성공; --refresh-dependencies --rerun-tasks | jvm-consumer-fresh.log, aar-consumer-fresh.log |
| ABI 5개 강제 실행 | baseline 전부 일치, 변경0; 실제 AAR wrong-golden 2개는 별도 정식 selftest에서 거부 | abi-fresh.log, full-local-final.log |
| KSP published consumer | positive11 features compile + 5 expected failure cases; 외부 plain/function/suspend/innerManual/inner compile, supertype-alias는 정확 diagnostic | green-ksp-owners.log, ksp-*-final.log, full-local-final.log |
| Kotlin 독립 조합/출력/task/testing | composition order/filter, map cancellation ID, 다중 waiter, nullable/no replay/close, TestStore wrong state/action/output, constructor contract 모두 통과 | runtime-probes.log |
| Kotlin native exception/cancellation | domain failure는 task failure/관측1, timeout·명시 취소는 native cancellation/관측0, 세 경우 모두 이후 retry state1 | kotlin-native-fresh.log |
| Node20.19.0/22.23.3 | npm11.19.0, 각각 npm ci 후 28 tests/5 files, 7개 추가 독립 probe groups | node20-tests.log, full-local-final.log, typescript-probes-node20/22.log |
| React18.2.0/19.2.8 × 두 Node | 실제 tarball install/typecheck/SSR/build/Chromium interaction/console 모두 성공; 별도 JS-disabled SSR7 및 live8/9/8 확인 | browser-node20-react18/19.log, browser-node22-react18.log, full-local-final.log, exact-*.log |
| value oracle selftest | 각 Node 정상1 + 분리된 SSR/live mutant2개. 모두 의도된 후조건 판정 | green-packed-oracles-node20.log, full-local-final.log |
| API26 / API34 | 각 Compose2 + sample1 = 총6 tests, failure/skip0. 정식 복원 probe도 각각 exit0 | android-api26/34-instrumentation.log, android-api26-restoration.log, android-api34-restoration-final.log |
| restoration safety selftest | 16 tests, 정상/native/fallback·잘못된 상태/이름/PID race/command denial·가짜 종료 구분 | green-restoration-selftest-final.log |
| CI 구조·정책 | actionlint1.7.12 / 18 workflows, pins/timeouts, normal+10 exact-SHA negative controls | actionlint.log, action-pins.log, workflow-timeouts.log, ci-evidence-selftest.log |
| advisory 조회 | npm0 known; Maven runtime38 OSV0, query-only Log4j1.2.17 control6 (취약 package를 설치/실행하지 않음) | full-local-final.log, jvm-dependency-graph.log, maven-advisories.json |
| Swift/입력 보존 | remote main SHA 동일, scoped Swift diff0, 기존 입력 변경 allowlist 확인 | remote-main.txt, swift-main-parity.log, source-preservation.log |

Kotlin/Gradle/AGP/KSP은 2.4.10/9.7.0/9.3.1/2.3.11, launcher JDK17.0.20.1,
core classfile55(Java11), Android/Compose61(Java17). TS5.9.3, Chromium156.0.8078.4,
host macOS27.0.1 arm64다. 설치된 host Node26 결과로 Node20/22를 대체하지 않았다.
compileSdk37/minSdk23는 빌드 계약이지 API23 실행 증거가 아니다.

두 차례 broad script와 기기 빌드는 새로 호출하되 unchanged Gradle build/cache outputs를 재사용했다.
이를 clean rebuild라고 부르지 않는다. 핵심 unit 28개·외부 consumer2개·ABI5개는
별도로 --rerun-tasks로 강제 실행했고, KSP fixtures는 clean compile했다.
Node별 npm ci와 실제 독립 tarball 설치는 새 실행이다.

### fixture/환경 실패 이력과 구분

- API34의 첫 새 probe는 실제 dumpsys의 Hist 헤더 이중 공백과 mAppStopped/mHaveState 표기를
  처리하지 못해 kill 전에 안전하게 거부했다 (android-api34-restoration.log).
  실제 표기를 지원하고 record-isolation regression을 추가한 뒤 정식 probe를 다시 실행해
  exit0을 확인했다. 이 실패는 runtime state 복원 결함이 아니다.
- 독립 exact Node22/React18 probe를 npm ci와 겹쳐 실행한 1회는 node_modules 교체 중
  module-not-found로 실패했다. 설치 완료 뒤 exact-node22-react18-final.log는 exit0.
  네 최종 exact 소비자에 이 실패를 PASS로 섞지 않는다.
- 초반 Gradle 호출의 ANDROID_HOME 누락은 도구 출력에서 관측한 SDK 환경 실패였다.
  해당 scratch 로그는 정상 재실행으로 덮어써 원본 실패 로그가 남아 있지 않다.
  명시 환경으로 다시 실행한 정상 로그와 최종 전체 실행은 보존했다.
  첫 Maven graph 호출은 configuration 옵션이 마지막 task에만 적용돼 다른 모듈의
  전체 configuration까지 출력했다 (exit0, jvm-dependency-graph-attempt.log).
  이 넓은 출력은 advisory scan 근거로 사용하지 않고, 모듈별 명시 runtime configuration으로
  새 조회한 jvm-dependency-graph.log만 38개 좌표의 근거로 사용했다.
- red constructor/KSP와 두 value mutants, unsupported KSP 5개, wrong ABI golden2개,
  CI evidence negatives10개는 **예상 실패 대조**다. 정상 실행 실패와 합산하지 않는다.
- 이전 원장의 metaspace/System UI ANR/old am-kill 결과는 역사 자료로 유지한다.
  이번 두 기기 성공 probe에는 ANR dialog가 없었고, 최종 crash buffer는 각각 0 bytes다.

### 입력 identity·보존

최종 실행 후보는 HEAD만이 아니라 [128개 candidate inputs](verification/2026-10-18-fixes/candidate-inputs.sha256)로
식별한다. verification 문서/JSON의 자기 참조 hash는 그 manifest에서 제외하고,
별도 전체 시작/종료 snapshot과 변경 allowlist를 대조한다. 이전 125개 manifest는 수정 전 입력이므로
현재 후보에 적용하면 의도된 수정 때문에 실패한다. 역사 sidecar는 그대로 보존한다.

- candidate-inputs.sha256의 SHA-256: `81719a85194d5671373a4888e1e69ff545057c4da09261085785891a37f86c9e` (128 paths).
- 전체 기존 시작 입력 796개 중 승인 범위 17개를 변경했고, 나머지 779개는 바이트 동일, 삭제 0개다.
- 17개는 core/KSP 2, 기존 regression 1, SSR/browser gate 2, npm script 1, Android probe 1,
  local/contract helper 2, 플랫폼 workflow 3, changelog 및 관련 문서 5다.
  신규 파일은 세 정식 regression/helper와 새 검증 원장/sidecar만 허용했다.
- 이전 `docs/verification/2026-10-18/` 전 파일과 unrelated `.gitignore`/CLAUDE.md,
  Swift/main 소스·테스트·manifest·CI는 바이트 보존했다. raw before/after manifest와
  exact changed-path 목록은 results.json 및 scratch의 source-preservation.log로 연결한다.

### 남은 gate·선택 개선·출시 결정

- **A06 LIMIT:** 로컬 phone AVD26/34만 실행. API23/35 hosted device jobs는 실제 실행 전 미검증.
- **C06 LIMIT:** uncommitted/unpushed 입력이므로 최종 committed/tagged main SHA의 hosted CI 증거가 없다.
- **C07 LIMIT:** registry-only consumer/credential/publication/maintainer release 승인은 미증명.
- **X01/X02 N/A:** Swift release/runtime CI-only, physical device·다른 engine/RN·soak·심층 보안 등
  명시 제외. 무변경을 runtime PASS로 바꾸지 않는다.

선택 개선 O1(native timeout의 domain-failure 예제), O2(FlowFeature-supertype alias 지원),
O3(wrapper refresh)는 이전 분류 그대로이며 이번 네 수정의 필수 범위를 확장하지 않았다.
예외/취소 의미나 지원 플랫폼을 새로 광고하지 않는다.

Verified facts는 위 fresh 실행/해시·정적 계약이며, working assumption은 문서화된 compiler 조합과
협조적 cancellation/immutable application state다. Unknown의 해결 책임자는 release maintainer이고
해결 시점은 commit 후 exact-SHA hosted 실행 및 승인된 registry publication이다.
새 commit/배포 입력이 달라지면 이 manifest 결과를 그대로 이월하지 않는다.

| 출시 단계 | 현재 상태 |
| --- | --- |
| 구현·로컬 unit/integration/build | scoped fixes 완료, 위 후보에서 검증 |
| hosted CI / 최소·current API runtime | 미실행, A06/C06 |
| 업로드·공개·registry-only 소비자 | not-run, C07 |
| maintainer 승인 / 운영 acceptance | 미기록 / 미검증 |

Decision: **public release HOLD**. 고정한 로컬 수정·검증 범위는 닫혔지만 사용자/maintainer의
출시 승인으로 자가 승격하지 않는다. 다음 gate는 명시적 commit/push 승인 후 exact-SHA CI,
API23/35, publication 승인 및 remote-only 소비자이며 이번에는 어떤 commit/push/tag/publish도 하지 않았다.
시작한 두 emulator는 정상 종료했다. push가 없으므로 post-push XcodeBuildMCP cleanup도 해당 없다.
