plugins {
    kotlin("jvm")
    id("com.google.devtools.ksp")
}

kotlin {
    jvmToolchain(11)
}

dependencies {
    implementation(project(":inno-flow-core"))
    ksp(project(":inno-flow-ksp"))

    testImplementation(project(":inno-flow-testing"))
    testImplementation(kotlin("test"))
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.11.0")
    testImplementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.11.0")
}

tasks.test {
    useJUnitPlatform()
    systemProperty(
        "innoflow.contracts",
        rootProject.projectDir.parentFile.resolve("contracts").absolutePath,
    )
}
