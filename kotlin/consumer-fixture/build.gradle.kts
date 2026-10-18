plugins {
    kotlin("jvm") version "2.4.10"
    id("com.google.devtools.ksp") version "2.3.11"
}

kotlin {
    jvmToolchain(11)
}

dependencies {
    implementation("com.innosquad.innoflow:inno-flow-core:1.0.0")
    ksp("com.innosquad.innoflow:inno-flow-ksp:1.0.0")

    testImplementation("com.innosquad.innoflow:inno-flow-testing:1.0.0")
    testImplementation(kotlin("test"))
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.11.0")
}

tasks.test {
    useJUnitPlatform()
}
