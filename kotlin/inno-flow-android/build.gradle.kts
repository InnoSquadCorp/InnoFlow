plugins {
    id("com.android.library")
    `maven-publish`
}

android {
    namespace = "com.innosquad.innoflow.android"
    compileSdk = 37

    defaultConfig {
        minSdk = 23
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
    api("androidx.lifecycle:lifecycle-viewmodel-ktx:2.11.0")

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.11.0")
}

publishing {
    publications {
        register<MavenPublication>("release") {
            afterEvaluate {
                from(components["release"])
            }
            artifactId = "inno-flow-android"
            pom {
                name = "InnoFlow Android"
                description = "Android ViewModel lifecycle ownership for InnoFlow"
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
