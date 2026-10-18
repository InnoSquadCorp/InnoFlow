# 2026-10-18 verification diagnostics

이 폴더는 [검증 원장](../../MULTIPLATFORM_VERIFICATION_2026_10_18.md)의
재현/감사 자료다. framework source, 정식 regression suite, CI gate를 수정한
것이 아니다. `.txt` 진단 파일은 **외부 scratch로 복사해서만** 실행한다.
특히 Android probe는 지정한 sample 앱 process만 조작하므로 명시된 serial,
package, APK, UID/PID, STOPPED 검사를 유지한다. 임의 기기/앱에 실행하지 않는다.

기준선 HEAD는 `0a7e685d3749b3dc28c6d5e56b932c9ad7fc0b11` + 기존 dirty 구현이다.
`candidate-inputs.sha256`은 Kotlin/TS/contracts/플랫폼 CI/도구 및 기존 shared
입력 125개를 식별한다. 의도적으로 바꾼 검증 문서와 main이 소유하는 Swift는
이 목록에서 제외한다. Swift는 main diff, 모든 기존 파일은 별도의 시작/종료
786개 파일 snapshot으로 검증했다. JSON에는 결과와 증거 해시를 남긴다.

```bash
# 현재 repo root에서 읽기 전용 입력 확인
shasum -a 256 -c docs/verification/2026-10-18/candidate-inputs.sha256
```

아래 diagnostic에는 당시 정확한 checkout/E2 경로가 들어 있다. 다른 머신이나
새 scratch로 옮기면 `root`/`evidence`/Maven artifact 경로와 serial만 먼저 맞추고
그 변경을 기록한다. fixture의 기대값/후조건은 바꾸지 않는다. 모든 진단에는
시간 제한을 두고, 끝나면 자신이 시작한 emulator/server만 정상 종료한다.

## F1 및 Kotlin 독립 대조

보존한 [runtime-probes.kt.txt](runtime-probes.kt.txt)는 실제 로컬 Maven
core/testing JAR를 사용한다. 원본 scratch는
`/tmp/innoflow-verification-20261018.vkS7JQI8/runtime`다.
필요한 `settings.gradle.kts` 내용:

```kotlin
pluginManagement { repositories { gradlePluginPortal(); mavenCentral() } }
dependencyResolutionManagement { repositories { mavenCentral() } }
rootProject.name = "innoflow-scope-verification-runtime"
```

`build.gradle.kts`는 다음과 같다. `artifacts`만 현재 repo의 local Maven
경로로 맞춘다. 실제 실행한 버전/의존성을 그대로 둔다.

```kotlin
plugins { kotlin("jvm") version "2.4.10"; application }
kotlin { jvmToolchain(11) }
val artifacts = "/Users/changwooson/Developer/InnoSquad/InnoFlow-worktrees/multiplatform/InnoFlow/kotlin/build/test-maven/com/innosquad/innoflow"
dependencies {
    implementation(files("$artifacts/inno-flow-core/1.0.0/inno-flow-core-1.0.0.jar"))
    implementation(files("$artifacts/inno-flow-testing/1.0.0/inno-flow-testing-1.0.0.jar"))
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.11.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.11.0")
}
application { mainClass.set("VerificationProbeKt") }
```

scratch의 `gradle.properties`에는 `org.gradle.jvmargs=-Xmx2g
-XX:MaxMetaspaceSize=1g -Dfile.encoding=UTF-8 -XX:+UseParallelGC`를 **한 줄**로,
`org.gradle.workers.max=2`를 다음 줄에 둔다. Kotlin 파일을
`src/main/kotlin/VerificationProbe.kt`로 복사한다.

```bash
./kotlin/gradlew -p <scratch> run --console=plain
./kotlin/gradlew -p <scratch> run --args=--assert-contract --console=plain
```

첫 명령은 정상 probe와 F1 관측을 함께 출력해 exit 0이다. 두 번째는 같은
관측에 명세 assertion을 켜 **현재 입력에서 exit 1**이어야 한다.

```text
capacity=1 error=null children=0 parentJoined=true
capacity=0 error=IllegalArgumentException children=1 parentJoined=false
SUMMARY positive probes passed; F1 constructor contract=FAIL
```

둘 다 constructor probe의 `finally`에서 parent를 cancel/join하므로 진단이
실제 orphan job을 남긴 채 끝나지 않는다. 나머지 positive probe는 순서/출력
매핑, ID 취소, 다중 대기자/대기 취소, no replay/nullable output/close,
TestStore negative assertion을 검사한다. 이것은 production 수정이 아니다.

## F2 KSP compile 대조

독립 Gradle Kotlin/JVM 2.4.10, KSP 2.3.11 프로젝트에서 local test-maven을
repository로 지정하고 다음 published dependency를 사용한다.

```kotlin
implementation("com.innosquad.innoflow:inno-flow-core:1.0.0")
ksp("com.innosquad.innoflow:inno-flow-ksp:1.0.0")
```

annotation이 있는 실제 실패 입력:

```kotlin
package consumer
import com.innosquad.innoflow.*
public class Outer<T>(public val outer: T) {
    public inner class Inner<U>(public val value: U)
}
@InnoFlow
public object Feature : FlowFeature<Outer<String>.Inner<Int>, Unit, Nothing> {
    override val initialState = Outer("owner").Inner(1)
    override val reducer = Reducer<Outer<String>.Inner<Int>, Unit, Nothing> {
        state, _ -> transition(state)
    }
}
```

`clean compileKotlin --console=plain`에서 잘못 생성된
`Outer.Inner<Int, String>` generic 인자 때문에 exit 1이다. 대조군은 같은
feature에서 annotation만 빼고 다음 factory를 명시적으로 선언하며 exit 0이다.

```kotlin
public fun create(scope: kotlinx.coroutines.CoroutineScope):
    FlowStore<Outer<String>.Inner<Int>, Unit, Nothing> =
    FlowStore(Feature.initialState, Feature.reducer, scope)
```

당시 별도 fixture는 `.../innoflow-review-20261018.ElsbEsg76Z/ksp`의
`-Pprobe=plain|function|suspend|innerManual|inner|alias`다. 앞 네 개는 exit 0,
`inner`는 잘못된 생성 코드, `alias`는 명시적 direct-implementation 진단으로
exit 1이다. suspend-function의 성공을 누락하거나 alias 제한을 F2와 같은
root cause로 계산하지 않는다. 영구 기존 fixture는 `scripts/check-ksp-fixtures.py`다.

## F3 SSR/UI 값 검사와 실제 package 대조

원본 `typescript/scripts/test-packed-consumer.mjs`의 `hasText: "Count: 8"`는
부분 문자열을 검사하고 SSR의 `/Count: 7/`도 마찬가지다. 아래 재현은 library
코드를 바꾸지 않고 소비자 표시만 바꾼다.

1. 현재 TS build 후 `packages`, `scripts`, `consumer-fixture`를 외부 scratch로
   복사하고 scratch `node_modules`는 현재 TS workspace의 도구 경로를 사용한다.
2. 복사본 `consumer-fixture/feature.mjs`의 한 줄만 다음처럼 바꾼다.

```diff
-    createElement("output", { "aria-live": "polite" }, `Count: ${count}`),
+    createElement("output", { "aria-live": "polite" }, `Count: ${count * 10}`),
```

3. 정상/복사본의 packages 디렉터리 `diff -qr`가 같고 위 소비자 표시만 다른지
   확인한다. 실제 재현에서 package bytes는 현재 산출물과 동일했다.
4. 같은 Node22.23.3/npm11.19.0/React19.2.8로 원본과 복사본 packed script를
   실행한다. 현재는 **둘 다 exit 0**이어서 정식 gate에 F3가 있다.
5. 보존한 [exact-packed-browser.mjs.txt](exact-packed-browser.mjs.txt)를 외부
   `.mjs`로 복사하고 각 생성된 consumer scratch 경로를 첫 인자로 실행한다.

```text
normal: SSR Count: 7; display [Count: 8, Count: 9, Count: 8]; exit 0
mutant: SSR Count: 70; display [Count: 80, Count: 90, Count: 80]; exit 1
```

정확한 probe는 JavaScript-disabled SSR page와 hydrate page를 분리하며,
정확한 role/name/text, console/page/recoverable error, screenshot을 보존한다.
`root`는 TS workspace, `scratch`는 실제 installed tarball consumer, screenshot
출력 위치는 E2다. 이 임시 probe가 정식 gate를 고친 것으로 간주하지 않는다.

## 추가 양성/실패 대조와 한계

- [typescript-probes.mjs.txt](typescript-probes.mjs.txt): 외부 `.mjs`로 복사해
  Node20.19.0/22.23.3 각각 실행했다. 기존 built workspace를 import하며
  **7개 positive group**에서 composition, cancellation, observers, TestStore,
  Provider의 정상/의도된 오류 후조건을 검사한다.
- [android-process26-control.py.txt](android-process26-control.py.txt): 자동
  `am kill` 실패 뒤 수행한 API26 전용 진단이다. 이 파일은 AVD를 시작하거나
  APK를 설치하지 않는다. 자신이 시작한 emulator-5582와 해당 debug sample이
  있어야 한다. STOPPED, 저장 상태, numeric PID, 정확한 cmdline/same UID를
  확인한 뒤 sample PID만 종료하고 재시작 값과 다른 PID를 검사한다.
  production의 `check-android-restoration.py`를 교체하지 않는다.
- [maven-advisories.mjs.txt](maven-advisories.mjs.txt): 다섯 published module의
  resolved runtimeClasspath 보고서를 읽고 OSV에 Maven coordinates/version을
  질의했다. pagination, 응답 길이/error와 known-vulnerable query-only 대조군을
  검사한다. 대상의 알려진 advisory 없음은 무결함/전체 보안 보증이 아니다.
- 원본 raw 로그/스크린샷/전체 XML과 전체 시작/종료 snapshot은 E2에 있다.
  임시 폴더가 사라져도 여기의 source, 기대값, 원장과 `results.json`은 남는다.
  수정 후에는 같은 source 입력이 아니므로 2026-10-18의 성공 로그를 새
  후보의 증거로 재사용하지 말고 영향 행을 다시 실행한다.
