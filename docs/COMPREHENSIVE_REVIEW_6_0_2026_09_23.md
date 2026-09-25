# InnoFlow 6.0 — 범위 고정 종합 검토 (2026-09-23)

## 기준·권한·종료 기준

- 상태: **고정한 24개 영역의 검토 기록 완료 / 결함·미검증 경계 있음 / 배포 준비 미완료**. 모든 조합의 동적 검증 완료, 결함 수정 또는 배포 완료 보고가 아니다.
- 기준: `release/6.0.0-local`, HEAD `dbd6cfec40e302fc03ac9f8f35ff810d30d48014`와 기존 tracked/untracked 변경. [검토 전 snapshot](../.build/comprehensive-review-20260923/candidate-before.json), [변경 목록](../.build/comprehensive-review-20260923/status-before.txt), [입력 inventory](../.build/comprehensive-review-20260923/file-inventory.txt).
- 원격은 fetch 후 `HEAD...origin/main = 1/0`, latest published `5.1.1`. 원격의 다른 PR 성공/실패는 이 dirty 후보의 결과가 아니다.
- 현재 환경: Xcode 27.0 `27A266a`, Apple Swift 6.4 `swiftlang-6.4.0.34.1`, arm64 macOS. 9월 18일 실행 환경과 다르므로 과거 테스트 결과를 재사용 PASS로 표시하지 않는다.
- 허용 변경: 이 검토 기록·향후 검토 지침·사용자가 요청한 기억 메모. production source/test, 정책, workflow 수정·commit/push/PR/태그/공개는 실행하지 않는다. 진단 probe는 `.build/comprehensive-review-20260923/` 아래에 둔다.
- 범위: 네 공개 product, macro target, tests/fixtures, canonical sample, docs, scripts, 6개 workflow와 공개/원격 보호 경계. Kotlin/TypeScript 별도 worktree는 이 Swift 6.0 후보에 포함되지 않아 제외한다.
- 명시적 제외: 물별 feature/UI/접근성/VoiceOver 및 checkout/token/SHA. 다른 제품 앱으로 대체하지 않는다. 실제 운영 트래픽·전체 하드웨어 조합·외부 서비스의 보안 감사는 수행하지 않는다.
- 종료: 아래 고정 행렬의 각 행에 fresh 실행, source/contract 점검, 재사용 이력, 또는 구체적인 미검증 사유를 기록한다. 의심 사항은 직접 반례+정상 대조로 확정하거나 미확정으로 남긴다. 열린 행을 숨기지 않되 무결함·수정 완료·release-ready 선언은 하지 않는다.

## 모듈 및 교차 기능 검토 행렬

경로 차원: N 정상, F 실패, C 취소, X 동시성, R 재시도/복원, L 자원 한도, O 관측성, S 보안/신뢰 경계. 재시도·영속 복원 자체는 InnoFlow의 소유 기능이 아니며 R은 재전송·동일 ID 재삽입·수명 재시작·증거 재사용을 검토한다. 적용되지 않는 차원은 최종 증거에 이유를 남긴다.

| ID | 영역 / 명시적 교차 기능 | 적용 차원 | 증거·판정 |
| --- | --- | --- | --- |
| M01 | Package / facade / Core 독립성 / 공개 product·privacy resource | N F S | E01/E04 통과, Package.swift·target dependency·privacy resource 점검. Core 독립 consumer 실행 E05. 네 product 전체 API diff는 M17의 미검증 경계. |
| M02 | Reduce/Combine/Scope/IfLet/IfCase/ForEach × effect/output lifting | N F C X R L | Reducer.swift·EffectTask.swift와 ReducerComposition/ReducerOnChange/ForEachIdentifiedReducer/OutputPromotion 회귀 E01 통과. ReducerOutput은 E02도 통과. 모든 임의 조합에 대한 생성형 검증은 미실시. |
| M03 | PhaseMap × post-reduce/guard/strict totality/graph diagnostics | N F R O | PhaseMap·PhaseValidationReducer·graph 계약 점검, PhaseTransitionGraph/PhaseValidationReducerDiagnostics/PhaseMapDiagnosticsAdapters/strict macro E01/E02 통과. 외부 persistence 복원은 이 기능의 계약 밖. |
| M04 | Store action queue × FlowTask descendant finish/cancel | N F C X R L | Store·Store+EffectDriver·FlowTask·StoreActionQueue 점검. FlowTask/FlowTaskCancellationBoundary/StoreEffectRuntime/StoreActionQueue E01, cancellation boundary E02 통과. queue는 drain 후 저장공간 축소이지 입력 backpressure 보장이 아님. |
| M05 | latest/drop/serial scheduler × cancellation ID / queue capacity | N F C X R L O | EffectRunScheduler 전체 점검, admission/중첩/대기 취소/비협조 작업 회귀 E01/E02/E03 통과. 장시간 무한 producer 스트레스 및 모든 OS sanitizer는 미실시. |
| M06 | effect map/merge/concatenate/debounce/throttle/sequence × clock | N F C X R L | EffectWalker·EffectTask·EffectExecutionContext 점검. EffectTask/EffectTaskPerform/EffectTaskRunSequenceError/EffectCancellationScope/TestStoreEffectAlgebra E01 통과. ManualTestClock은 E02 포함. 실제 네트워크 재시도/영속 복원은 사용자 effect 책임. |
| M07 | FlowScope × unrelated await / throw / sibling lifetime | N F C X L | FlowScope 전체 점검. 등록/닫힘 경쟁·unrelated await·throw·형제 격리 E01/E02/E03 통과. 프로세스 종료 뒤 복원은 ephemeral scope 계약 밖. |
| M08 | capture outputs × broadcast / descendant / termination / buffer | N F C X L S | StoreOutputHub·FlowTask 점검. ReducerOutput/OutputCasePath/TestStoreOutputMatching E01/E02 통과. 종료·취소·buffer drop·구독자 분리 확인. output은 영속/보안 격리 채널이 아니며 외부 전송 보안은 범위 밖. |
| M09 | collection/identified scopes × delete/reinsert/cache identity | N F C X R L | ScopedStore·StoreCaches·IdentifiedArray 점검. CollectionScopeCache/SingleScopeCache/StoreScopeSelection/IdentifiedArray E01, 삭제 관찰·재삽입·형제 격리 E03 통과. 공식 8-runtime 집합에는 해당 삭제 회귀가 빠져 있음 F4. |
| M10 | selected/optional state × observation registry / dependency isolation | N F X R L O | SelectedStore·ProjectionObserverRegistry 점검, 기존 E01/E02/E03 통과와 별개로 captured selector 충돌 F1을 Debug/Release E05에서 재현. parent release 알림은 C1 계약 미확정. |
| M11 | SwiftUI bindings/presentation/animation/preview × scope lifetime | N F C R O | Store+SwiftUIBinding·presentation helpers 점검, StoreSwiftUIBinding/StorePresentation/StoreSwiftUIPreview E01 통과. 실제 렌더링·화면 이동·접근성 및 모든 form factor UI는 미검증. 이 행을 사용자 체감 검증 PASS로 표시하지 않음. |
| M12 | TestStore receive/output/finish × exhaustivity / cancellation / deadline | N F C X L O | TestStore core·receive/output·finish deadline/cleanup 점검. Core/Receive/OutputMatching/Exhaustivity/Finish/TerminalVerification E01, output matching E02 통과. 동일 TestStore를 여러 scenario에서 동시에 공유하는 사용 계약은 독립 검증 안 됨. |
| M13 | invariant/scenario/ManualTestClock × composed/scoped reduction | N F C X R L O | invariant·scenario reporter 복원·scoped forwarding·clock 점검. TestStoreInvariant/scenario/ManualTestClock E01/E02 통과. 테스트 clock을 실제 wall-clock 처리량 근거로 사용하지 않음. |
| M14 | macro generation × visibility/generic/conditional/availability/collision | N F S | macro 생성·진단 분기 및 fixtures 점검. macro 68개와 독립 CompileContractTests 31개 E01 통과. toolchain 6.3에서 동일 실행은 미검증. macro 자체에 네트워크/영속 재시도 기능은 없음. |
| M15 | diagnostics/instrumentation × effect failure/privacy/retention | N F C X L O S | StoreDiagnostics·StoreInstrumentation 및 failure/redaction/signpost 경로 점검. DispatchDiagnostics/StoreInstrumentation/StoreInstrumentationMetrics E01/E02 통과. OS 로그 추출·운영 개인정보 감사는 미실시; 기본 redaction 검증을 전체 앱 보안으로 확대하지 않음. |
| M16 | performance/resource lifecycle × queue/cache/deinit/clock cleanup | N C X R L O | bounded history·scope cache·projection prune·queue 축소 점검. ProjectionObserverRegistryPerf/ReducerCompositionPerf/PhaseMapPerf 및 관련 script tests E01 통과. 여러 빌드가 공존한 환경으로 전용 성능 기준선·장시간 RSS/leak·전체 sanitizer 증거는 아님. |
| M17 | independent macro/Core/Catalyst consumer × public API / 5.1.1 migration | N F R S | 독립 compile 소비자 31개 E01 및 plugin-free Core 소비자 E05 실행. 네 product의 전체 API diff·5.1.1→6.0 migration consumer·전용 Catalyst consumer는 이번 미실시. static API baseline의 staged 메시지를 완료로 해석하지 않음. R63 미완료. |
| M18 | README/DocC/sample × compile contracts / user-visible behavior | N F R O | 공개 GettingStarted 실행형 예제 compile 성공, sample 지침의 Sendable 예제 compile 실패 F7/E10. 문서 계약/parity E04. 전체 코드 블록 분류·DocC 생성·canonical sample UI 실행은 미완료. R64 유지. |
| M19 | 5 SDK / platform runtime × discovery/filter/toolchain/sanitizer | N F C X O | Xcode/Swift/runtime inventory E11, macOS E01/E02 및 iOS 18.5 E03 실행. helper 4-test fixture 허용 F4/E08. 나머지 7-runtime·5 SDK 전수 build·6.3·ASan/TSan은 이번 fresh 결과 없음. R61/R66 미완료. |
| M20 | evidence command × actual target/argv/toolchain/no-build | N F R S | 실제 validator·recorder E06에서 no-build PASS와 foreign root 허용 F2, 정상 deterministic Swift 인자 거부 F5 재현. 관련 기존 self-test E04 통과가 이 반례를 방어하지 못함. |
| M21 | evidence parser × run/test identity/order/summary/failure | N F C X S | 실제 parser E07에서 역순/중복 lifecycle 허용 F3 재현. incomplete/failed 대조군은 거부, 기존 parser self-test E04 통과. 실제 6.3 출력 호환성은 미검증. |
| M22 | snapshot/receipt/artifact × mutation/reuse/tamper/original retention | N F C R L S | snapshot·recorder·verifier·provenance와 attempt 보존 점검, E04 음성 대조 통과. artifact hash의 directory symlink 누락 F6/E09. 실제 CI artifact 다운로드→재개→승격 전체 경로 미검증. |
| M23 | CI jobs/aggregate/concurrency × required check / trusted execution | N F C X O S | 6 workflow·required aggregate·permissions·concurrency 점검, actionlint/CI self-tests E04 통과. 원격 main 보호 없음, repo-visible runner 0, 후보 CI 없음 E11. 취소/실패 job의 실제 원격 재현은 승인 범위 밖. |
| M24 | pre-tag/tag/publication × metadata/API baseline/producer provenance | N F R S | cd/release-evidence·RELEASING·API baseline lifecycle 점검. 현 CD는 tag/evidence 충족 시 공개 job으로 연결됨. verify-only rehearsal·정확한 6.0 tag producer·공개 설치 검증 없음. R65/R67 미완료, 외부 공개 작업 미실행. |

소스 영역 96개 파일을 [파일별 module/matrix/SHA 목록](../.build/comprehensive-review-20260923/source-inventory.json)에 연결했다. InnoFlow 9, Core 44, Macros 13, SwiftUI 5, Testing 25이며 DocC/resource도 포함하는 파일 수다. 테스트/consumer/docs/도구/배포 경계는 M17~M24까지 연결한다. 행의 source 점검은 실행 검증을 대신하지 않으며 범용 suite 통과만으로 모든 차원을 동적 검증했다고 표시하지 않는다. 파일을 inventory에 넣었다는 사실은 모든 줄/분기의 검증 완료를 의미하지 않는다.

## 증거 원장

아래는 모두 이번 실행의 fresh 증거다. 9월 18일 이력은 비교/계획 추적에만 사용하고 PASS 수에 포함하지 않았다. 원본은 git-ignored `.build/comprehensive-review-20260923/`에 있으므로 이 문서를 커밋하는 것만으로 원본까지 배포되지는 않는다.

| ID | 실행·관측 | 결과 / 원본 / 한계 |
| --- | --- | --- |
| E01 | `swift test --jobs 1 --no-parallel -Xswiftc -warnings-as-errors` | exit 0. library **713 tests / 58 suites**, macro **68 / 5**. library 실행 634.543초(독립 compile/subprocess 포함). [debug-tests.log](../.build/comprehensive-review-20260923/debug-tests.log). 전체 branch coverage 측정은 아님. |
| E02 | `swift test -c release --jobs 1 --no-parallel -Xswiftc -warnings-as-errors --filter 'EffectRunSchedulerTests\|FlowScopeTests\|DispatchDiagnosticsTests\|StoreScopeSelectionTests\|TestStoreInvariantTests\|FlowTaskCancellationBoundaryTests\|ReducerOutputTests\|TestStoreOutputMatchingTests\|ManualTestClockTests\|PhaseValidationReducerDiagnosticsTests'` | exit 0, **173 / 11**. [release-focused.log](../.build/comprehensive-review-20260923/release-focused.log). 전체 Release suite는 아니며 E01과 중복 테스트를 별도 신규 개수로 합산하지 않음. |
| E03 | genuine SwiftPM workspace `InnoFlow-Package`, iPhone 16 Pro iOS 18.5, `xcodebuild test`, jobs 1/parallel NO; StoreScopeSelection·CollectionScopeCache·SingleScopeCache·EffectRunScheduler·FlowScope | exit 0, **125 passed / 0 failed / 0 skipped**, 5 suites. [명령·로그](../.build/comprehensive-review-20260923/ios-focused.log), [xcresult](../.build/comprehensive-review-20260923/ios-focused.xcresult), [구조화 summary](../.build/comprehensive-review-20260923/ios-focused-summary.json). MCP 첫 시도는 300초 timeout: PASS로 계산하지 않음. 종료 확인 후 shell fallback으로 완료; 기존 사용자 xcodeproj는 사용/변경하지 않음. |
| E04 | static principle, principle self-test, parser/policy/workflow/required-results/CI-efficiency/coverage-workflow/verifier/snapshot/provenance/GitHub-run/toolchain self-tests, actionlint, coverage parser self-test | 모두 정상 호출 exit 0. [static.log](../.build/comprehensive-review-20260923/static.log), [selftests.log](../.build/comprehensive-review-20260923/selftests.log), 아래 상세 목록. coverage parser unit 5개 통과는 actual code coverage 아님. |
| E05 | actual Core를 링크한 public API consumer: capture index 0/1 selection, state 변경, scoped selection, observation 대조 | Debug/optimized Release 동일 반례 F1. [probe](../.build/comprehensive-review-20260923/selection_probe.swift), [Debug 결과](../.build/comprehensive-review-20260923/selection-probe.log), [Release 결과](../.build/comprehensive-review-20260923/selection-probe-release.log). 생산 테스트 트리에 추가하지 않음. |
| E06 | production `validate-command`, 실제 `xcodebuild -version … build`, official recorder, incomplete manifest verifier | [argv 결과](../.build/comprehensive-review-20260923/contract-probes.json), [잘못 발급된 sdk PASS receipt](../.build/comprehensive-review-20260923/no-build-receipt/sdk.receipt.json). 전체 manifest verifier는 **23개 missing으로 exit 1**: [대조](../.build/comprehensive-review-20260923/no-build-full-manifest-control.log). 전체 release 우회 성공 주장이 아님. |
| E07 | actual output parser에 정상/역순/중복/미종료/failed 입력 | [probe](../.build/comprehensive-review-20260923/contract_probes.rb), [입력·판정](../.build/comprehensive-review-20260923/contract-probes.json). 역순/반복 lifecycle 허용, 정상 허용·미종료/실패 거부. parser와 CLI 함수를 바꾸지 않음. |
| E08 | `scripts/run-focused-platform-runtime-tests-selftest.sh` | exit 0, **4개짜리 축소 fixture PASS** [runtime-subset.log](../.build/comprehensive-review-20260923/runtime-subset.log). fake xcrun/xcodebuild fixture이며 실제 플랫폼 4개 테스트 실행 근거가 아님. 실제 helper가 부족한 결과를 수용함을 검증. |
| E09 | production artifact manifest/hash 함수에 ordinary file + directory symlink + file symlink 비교 | [probe](../.build/comprehensive-review-20260923/artifact_probe.rb), [결과](../.build/comprehensive-review-20260923/artifact-probe.log). directory symlink 허용/대상 변경 후 digest 동일, file symlink는 exit 1 거부. 실제 xcresult 위조 end-to-end 성공까지 입증한 것은 아님. |
| E10 | 문서에서 실제 Swift block 추출, `swiftc -swift-version 6 -warnings-as-errors -typecheck` | [추출 runner](../.build/comprehensive-review-20260923/doc_snippet_probes.rb), [결과](../.build/comprehensive-review-20260923/doc-snippet-probes.json). GettingStarted exit 0, sample Sendable 지침 exit 1, 동일 예제에 MainActor를 명시한 양성 대조 exit 0. 전체 문서 전수 검사 아님. |
| E11 | GitHub read-only API, selected Xcode/Swift 및 simulator inventory | [main protection](../.build/comprehensive-review-20260923/main-protection.json), [effective rules](../.build/comprehensive-review-20260923/main-effective-rules.json), [repo-visible runners](../.build/comprehensive-review-20260923/remote-runners.json), [HEAD CI runs](../.build/comprehensive-review-20260923/candidate-remote-runs.json), [latest release](../.build/comprehensive-review-20260923/latest-release.json), [runtimes](../.build/comprehensive-review-20260923/runtimes.json). 조직 runner 전체 권한/할당은 별도 미확인. |
| E12 | 시작/종료 후보의 파일별 mode·hash 비교, 문서 계약/parity·diff·로컬 링크 검사 | [input-integrity.json](../.build/comprehensive-review-20260923/input-integrity.json): 변경 경로는 `CLAUDE.md`와 이 보고서뿐, production source/test/script/workflow 입력 동일. [종료 snapshot](../.build/comprehensive-review-20260923/candidate-after.json). 문서 계약/parity·`git diff --check` 통과; 24개 행과 로컬 증거 링크 존재 확인. 문서 변경으로 aggregate digest는 달라지므로 과거 receipt를 새 최종 후보 receipt라고 부르지 않음. |

E04 개별 로그(같은 evidence 폴더): `release-evidence-output-parser-selftest.rb.log`, `check-release-evidence-policy-selftest.sh.log`, `check-release-evidence-workflow-selftest.sh.log`, `check-required-ci-results-selftest.sh.log`, `check-ci-efficiency-selftest.sh.log`, `check-coverage-workflow-selftest.sh.log`, `verify-release-evidence-selftest.sh.log`, `release-candidate-snapshot-selftest.sh.log`, `write-github-evidence-provenance-selftest.sh.log`, `verify-github-evidence-run-selftest.sh.log`, `run-swift-toolchain-evidence-selftest.sh.log`, `actionlint.log`, `coverage-selftest.log`. 실행 비트 없는 parser/coverage-workflow self-test를 처음 직접 호출한 exit 126은 각각 `ruby`/`bash`로 재실행해 통과했다. 제품 실패로 분류하지 않는다.

E05 재실행: `swiftc -parse-as-library -swift-version 6 -I .build/debug .build/debug/InnoFlowCore.o .build/comprehensive-review-20260923/selection_probe.swift -o .build/comprehensive-review-20260923/selection-probe` 뒤 실행. 최적화 대조는 `-O`, `.build/release`의 같은 Core object를 사용했다.

## 확정 결함

이전 보고의 항목 수를 목표로 삼지 않았다. 실행 대상의 두 허점은 같은 F2로, runtime subset/삭제 회귀 누락은 같은 F4로 묶었다. 아래 F1/F6/F7은 이번에 추가로 확인한 반례이며 나머지는 기존 후보를 현재 구현에서 재현한 것이다.

### F1 — P2 / 제품: 같은 호출 위치의 서로 다른 selector capture가 충돌

- 위치: `Sources/InnoFlowCore/SelectedStore.swift:218` 및 `:395`, closure/dependency cache key 생성 `:284`, `:346`, `:373`.
- `selectValue(store, index: 0)` / `selectValue(store, index: 1)`가 같은 helper 내부 `store.select { $0.values[index] }`를 통과하면 두 handle이 같은 객체다. `[10,20]`에서 **10,10**, `[11,21]`로 변경 후에도 두 번째가 **11**을 반환한다. dependency/memoized/scoped overload에서도 재현했다.
- 원인: callsite·key path·value type 등은 구별하지만 captured parameter가 달라진 selector를 구별하지 않고 기존 resolver를 그대로 반환한다. 일반적인 재사용 helper나 반복 생성 row에서 잘못된 값을 표시할 수 있다.
- 대조: key-path selection은 변경된 `[11,21]`을 반환하고 일반 state 관찰은 알림 1회. Debug/Release 모두 같은 반례(E05). 기존 scope suite 통과는 이를 방어하지 않는다.
- 수정 시 검증할 조건: 명시적인 selector identity 또는 충돌 없는 선택 계약; 서로 다른 capture의 handle 격리, 같은 selector의 의도된 재사용, dependency pruning, 기존 handle을 새 resolver로 덮어쓰지 않는 동작. 구현은 이번 범위 밖.

### F2 — P1 / 검증: 실제 작업·실행 대상과 무관한 명령도 허용

- 위치: `docs/contracts/release-evidence-policy.json:48`~runtime 계약, `scripts/release-evidence-tool.rb:167`, helper의 `--package-root` 처리.
- `xcodebuild -version … build`는 버전만 출력하고 exit 0인데 SDK 명령 검사가 허용하며 실제 recorder가 `sdk-macos PASS` receipt를 발급했다. runtime 명령 뒤에 다른 `--package-root`를 넣어도 validator가 허용한다.
- 대조: 정상 SDK/runtime 명령 허용, 명시한 foreign `-project` 거부. 전체 manifest는 다른 23개 필수 항목 누락으로 정상 거부했다(E06). **SDK 항목 오인정**은 확정하되 전체 release 승격 우회까지 주장하지 않는다.
- 기존 R59에 해당. argument allowlist/최종 대상 결합/실제 build 결과가 필요하다.

### F3 — P1 / 검증: lifecycle의 순서·고유 실행 identity를 증명하지 못함

- 위치: `scripts/release-evidence-output-parser.rb:34`, `:161`.
- terminal→start 순서도 집계가 맞으면 통과. 같은 A의 start→pass를 두 번 반복하고 summary 2로 두면 `testCount=2`, `passedTests=[A]`로 통과한다(E07).
- 정상 입력은 통과, 미종료/failed leaf는 거부하는 대조를 유지했다. 단순 이름 중복 금지는 서로 다른 합법적인 테스트/parameter case를 깨뜨릴 수 있다. stable test identity와 이벤트 상태가 필요하다. R60.

### F4 — P1 / 검증: 필수 runtime 테스트 집합의 완전성 보장 없음

- 위치: `scripts/run-focused-platform-runtime-tests.sh:88`의 filters, policy `:53`~`:60`의 suite prefix.
- 필수 4 suite에서 각 1개만 남긴 fixture를 실제 helper가 PASS로 인정한다(E08). 현재 필터에는 `StoreScopeSelectionTests`가 없어 기존 삭제 관찰 수정의 플랫폼 회귀도 누락된다.
- E03에서 삭제 관찰을 포함한 iOS 18.5 실제 125개는 통과했다. 이는 이 결함을 고친 것도, 남은 7-runtime의 같은 결과를 입증한 것도 아니다. 기대 test ID inventory와 실제 xcresult를 대조해야 한다. R61.

### F5 — P2 / 검증: 정식 Swift 실행 명령과 exact argument 정책이 불일치

- 위치: `docs/contracts/release-evidence-policy.json:46`~`:47`.
- 문서화된 `--jobs 1 --no-parallel -Xswiftc -warnings-as-errors`를 붙인 Swift 6.4 wrapper 명령을 validator가 거부한다. 인자를 제거한 대조는 허용(E06). 실제 해당 옵션으로 E01은 성공한다.
- 통과한 테스트를 정식 evidence로 수집할 수 없게 만드는 계약 오류다. 테스트 옵션을 제거해 회피하지 말고 계약을 맞춰야 한다. R59/R66.

### F6 — P2 / 증거 무결성: 하위 directory symlink가 manifest에서 조용히 제외됨

- 위치: `scripts/release-evidence-tool.rb:29`.
- `File.directory?`로 skip한 다음 symlink 검사하므로 디렉터리를 가리키는 링크는 거부도 hash에도 포함되지 않는다. 링크 대상 파일을 바꿔도 digest가 동일했다. ordinary file은 포함되며 file symlink 대조는 거부(E09).
- fail-closed 링크 거부 계약을 위반하는 hash 범위 누락이다. 실제 유효한 xcresult를 위조해 전체 release를 통과시킨 사례는 아니다. lstat 기반 파일형 판정을 먼저 하고 directory/file/broken 링크를 모두 검증하는 회귀가 필요하다. R62의 artifact integrity에 포함할 대상.

### F7 — P2 / 문서 지침: mutable Observable class가 자동 Sendable이라는 예제가 컴파일 실패

- 위치: `Examples/InnoFlowSampleApp/CLAUDE.md:326`~`:331`.
- 현재 지침의 `@Observable final class UserModel: Sendable` 예제는 Swift 6에서 mutable `_name` 오류로 실패한다. 같은 코드에 MainActor isolation을 명시한 대조와 실제 GettingStarted 예제는 컴파일 성공(E10).
- framework runtime 실패와 분리한다. 후속 구현이 잘못된 동시성 패턴을 따르게 하는 지침 오류이며 canonical architecture/Sendable 설명을 정리해야 한다. R64.

## 미확정 후보

**C1 — 부모 store 해제 시 selected optionalValue 관찰 알림 계약.** E05에서 정상 state 변경 callback 1회, parent release 후 `isAlive=false`/`optionalValue=nil`인데 callback 0회였다. collection element 삭제 알림 계약은 이미 있지만 부모 자체 해제 때 observer invalidation까지 보장하는 명시적 계약은 확인하지 못했다. 따라서 관측된 현상은 확정이나 **제품 결함 판정은 보류**한다. 부모 수명 소유자와 UI 구독자의 기대를 먼저 명시하고, 필요하면 release notification을 계약/회귀에 추가해야 한다.

recorder 재실행이 성공 원본을 덮어쓸 것이라는 가설은 기존 경로 충돌 거부 및 attempt별 보존 코드/self-test로 제외했다. action queue의 순간 무제한 입력 역시 현재 설계상 backpressure 부재이지 새로 재현된 계약 위반으로 세지 않았다.

## 선택적 개선

다음은 현재 확정 결함 수나 필수 릴리스 차단 조건에 더하지 않는다.

1. 장시간 resource budget 대시보드: queue high-water, selection cache 수, active effect, dropped output을 같은 시나리오에서 추적. 현재 bounded history/단기 성능 검사와 장기 안정성을 구별하기 좋다.
2. canonical sample에 업무형 backpressure/취소 복구 예제: 버스트 입력·오프라인 retry는 사용자 domain effect 책임이라는 경계를 구체적으로 보여준다. core 자동 영속 복원이라는 새 약속은 만들지 않는다.
3. selector capture/lifetime 관련 문서 진단 가이드: F1 수정 후 사용자가 안전한 selection identity를 선택할 수 있게 예제를 추가한다. F1 자체 수정은 선택적 개선이 아니다.

API inventory, 문서 compile manifest, runtime test inventory, verify-only CD는 이미 R59~R67 완료 기준에 들어 있는 **필수 작업**이므로 편의 기능/backlog로 낮추지 않는다.

## 미검증 경계와 최종 상태

| 경계 | 현재 확인 / 남은 이유 | 닫는 데 필요한 증거 |
| --- | --- | --- |
| 정확한 Swift 6.3 | 현재 선택 toolchain은 6.4, 조사한 Xcode/표준 toolchain 위치에 6.3 없음 | 실제 6.3 환경에서 test·compile·parser 양성 대조. 설치/다른 runner 조달은 별도 결정 |
| 멀티플랫폼·sanitizer | macOS Debug/집중 Release 및 iOS 18.5 집중만 fresh 완료. 공식 runtime subset 검사가 F4로 부정확 | 수정된 ID inventory 후 5 SDK·8 runtime·ASan/TSan·전체 Release/coverage를 동일 최종 후보로 수집 |
| UI·문서·consumer | compile 소비자와 일부 snippet만 실행, sample 실제 화면/전체 snippet/API 전수·migration 미실시 | R63/R64 API diff·5.1.1 migration·전용 Catalyst·sample 흐름/DocC/code-block 분류 |
| 원격 보호 | main `protected=false`, effective rules `[]` | 승인 후 required checks/보호 적용 및 fresh API 확인; 로컬 YAML만으로 대체 불가 |
| trusted runner | repo-visible runners 0. 조직 runner 가용성/할당은 이번 확인 범위 밖 | 접근 가능한 trusted runner/label/toolchain과 실제 producer provenance |
| 후보 CI | HEAD dbd6… run 없음; dirty 후보는 원격 SHA와 동일하지 않음 | 승인된 clean candidate push/PR 후 정확한 SHA의 CI, 기존 다른 PR 결과 재사용 금지 |
| 정식 배포 evidence | no-build 반례용 manifest는 1/24이며 의도적으로 불완전. 전수 official manifest 없음 | 검증 결함 수정 후 최종 snapshot과 각 원본/receipt/attempt/provenance의 동일 후보 결합 |
| 공개 경계 | 현재 tag/evidence 성공이 CD 공개 job으로 이어짐. 6.0 tag/Release 없으며 verify-only rehearsal 없음 | R65 승인 경계 구현 → R66 local → R67 원격 → 별도 tag/공개 승인. 이번 dispatch/설정 변경 미실행 |

검토의 종료 기준은 **24개 영역에 근거 또는 구체적 미검증 사유를 남기는 것**으로 충족했다. 동적 검증이 남은 행을 PASS로 닫지는 않았다. 현재 판정은 제품 결함 F1, 검증 체계 F2~F6, 문서 지침 F7 및 C1/위 경계가 남아 **수정·추가 검증 전 6.0.0 release-ready 아님**이다. 아무 결함도 더 없다는 선언이나 모든 조합을 검증했다는 선언이 아니다.

이번 허용 변경은 root `CLAUDE.md`의 상시 검토 규칙, 이 보고서, 사용자가 요청한 memory note 및 ignored diagnostic evidence뿐이다. Apple platform skill의 취소·수명·delivery 점검 기준을 행렬에 반영했으며 production 코드·기존 테스트·정책·workflow의 사전 변경은 보존했다. 전역 AGENTS에는 같은 규칙이 이미 있어 중복 수정하지 않았다. 이 규칙은 이후 새 후보에서도 범위/제외/종료 기준을 먼저 정하도록 한다.

검토를 위해 생성한 임시 simulator `093EDD39-A533-487F-B47E-5D4F5FC717E2`만 테스트 종료 후 shutdown/delete했다. simulator 상태 자체는 삭제됐지만 실행 로그/xcresult는 보존했고 같은 runtime으로 재생성할 수 있다. 기존 simulator와 다른 작업의 build/test는 중단하지 않았다. coverage self-test가 생성한 Python cache는 삭제하지 않고 ignored evidence 폴더로 옮겼다.
