# Releasing Kotlin, Android, TypeScript, and React

The Swift release flow remains in `RELEASING.md`. Do not reuse a bare Swift tag
for a Kotlin or npm release.

Regular Kotlin/Android and TypeScript/React validation runs in the separate
`Multiplatform CI` workflow (`.github/workflows/ci-multiplatform.yml`). It checks
the shared contract before running both platform jobs. Swift CI selection,
required-result evaluation, and release preflight follow `main` independently.

## Required gate

Use the [post-fix verification ledger](MULTIPLATFORM_FIX_VERIFICATION_2026_10_18.md)
and its candidate-input manifest rather than the earlier pre-fix snapshot.
Its 63-row scope distinguishes corrected defects, local consumer proof,
device limitations and unpublished/hosted release gates. The local candidate
is not approved for public release, despite the corrected local gates.

From a clean checkout with Java 11/17, Android SDK 37, Node.js 20.19 or newer, and
npm 11.19.0:

```bash
./scripts/test-multiplatform.sh
```

Confirm that the intended public API changes are reflected in the Kotlin ABI
files and that all three npm package versions match.

The local script is necessary but not sufficient: before a release tag,
require a successful `Multiplatform CI` **main-branch push** run on the exact
tagged commit. That workflow also covers the Node 20.19/22 matrix, both React
major versions, Android API 23/35 lifecycle/recreation/process-restoration
tests, and independent packed consumers. A successful older SHA or a PR-only
run is not release evidence. The release workflows query that exact-SHA
result and fail closed when it is absent or unsuccessful.

Run `python3 scripts/check-android-api-selftest.py` with the same Java/Android
environment to verify both actual AAR API comparisons reject an intentionally
wrong temporary baseline. Run the supported device gate independently:

```bash
./kotlin/gradlew -p kotlin :inno-flow-compose:connectedDebugAndroidTest :android-sample:connectedDebugAndroidTest --no-parallel
ANDROID_HOME=/path/to/android/sdk python3 scripts/check-android-restoration.py --serial emulator-5554
```

The restoration probe installs only the sample debug APK on the specified
device. It first requires a saved STOPPED Activity, then attempts `am kill`.
If Android retains that process (observed on API26), it rechecks the same
single positive PID and exact app cmdline and uses `run-as` to kill only that
debug sample PID as its own UID. PID changes, unsaved/foreground state,
run-as denial and surviving processes fail closed; no force-stop is used.
It requires a different nonempty PID and the exact saved visible count on
relaunch, preserving screenshot, XML, stopped Activity dump and result JSON.
Do not run it concurrently with instrumentation on the same device.

The local script and contract CI also run
`python3 scripts/check-android-restoration-selftest.py` (20 safety/UI-capture controls).
`npm run test:packed:selftest` in `typescript` runs the actual packed gate in
isolated normal/SSR-wrong/live-browser-wrong consumers. The SSR mutation and
post-hydration UI mutation must both fail their specific exact-value oracle;
an install/build/hydration error is not an acceptable negative-control pass.
These controls are also enforced before their platform's package publication.

## Kotlin and Android

1. Set `version` in `kotlin/build.gradle.kts`.
2. Update and review the Kotlin ABI dumps only for intentional public API
   changes.
3. Run the required gate.
4. Review the readiness ledger, registry access and repository permissions.
5. After explicit maintainer release approval and exact-SHA main CI, push
   `kotlin/v<version>` from that reviewed commit.

The release workflow republishes to GitHub Packages only after tests, Android
lint/APK assembly, ABI checks, local Maven publication, and the independent
JVM/AAR consumers and KSP diagnostic fixtures pass. After publication, it
resolves both independent consumers from GitHub Packages, not the local test
repository. GitHub Packages read/write permissions and registry credentials
are external release requirements, not proven by a local Maven build.

## TypeScript and React

1. Set the same version in the core, React, and testing `package.json` files.
2. Update internal peer dependency ranges when required.
3. Run the required gate and inspect each `npm pack --dry-run` manifest.
4. Verify package ownership, npm trusted-publishing/token configuration and
   the exact-SHA main CI gate.
5. After explicit maintainer release approval, push `npm/v<version>` from
   that reviewed commit.

The npm workflow uses provenance and publishes only the three public package
workspaces. The Vite example is private and cannot be published.

After publication the workflow installs the exact registry versions into the
independent browser consumer (`INNOFLOW_FROM_REGISTRY=1`). Manual dispatch on
a tag also validates its version, but a manual run does not publish;
publication requires the corresponding tag-push event. Workflows have
timeouts and per-tag concurrency groups. Registry publication is immutable
and is not atomic across several packages: if a partial publication fails,
inspect the registry state and recover deliberately, never overwrite a
published version or advance a success claim from local evidence alone.

No tag, GitHub Release, Maven or npm publication is implied by preparing this
source candidate. Record the exact SHA, CI links and post-publication consumer
results in the readiness ledger before calling a public release complete.
