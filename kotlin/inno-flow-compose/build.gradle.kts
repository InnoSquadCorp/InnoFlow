plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.plugin.compose")
    `maven-publish`
}

android {
    namespace = "com.innosquad.innoflow.compose"
    compileSdk = 37

    defaultConfig {
        minSdk = 23
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    buildFeatures {
        compose = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    publishing {
        singleVariant("release") {
            withSourcesJar()
        }
    }
}

dependencies {
    api(project(":inno-flow-core"))
    api(platform("androidx.compose:compose-bom:2026.08.00"))
    api("androidx.compose.runtime:runtime")
    api("androidx.lifecycle:lifecycle-runtime-compose:2.11.0")
    androidTestImplementation(platform("androidx.compose:compose-bom:2026.08.00"))
    debugImplementation(platform("androidx.compose:compose-bom:2026.08.00"))
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
    androidTestImplementation("androidx.test:runner:1.7.0")
    androidTestImplementation("androidx.compose.ui:ui-test-junit4")
    androidTestImplementation("androidx.compose.material3:material3")
    androidTestImplementation("androidx.activity:activity-compose:1.13.0")
    androidTestImplementation("androidx.lifecycle:lifecycle-runtime-testing:2.11.0")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
}

publishing {
    publications {
        register<MavenPublication>("release") {
            afterEvaluate {
                from(components["release"])
            }
            artifactId = "inno-flow-compose"
            pom {
                name = "InnoFlow Compose"
                description = "Lifecycle-aware Compose state and output adapters for InnoFlow"
                url = "https://github.com/InnoSquadCorp/InnoFlow"
                licenses {
                    license {
                        name = "MIT License"
                        url = "https://opensource.org/licenses/MIT"
                    }
                }
                developers {
                    developer {
                        id = "innosquad"
                        name = "InnoSquad"
                        url = "https://github.com/InnoSquadCorp"
                    }
                }
                scm {
                    connection = "scm:git:https://github.com/InnoSquadCorp/InnoFlow.git"
                    developerConnection = "scm:git:ssh://git@github.com/InnoSquadCorp/InnoFlow.git"
                    url = "https://github.com/InnoSquadCorp/InnoFlow"
                }
            }
        }
    }

    repositories {
        maven {
            name = "GitHubPackages"
            url = uri("https://maven.pkg.github.com/InnoSquadCorp/InnoFlow")
            credentials {
                username = providers.environmentVariable("GITHUB_ACTOR").orNull
                password = providers.environmentVariable("GITHUB_TOKEN").orNull
            }
        }
    }
}
