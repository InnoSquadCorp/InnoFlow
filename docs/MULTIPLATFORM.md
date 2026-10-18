# Multiplatform InnoFlow

InnoFlow keeps its existing Swift implementation and adds two platform-native
1.0 lines in the same repository. The implementations share reducer fixtures
and boundary principles, not a lowest-common-denominator runtime.

The Kotlin/npm versions below are **1.0.0 release candidates in source**, not
an assertion that registry publication has occurred. Until the separately
authorized release, use locally built Maven artifacts or npm tarballs. See the
[readiness ledger](MULTIPLATFORM_1_0_READINESS.md) for evidence and external gates.

The [post-fix 63-row verification ledger](MULTIPLATFORM_FIX_VERIFICATION_2026_10_18.md)
supersedes the earlier defect findings: the two product defects and consumer
value-gate defect are fixed, and the standard process-restoration probe now
passes locally on API26 and API34. The
[hosted follow-up](MULTIPLATFORM_HOSTED_VERIFICATION_2026_10_18.md) also confirms
API23/35 real process restoration and all six exact-SHA branch CI jobs.
Exact-SHA main release CI and registry-only installation remain separate
release gates; no packages/tags were published and this is not public 1.0 approval.

| Platform | Version line | Authoring entry point | Runtime/UI integration |
| --- | --- | --- | --- |
| Apple | Swift `main` (published baseline `6.0.2`) | `@InnoFlow` | `Store` and SwiftUI adapter from `main` |
| Kotlin/Android | `1.0.0` | `@InnoFlow` + KSP, or `FlowFeature` | `StateFlow`, ViewModel ownership, lifecycle-aware Compose |
| React/TypeScript | `1.0.0` | `defineFlow` | external-store hooks and a typed React provider |

## Kotlin and Android 1.0

The Maven coordinates are:

- `com.innosquad.innoflow:inno-flow-core:1.0.0`
- `com.innosquad.innoflow:inno-flow-ksp:1.0.0`
- `com.innosquad.innoflow:inno-flow-testing:1.0.0`
- `com.innosquad.innoflow:inno-flow-android:1.0.0`
- `com.innosquad.innoflow:inno-flow-compose:1.0.0`

The core targets JVM 11. The Android and Compose adapters require Java 17,
Android API 23 or newer, and compile SDK 37. Releases are published to this
repository's GitHub Packages registry, so consumers must configure GitHub
Packages credentials.

Add the repository in `settings.gradle.kts` (even public GitHub Packages
downloads require an authorized token with package-read access):

```kotlin
dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
        maven {
            url = uri("https://maven.pkg.github.com/InnoSquadCorp/InnoFlow")
            credentials {
                username = providers.environmentVariable("GITHUB_ACTOR").orNull
                password = providers.environmentVariable("GITHUB_TOKEN").orNull
            }
        }
    }
}
```

The tested producer/consumer toolchain is Kotlin 2.4.10, KSP 2.3.11, AGP
9.3.1 and Gradle 9.7.0, with Java 11 and 17 installed for builds. The Kotlin compiler/KSP pair
is part of the supported build configuration; arbitrary older compiler
versions are not claimed compatible with the generated metadata.

```kotlin
plugins {
    id("com.google.devtools.ksp") version "2.3.11"
}

dependencies {
    implementation("com.innosquad.innoflow:inno-flow-core:1.0.0")
    implementation("com.innosquad.innoflow:inno-flow-android:1.0.0")
    implementation("com.innosquad.innoflow:inno-flow-compose:1.0.0")
    ksp("com.innosquad.innoflow:inno-flow-ksp:1.0.0")
    testImplementation("com.innosquad.innoflow:inno-flow-testing:1.0.0")
}
```

Macro-first authoring stays concise while the ordinary `FlowFeature` protocol
remains the fallback:

The annotated feature must be top-level and non-generic; its state/action/output
types may still include generic owners and inner classes (for example,
`Owner<String>.Inner<Int>`), nullable types, projections and functions. Generic
owner arguments are preserved at each nesting level. A typealias used for a
state type is supported; spelling the `FlowFeature` supertype itself through
a typealias remains outside the direct-supertype KSP contract.

```kotlin
@InnoFlow
class CounterFeature : FlowFeature<CounterState, CounterAction, Nothing> {
    override val initialState = CounterState()
    override val reducer = Reducer<CounterState, CounterAction, Nothing> { state, action ->
        when (action) {
            CounterAction.Increment -> transition(state.copy(count = state.count + 1))
        }
    }
}

class CounterViewModel : ViewModel() {
    val store = ownFlowStore(
        CounterFeatureFlow.create(CounterFeature(), viewModelScope),
    )
}

@Composable
fun Counter(viewModel: CounterViewModel) {
    val state by viewModel.store.collectStateWithLifecycle()
    Button(onClick = { viewModel.store.send(CounterAction.Increment) }) {
        Text("${state.count}")
    }
}
```

`inno-flow-android` closes an owned store with its `ViewModel`.
`inno-flow-compose` also provides `CollectOutputsWithLifecycle` for ephemeral
events. The runnable `kotlin/android-sample` builds a real APK using generated
KSP code, the ViewModel adapter, and Compose lifecycle collection.

KSP supports top-level public/internal classes or objects that directly
implement `FlowFeature`. Generated factory visibility follows the feature.
Default packages and backtick-escaped identifiers are covered. Private,
nested, generic, abstract or indirectly inherited declarations produce a
specific diagnostic instead of invalid generated code. Use `createFlowStore`
or explicit `FlowStore` construction when KSP does not fit the declaration.

`SavedStateHandle` persistence is explicit application code, not automatic
runtime serialization. The Android sample restores its count through
`CounterViewModel`; its process-death test checks a new PID, not only Activity
recreation. Persist durable state, never ephemeral output events.

For local artifacts before publication:

```bash
./kotlin/gradlew -p kotlin publishAllPublicationsToTestRepository
./kotlin/gradlew -p kotlin/consumer-fixture test --refresh-dependencies
./kotlin/gradlew -p kotlin/android-consumer-fixture testDebugUnitTest assembleRelease --refresh-dependencies
```

The independent consumers resolve `kotlin/build/test-maven`, not Gradle
project dependencies. Another application can use that directory as a Maven
repository. `-PinnoFlowRepository=<url>` switches the fixtures to a remote
registry for post-publication checks.

## TypeScript and React 1.0

The npm packages are ESM-only and require Node.js 20.19 or newer for tooling:

```bash
npm install @innosquad/inno-flow@1.0.0 \
  @innosquad/inno-flow-react@1.0.0
npm install --save-dev @innosquad/inno-flow-testing@1.0.0
```

```tsx
const counter = defineFlow({
  initialState: { count: 0 },
  reducer: (state, action: { type: "increment" }) =>
    transition({ count: state.count + 1 }),
});

const store = createStore(counter);

function Counter() {
  const count = useFlowSelector(store, (state) => state.count);
  return <button onClick={() => store.send({ type: "increment" })}>{count}</button>;
}
```

The core has no React dependency. The React adapter is based on
`useSyncExternalStore`, supports selector equality and StrictMode store
replacement, and has an actual Vite production consumer under
`typescript/examples/react-consumer`.

React 18.2 and React 19 are supported. Type declarations and browser consumers
are tested with TypeScript 5.9.3. Tooling is tested on Node 20.19.0 and Node
22; this Node requirement is for package tooling, not an added Node runtime
dependency in a browser bundle. These packages do not claim React Native
device-runtime validation.

`defineFlow` deliberately remains a typed factory instead of adding a Babel or
TypeScript transform. This keeps macro-first intent without coupling consumers
to a custom compiler pipeline.

### SSR and ownership

Create one store per server request and initialize the client store with the
same serialized state used for server rendering. Never share a mutable
module-global store between server requests. Hooks use the immutable
`store.getInitialState()` for the server/first hydration snapshot; later
client dispatches are reflected after hydration. `useFlowState` and
`useFlowSelector` also accept an explicit `getServerSnapshot` when the app
owns that snapshot separately. It must return a stable, matching value.

The provider subscribes to the supplied store but does not close it on
unmount. The creator owns its lifetime and must call `store.close()` at the
appropriate boundary. Manually installed output subscriptions must be
unsubscribed, typically in a React effect cleanup. Keep selectors pure and
state immutable; choose an equality function that describes the selected
value rather than mutating it to avoid renders.

### Testing and local npm packages

`TestStore` compares state, actions and outputs structurally by default,
including nested objects, Map/Set/Date values and explicit `undefined` state.
Supply custom `stateEquals`, `actionEquals` or `outputEquals` comparators for cyclic
graphs or domain-specific equality. A failed dispatch is observed through its
returned task; `store.finish()` waits for currently active tasks, not a history
of already-settled failures.

```bash
cd typescript
npm ci
npm test
npm exec playwright install chromium --only-shell
INNOFLOW_REACT_VERSION=18.2.0 npm run test:packed
INNOFLOW_REACT_VERSION=19.2.8 npm run test:packed
npm pack --workspace=@innosquad/inno-flow
npm pack --workspace=@innosquad/inno-flow-react
npm pack --workspace=@innosquad/inno-flow-testing
```

Install the resulting `.tgz` files together in an application. The packed
consumer gate uses a clean directory outside the workspace and actual
tarballs, including public type errors, SSR, hydration, browser interactions
and browser-console checks. It does not use workspace source aliases.

## Runtime limits and failure policy

Both runtimes default to `actionCapacity = 1024`. Accepted actions remain
FIFO; overload rejects the new synchronous dispatch with an explicit task
failure. Kotlin effect sends suspend under backpressure. This bounds queued
actions, not arbitrary effect fan-out or external resource use. Keep fan-out
bounded and effects cancellation-aware. Reducer/effect failures fail their
own dispatch while allowing a later independent retry.

Output is live, non-replaying notification, not storage. Kotlin buffers 64
pending output events and reports overload drops through instrumentation.
TypeScript invokes live output callbacks synchronously and isolates callback
errors. A cancelled dispatch cannot emit later actions or output; underlying
non-cooperative I/O must still be stopped by the effect implementation.
`close()` is idempotent and rejects later sends. See the full
[semantics contract](../contracts/SEMANTICS.md) for platform differences.

## Validation and releases

The separate `Multiplatform CI` workflow checks the shared contract and runs
the Kotlin/Android and TypeScript/React jobs. Swift keeps `main`'s CI selection
and release-preflight policy.

```bash
./scripts/test-multiplatform.sh
```

The gate runs the shared runtime fixtures, reducer/lifetime/resource tests,
positive and negative KSP compilation, Android lint and debug/release APKs,
all five Kotlin API gates, independent JVM and Android Maven-artifact
consumers, React DOM tests, a Vite production build, npm package/type/source-map
checks and a real packed-package browser consumer. Install the Playwright
browser first when running locally. Runtime Android instrumentation and real
process restoration run separately in CI on API 23/35.

Public Kotlin 1.x API signatures are checked against committed baselines.
Android/Compose gates inspect actual release AARs, not an empty JVM source
set; deliberate bad-baseline controls verify both gates reject API drift.
Source-level/type contracts also have independent consumers; an ABI dump
alone is not a proof of all Kotlin source/nullability compatibility. Intentional
breaking public API changes require a new major version. Baselines are
reviewed and never automatically updated by CI.

The release lines are intentionally independent:

- bare semantic-version tags such as `6.0.2` follow the Swift release gate
  defined on `main`;
- `kotlin/v1.0.0` validates and publishes the five Maven artifacts;
- `npm/v1.0.0` validates and publishes the three public npm packages.

See [`RELEASING_MULTIPLATFORM.md`](RELEASING_MULTIPLATFORM.md) for the release
checklist. Creating a tag is a maintainer action; validation alone never
publishes a package.
