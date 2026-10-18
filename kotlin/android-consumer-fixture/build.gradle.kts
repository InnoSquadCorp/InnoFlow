plugins {
    id("com.android.application") version "9.3.1"
    id("org.jetbrains.kotlin.plugin.compose") version "2.4.10"
    id("com.google.devtools.ksp") version "2.3.11"
}
android {
    namespace = "com.example.innoflow.consumer"
    compileSdk = 37
    defaultConfig {
        applicationId = namespace
        minSdk = 23
        targetSdk = 37
        versionCode = 1
        versionName = "1.0.0"
    }
    buildFeatures { compose = true }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}
val innoFlowVersion = providers.gradleProperty("innoFlowVersion").getOrElse("1.0.0")
dependencies {
    implementation("com.innosquad.innoflow:inno-flow-core:$innoFlowVersion")
    implementation("com.innosquad.innoflow:inno-flow-android:$innoFlowVersion")
    implementation("com.innosquad.innoflow:inno-flow-compose:$innoFlowVersion")
    ksp("com.innosquad.innoflow:inno-flow-ksp:$innoFlowVersion")
    implementation(platform("androidx.compose:compose-bom:2026.08.00"))
    implementation("androidx.activity:activity-compose:1.13.0")
    implementation("androidx.compose.material3:material3")
    testImplementation("com.innosquad.innoflow:inno-flow-testing:$innoFlowVersion")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.11.0")
}
