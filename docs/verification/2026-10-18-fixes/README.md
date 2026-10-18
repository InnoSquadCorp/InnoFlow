# Post-fix verification evidence — 2026-10-18

Canonical result: [63-row ledger](../../MULTIPLATFORM_FIX_VERIFICATION_2026_10_18.md).
Document status is Draft; release approval/publication was not performed.
This directory supplements, and does not overwrite, the pre-fix evidence in
`../2026-10-18/`. Its old manifest identifies different, intentionally unfixed
bytes. This candidate is HEAD `0a7e685d3749b3dc28c6d5e56b932c9ad7fc0b11`
plus the uncommitted inputs identified here.

## Identity and preserved evidence

- `candidate-inputs.sha256`: 128 runtime/build/contract/CI/shared inputs,
  SHA-256 `81719a85194d5671373a4888e1e69ff545057c4da09261085785891a37f86c9e`.
  Includes the original 125 paths and three new permanent regression/helper
  files. Verification prose/results/images are excluded to avoid self-reference.
- `results.json`: all 63 row results, change classification, red/green controls,
  toolchains, remaining gates and raw log hashes. A PASS covers its stated
  bounded test/inspection, not the entire abstract property for all inputs.
- `android-api26/34.json`, `*-ui.xml`, `*.png`: the standard probe's different
  PIDs, exact count, method, visible UI and screenshots. Compose/sample XML
  reports document 3 tests per API, not merely successful Gradle packaging.
- `unit/`: eight JUnit XML reports, 28 module/sample + 2 independent consumers,
  0 failures/errors/skips. Broad builds may reuse outputs; dedicated runs used
  `--rerun-tasks` to regenerate these tests.
- `maven-advisories.json`: 38 resolved runtime coordinates, 0 matching advisories,
  known-vulnerable query-only control 6. No vulnerable library was installed.
- Raw logs, original red controls, full before/after manifests, stopped activity
  dumps, dependency graph and complete device reports remain in
  `/tmp/innoflow-fixes-20261018.evgcyvL1`. Temporary logs are not permanent
  release artifacts; their hashes and the commands/observations below retain
  the evidence boundary if that scratch directory is later removed.

Run from the repository root:

```bash
shasum -a 256 -c docs/verification/2026-10-18-fixes/candidate-inputs.sha256
```

## Fresh reproduction

Use Java 11 and 17, SDK37, the repo-pinned Gradle/Kotlin/KSP/AGP toolchain,
npm11.19.0 and the lockfile's Playwright Chromium. Keep source/library versions
unchanged. Set these paths for your machine; they are the exact local inputs:

```bash
export JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home
export ANDROID_HOME=/Users/changwooson/Library/Android/sdk
npm exec --yes --package=node@22.23.3 --package=npm@11.19.0 -- bash scripts/test-multiplatform.sh
```

The script includes both permanent validation-tool controls:

```bash
python3 scripts/check-android-restoration-selftest.py
cd typescript
npm run test:packed:selftest
```

The restoration selftest runs 16 controls without a device. It checks native
kill success, protected API26 fallback, saved/STOPPED record isolation, real
API34 padded headers/fields, malformed/changed/replacement PIDs, foreign or
multi-argument cmdlines, run-as denial, pidof command error and surviving
processes. It does not claim device restoration by itself.

The packed selftest copies packages/scripts/fixture into an isolated scratch
and runs the **actual** packed gate with three fixture variants. Normal must
succeed. `count * 10` must fail the exact SSR oracle. A separate
`count === 7 ? count : count * 10` must keep server/first hydration valid and
fail the live browser oracle (`Count: 8` versus `Count: 80`). Merely failing
installation, compilation or hydration cannot satisfy these negatives.

Run Node20 separately, without overlapping `npm ci` and a browser/probe which
imports root tooling:

```bash
cd typescript
npm exec --yes --package=node@20.19.0 --package=npm@11.19.0 -- npm ci
npm exec --yes --package=node@20.19.0 --package=npm@11.19.0 -- npm test
INNOFLOW_REACT_VERSION=18.2.0 npm exec --yes --package=node@20.19.0 --package=npm@11.19.0 -- npm run test:packed
INNOFLOW_REACT_VERSION=19.2.8 npm exec --yes --package=node@20.19.0 --package=npm@11.19.0 -- npm run test:packed
npm exec --yes --package=node@20.19.0 --package=npm@11.19.0 -- npm run test:packed:selftest
```

Repeat the packed React18/19 commands with Node22.23.3. The final broad script
already covers Node22/React19 but does not replace the React18 consumer.

From the repo root, the dedicated fresh JVM/AAR/ABI commands were:

```bash
./kotlin/gradlew -p kotlin :sample:test :inno-flow-android:testDebugUnitTest :android-sample:testDebugUnitTest --rerun-tasks --max-workers=2 --console=plain
./kotlin/gradlew -p kotlin/consumer-fixture test --refresh-dependencies --rerun-tasks --console=plain
./kotlin/gradlew -p kotlin/android-consumer-fixture testDebugUnitTest assembleRelease --refresh-dependencies --rerun-tasks --max-workers=2 --console=plain
./kotlin/gradlew -p kotlin :inno-flow-core:checkKotlinAbi :inno-flow-testing:checkKotlinAbi :inno-flow-ksp:checkKotlinAbi :inno-flow-android:checkKotlinAbi :inno-flow-compose:checkKotlinAbi --rerun-tasks --max-workers=2 --console=plain
python3 scripts/check-ksp-fixtures.py
python3 scripts/check-android-api-selftest.py
python3 scripts/check-multiplatform-ci.py --self-test
python3 scripts/check-ci-workflows.py
./scripts/check-workflow-action-pins.sh
./scripts/check-workflow-job-timeouts.sh
```

The KSP positive consumer includes 11 annotated features, 7 new owner/type
regressions. Five unsupported feature cases must fail with their specific
diagnostic. No ABI golden changed. Wrong-golden AAR controls change only a
temporary reference, never production sources/baselines.

## Android device proof

Only owned emulators were used, one at a time: `Small_Phone_API_34` on
`emulator-5580`, then `Hestia_API_26` on `emulator-5582`. For each serial:

```bash
ANDROID_SERIAL=emulator-5582 ./kotlin/gradlew -p kotlin :inno-flow-compose:connectedDebugAndroidTest :android-sample:connectedDebugAndroidTest --no-parallel --max-workers=2 --console=plain
python3 scripts/check-android-restoration.py --serial emulator-5582
```

Replace the serial only with an explicitly selected owned device. Do not run
instrumentation and restoration concurrently on it. The probe reinstalls only
the debug sample, backgrounds it, requires the target ActivityRecord to have
saved STOPPED state, then tries `am kill`. If retained, it verifies a single
unchanged positive PID and exact cmdline and invokes `run-as PACKAGE kill -9 PID`.
It neither force-stops nor kills other apps/system/build/compiler processes.
Unexpected replacement PID or denied/ineffective termination fails the probe.

Fresh results: API34 `7446 -> 7747`, native am-kill; API26 `4158 -> 4362`,
guarded same-UID PID kill. Both restore exact `Count: 2`, no ANR dialog,
crash buffers 0 bytes. Both emulators were closed after evidence capture.
The first API34 parser mismatch is retained as an intermediate tooling failure,
not hidden or counted as product failure. The rerun passed after real header/
field compatibility was integrated and selftested.

## Additional diagnostic sources and limits

The unchanged external Kotlin and TypeScript probe sources remain in
`../2026-10-18/runtime-probes.kt.txt` and `typescript-probes.mjs.txt`; the full
setup is in that historical `REPRODUCERS.md`. Reuse the sources, not the old
expected F1 failure: with the new local Maven JAR,
`run --args=--assert-contract` now exits0, both capacity1 and rejected0 report
children0/jointrue. The other five runtime groups and seven TS groups run
against the new JAR/dist. Old native-timeout diagnostics that hardcode a known
leak expectation are not post-fix green oracles.

A separate fresh [native cancellation probe](native-cancellation-probe.kt.txt)
now checks domain failure, native timeout and explicit cancellation against
the corrected Maven core JAR. All three independent retries reach state1;
only domain failure fails the task and records one dispatch failure. Timeout
and explicit cancellation settle natively without dispatch-failure reporting.
Its exact scratch is `/tmp/innoflow-fixes-20261018.evgcyvL1/native` and log is
`kotlin-native-fresh.log`. To recreate after scratch removal, use the JVM
Gradle setup in the historical REPRODUCERS with the same dependencies and
set the application main class to `NativeCancellationProbeKt`, using this
source as `src/main/kotlin/NativeCancellationProbe.kt`. Run `run --console=plain`.

`exact-packed-browser.mjs.txt` in the old sidecar was copied to the new scratch
with only its evidence output path changed, then run on all four **new**
consumer scratches. SSR is inspected with JavaScript disabled, separately
from hydrated 8/9/8 and console/hydration checks. Maven query source was
likewise copied with the new evidence path and run on a new five-module graph.

Full workflow/device/registry acceptance is not established by these local
results. API23/35 hosted runtime, the final committed candidate's exact-SHA
main-push CI, registry permissions/publication/remote-only consumers and
maintainer approval remain separate gates. Swift behavior and release tests
are excluded; only exact main parity is proved. No commit, push, tag or
publication was performed. Optional O1/O2/O3 remain non-blocking proposals,
not silently implemented changes or proof of no remaining defects.
