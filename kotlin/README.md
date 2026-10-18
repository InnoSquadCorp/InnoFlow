# InnoFlow for Kotlin and Android 1.0

The Kotlin implementation is split into five publishable modules:

- `inno-flow-core`: reducer, effects, dispatch-tree tasks, typed output,
  `StateFlow`, instrumentation, and composition.
- `inno-flow-ksp`: optional `@InnoFlow` store-factory generation.
- `inno-flow-testing`: transition, action, state, and output assertions.
- `inno-flow-android`: `ViewModel` ownership and automatic close.
- `inno-flow-compose`: lifecycle-aware state and output collection.

`android-sample` is a real Compose APK using generated KSP code.
`consumer-fixture` and `android-consumer-fixture` resolve locally published
JVM/Maven and Android AAR artifacts, not project dependencies.

The JVM core targets Java 11. Builds need Java 11/17 and Android SDK 37;
Android runtime support starts at API 23. The pinned Gradle wrapper verifies
its distribution checksum. These are source 1.0.0 candidates until the
separate registry release is authorized and verified.

```bash
./gradlew \
  test \
  :android-sample:assembleDebug \
  :android-sample:assembleRelease \
  :inno-flow-android:lintRelease \
  :inno-flow-compose:lintRelease \
  :inno-flow-core:checkKotlinAbi \
  :inno-flow-testing:checkKotlinAbi \
  :inno-flow-ksp:checkKotlinAbi \
  :inno-flow-android:checkKotlinAbi \
  :inno-flow-compose:checkKotlinAbi \
  publishAllPublicationsToTestRepository
./gradlew -p consumer-fixture test --refresh-dependencies
./gradlew -p android-consumer-fixture testDebugUnitTest assembleRelease --refresh-dependencies
python3 ../scripts/check-ksp-fixtures.py
python3 ../scripts/check-android-api-selftest.py
```

Root sends reject overload explicitly; effect sends suspend for queue
capacity. Immutable state and cancellation-aware, bounded effect fan-out
remain application responsibilities. Close stores or bind them to a
ViewModel; persist durable state explicitly through SavedStateHandle.

See [`../docs/MULTIPLATFORM.md`](../docs/MULTIPLATFORM.md) for installation and
lifecycle examples.
