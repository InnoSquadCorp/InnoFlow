import org.gradle.api.publish.PublishingExtension
import com.android.build.api.artifact.SingleArtifact
import com.android.build.api.variant.LibraryAndroidComponentsExtension
import kotlinx.validation.KotlinApiBuildTask
import kotlinx.validation.KotlinApiCompareTask

plugins {
    kotlin("jvm") version "2.4.10" apply false
    id("com.google.devtools.ksp") version "2.3.11" apply false
    id("com.android.library") version "9.3.1" apply false
    id("com.android.application") version "9.3.1" apply false
    id("org.jetbrains.kotlin.plugin.compose") version "2.4.10" apply false
    id("org.jetbrains.kotlinx.binary-compatibility-validator") version "0.18.1" apply false
}

allprojects {
    group = "com.innosquad.innoflow"
    version = "1.0.0"
}

subprojects {
    pluginManager.withPlugin("com.android.library") { configureAndroidAbi() }
    pluginManager.withPlugin("maven-publish") {
        extensions.configure<PublishingExtension> {
            repositories {
                maven {
                    name = "Test"
                    url = uri(rootProject.layout.buildDirectory.dir("test-maven").get().asFile)
                }
            }
        }
    }
}

// AGP 9 built-in Kotlin needs explicit BCV wiring. Inspect the actual release
// AAR so Android/Compose cannot silently escape public API validation.
fun Project.configureAndroidAbi() {
    val abiRuntime = configurations.create("androidAbiRuntime") {
        isCanBeConsumed = false
    }
    dependencies.add(abiRuntime.name, "org.jetbrains.kotlin:kotlin-metadata-jvm:2.4.10")
    dependencies.add(abiRuntime.name, "org.ow2.asm:asm:9.7.1")
    dependencies.add(abiRuntime.name, "org.ow2.asm:asm-tree:9.7.1")
    extensions.getByType<LibraryAndroidComponentsExtension>().onVariants { variant ->
        if (variant.buildType == "release") {
            val aar = variant.artifacts.get(SingleArtifact.AAR)
            val classes = tasks.register<Sync>("extractAndroidApiClasses") {
                from(aar.map { archive -> zipTree(archive.asFile) })
                include("classes.jar")
                into(layout.buildDirectory.dir("android-api/input"))
            }
            val generate = tasks.register<KotlinApiBuildTask>("generateAndroidApi") {
                dependsOn(classes)
                inputJar.set(layout.buildDirectory.file("android-api/input/classes.jar"))
                outputApiFile.set(layout.buildDirectory.file("android-api/${project.name}.api"))
                runtimeClasspath.from(abiRuntime)
            }
            tasks.register<KotlinApiCompareTask>("checkKotlinAbi") {
                group = "verification"
                projectApiFile.set(layout.projectDirectory.file("api/${project.name}.api"))
                generatedApiFile.set(generate.flatMap { task -> task.outputApiFile })
            }
            tasks.register<Copy>("updateKotlinAbi") {
                from(generate.flatMap { task -> task.outputApiFile })
                into(layout.projectDirectory.dir("api"))
            }
            tasks.named("check") { dependsOn("checkKotlinAbi") }
        }
    }
}
