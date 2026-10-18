plugins {
    kotlin("jvm") version "2.4.10"
    id("com.google.devtools.ksp") version "2.3.11"
}
kotlin {
    jvmToolchain(11)
    sourceSets.main { kotlin.setSrcDirs(listOf("cases/${providers.gradleProperty("fixtureCase").getOrElse("positive")}")) }
}
dependencies {
    implementation("com.innosquad.innoflow:inno-flow-core:1.0.0")
    ksp("com.innosquad.innoflow:inno-flow-ksp:1.0.0")
}
