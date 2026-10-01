# 계약 fixture의 같은 Mac 전후 측정

## 목적과 실행 경계

이 실험은 테스트 계약을 줄이지 않고 중복 컴파일을 줄이는 변경을 비교한다.
`Contract Fixture Measurement`는 GitHub-hosted `macos-26`,
`/Applications/Xcode_26.6.app`, Swift 6.3에서만 실제 측정을 허용한다.
사용자 Mac에서 실행하거나 release preflight를 대체하는 도구가 아니다.

- baseline: `d581ecc9b4d82b19d7fdcb37ec989a63ef73ebd5`
- candidate: PR 이벤트에 기록된 정확한 head SHA
- PR head: `perf/shared-macro-consumer-fixtures`
- PR base branch: `ci/flow-automation-standardization`
- 이벤트: 같은 저장소 PR의 `opened`, `synchronize`, `reopened`, Draft 포함
- 워크플로: `.github/workflows/contract-fixture-measurement.yml`

새 워크플로가 default branch에 설치되기 전에는 `workflow_dispatch`에
의존할 수 없으므로 PR 이벤트로 실행한다. `pull_request_target`, write token,
새 credential, self-hosted runner, Actions build cache를 사용하지 않는다.
기존 checkout/upload-artifact SHA pin을 그대로 쓰며 두 checkout 모두
`persist-credentials: false`, 권한은 `contents: read`다. 기준 branch가 나중에
움직여도 비교 baseline은 위 SHA로 고정된다. 이벤트의 base SHA도 별도로 기록한다.
기존 CI 필터, 필수 검사, 테스트, timeout은 변경하지 않는다.

## 측정 순서와 시간 정의

같은 runner에서 다음 ABBA 순서로 실행한다.

1. baseline clean root build → discovery → 17개 test 실행
2. candidate clean root build → discovery → 17개 test 실행
3. candidate warm root build → discovery → 새로운 process에서 같은 17개 실행
4. baseline warm root build → discovery → 새로운 process에서 같은 17개 실행
5. candidate `CompiledHarnessCacheTests` 8개 별도 correctness validation

두 revision은 별도 checkout과 `.build`를 사용한다. clean은 해당 checkout에
`.build`가 없었다는 뜻이다. warm은 같은 revision의 root `.build` 재사용이다.
매 test invocation에는 별도 `TMPDIR`를 주므로 외부 macro consumer의 임시 package,
SwiftSyntax source build tree, process-local harness cache는 다시 만들어진다.
서로 다른 invocation의 macro scratch 경로가 겹치면 실패한다.
OS file cache, 네트워크 상태, SwiftPM 다운로드 cache까지 cold라고 주장하지 않는다.

Root build는 `swift build --build-tests --jobs 1
--disable-experimental-prebuilts -Xswiftc -warnings-as-errors`다.
전체 test target을 컴파일하되 실행은 아래 17개로 고정한다. 후보가 추가한 cache
unit test의 컴파일 비용도 candidate root build에 포함된다.
이후 `swift test list --skip-build`와 `swift test --skip-build --no-parallel
--filter ...`로 build와 실행 시간을 분리한다. 각 suite의 `.serialized`도 유지된다.

- `rootBuild.elapsedSeconds`: 해당 clean/warm root build command wall time
- `discovery.elapsedSeconds`: 테스트 열거 overhead, 따로 기록
- `testExecution.elapsedSeconds`: 17개 실행 전체 wall time. 내부 compile도 포함
- `buildPlusTestSeconds`: root build + test execution
- `includingDiscoverySeconds`: 위 합계 + discovery
- `subprocesses.directSwiftcSeconds`: 관찰된 직접 harness swiftc 호출 시간의 합
- `subprocesses.nestedSwiftBuildSeconds`: 관찰된 외부 macro consumer swift build 시간의 합
- `runnerElapsedSeconds`: toolchain 확인, 준비, 검증, 추가 cache validation을 포함한 runner 전체

내부 compiler 시간은 test execution에 이미 포함되므로 total에 다시 더하지 않는다.
Swift frontend/driver의 하위 process 개수나 CPU time을 세는 지표가 아니다.
Observer의 파일 기록 overhead는 test execution에 포함되며 따로 빼지 않는다.
별도 cache 8개 validation은 paired phase timing과 비교 비율에 포함하지 않는다.

신규 job 한도는 60분, Python runner 전체 deadline은 3,300초다.
한도가 다하면 process group에 종료 신호를 보내고 실패로 기록한다.
기존 테스트 예산을 늘리거나 실패한 시나리오를 건너뛰어 성공으로 만들지 않는다.

## 고정된 테스트 범위와 검증

17개 function ID를 runner의 `METHODS` / `EXPECTED_IDS`에 명시한다.

- `StaleScopeCrashContractTests`: 모든 7개
- `StaleScopeReleaseContractTests`: 모든 3개
- `PhaseMapCrashContractTests`: 모든 4개
- `ConditionalReducerReleaseContractTests`: 모든 2개
- `CompileContractTests/exportedMacroFeaturesWorkAcrossTargetBoundaries()`: 1개

앞의 네 suite는 suite 전체를 선택한다. source inventory, 실제 discovery,
성공한 display name 17개, 마지막 17-test passing summary를 모두 확인한다.
누락, 중복, 추가 test, skip, 실패는 측정 실패다. 두 revision의
`SubprocessContractTests.swift`는 observer 삽입 전에 byte-identical이어야 한다.
각 시나리오의 기존 assertion은 그대로 실행된다.

각 test process에서 다음 구조적 결과도 관찰값으로 확인한다.

| 항목 | baseline | candidate |
| --- | ---: | ---: |
| 16개 subprocess 시나리오의 새 process 실행 | 16 | 16 |
| 직접 harness `swiftc` 호출 | 16 | 5 |
| 그중 `-Onone` / `-O` | 7 / 9 | 2 / 3 |
| macro consumer `swift build` 호출 | 11 | 11 |
| 성공한 macro variant | 9 | 9 |
| 의도적으로 실패한 availability control | 2 | 2 |
| invocation마다 cold로 시작한 macro scratch root | 10 | 2 |
| macro consumer runtime control | 1 | 1 |

성공 variant는 기본, `MANUAL_PATH`, `FEATURE_A/B/C`의 모든 비어 있지 않은
7가지 조합이다. baseline은 global `-D`를, candidate는 consumer manifest의
각 target `.define`을 관찰한다. 두 negative control은 no-flag 원본 fixture이며,
둘 다 nonzero와 `unavailable` diagnostic을 요구한다. application-extension
control은 global `-Xswiftc -application-extension`을 유지한다. 모든 macro build에서
`--disable-experimental-prebuilts`와 `-warnings-as-errors`가 있어야 한다.

16개 runtime 시나리오는 정확한 scenario environment key/value와 성공/실패 결과를
대조한다. crash 성공은 child의 nonzero 종료와 원래 테스트의 diagnostic assertion을
뜻한다. compiler 호출 수만 줄고 runtime 시나리오가 누락되면 실패한다.

## Observer와 증거

측정 runner는 깨끗한 일회용 checkout인지 확인한 뒤 양쪽
`TestSupport.runCapturedProcess`의 동일한 `process.run()/waitUntilExit()` 위치에
같은 observer 코드를 삽입한다. 인자, child 환경, 반환값, assertion, 실패 동작을
변경하지 않는다. observer 기록은 best-effort이며 기록 누락은 사후 검증 실패다.
원본 3개 test source hash, 삽입 후 TestSupport hash, observer hash와 정확한 diff를 남긴다.
저장되는 environment는 각 호출에 명시된 scenario key/value뿐이며 전체 환경은 저장하지 않는다.

Artifact 이름은 `contract-fixture-measurement-<candidate SHA>-<attempt>`다.

- `summary.json`: SHA, PR/run/toolchain, 시간 정의, phase별 결과, 오류와 최종 상태
- `baseline-observer.diff`, `candidate-observer.diff`: 동일 observer 삽입 내역
- `<revision>-<clean|warm>/result.json`: 해당 phase의 command receipt와 검증 결과
- `root-build/`, `discovery/`, `tests/`: 인자/exit/elapsed receipt와 원본 stdout/stderr
- `events/`, `events.json`: 각 captured process의 인자, 종료, elapsed, manifest와 원본 출력
- `candidate-cache-validation/`: paired timing에서 제외한 cache 8개 검사
- `toolchain/`: 실제 Xcode/Swift version 원본 출력

실패 시에도 원본 로그와 부분 JSON을 남기고 `always()` artifact upload를 시도한다.
checkout/setup 실패에는 초기 `not-started` JSON이 남는다. 강제 runner 종료,
GitHub 장애, artifact upload 실패까지 보존을 보장하지는 못한다.
부분 성공이나 timeout을 최종 성공으로 읽으면 안 된다.

## 로컬 도구 검증과 한계

Linux에서 재현 가능한 selftest:

```sh
python3 -B -m unittest discover -s scripts/tests -p 'test_contract_fixture_measurement.py' -v
scripts/check-workflow-action-pins.sh
scripts/check-workflow-job-timeouts.sh
ruby scripts/check-ci-efficiency.rb
```

Python selftest는 fake Swift process로 정상/실패/timeout, 모든 variant와 scenario,
source fallback, extension mode, 직접 compiler count, 새 scratch root, discovery와
최종 결과, 시간 이중 합산 방지를 검증한다. Fake 시간이 실제 Mac 성능 증거는 아니다.

추가로 실제 Linux Swift 6.3.3에서 `swift test list --skip-build`의 function ID,
괄호를 포함한 단일 function filter, 8개 cache test의 실제 결과 출력 파싱을 확인했다.
동일 observer 본문도 Linux Foundation `Process`로 Swift 6 strict mode와
warnings-as-errors 컴파일 후 child stdout/stderr, 종료값, JSON 기록을 확인했다.
이 확인은 Xcode/Foundation macOS 실행을 대체하지 않는다.

실제 macOS 전후 시간과 16→5 / 10→2 관찰 count는 이 PR의 GitHub run artifact가
완료되기 전까지 미검증이다. 한 ABBA 측정은 통계적 속도 보장이나 전체 test suite,
release, Apple platform matrix의 통과 근거가 아니다. runner 부하와 다운로드 변동을
함께 해석해야 한다. parser가 새 출력 형식을 못 읽으면 실패로 닫히며, 그때는 원본
로그를 검토해 parser를 고친 뒤 두 revision을 같은 조건으로 다시 실행한다.

CLI와 출력 확인의 기준: [SwiftPM Swift 6.3 test command 구현](https://github.com/swiftlang/swift-package-manager/blob/swift-6.3-RELEASE/Sources/Commands/SwiftTestCommand.swift).
