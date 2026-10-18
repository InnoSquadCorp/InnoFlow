plugins {
    kotlin("jvm")
    `java-library`
    `maven-publish`
}

kotlin {
    explicitApi()
    jvmToolchain(11)

    @OptIn(org.jetbrains.kotlin.gradle.dsl.abi.ExperimentalAbiValidation::class)
    abiValidation {}
}

java {
    withSourcesJar()
}

dependencies {
    api(project(":inno-flow-core"))
}

publishing {
    publications {
        create<MavenPublication>("maven") {
            from(components["java"])
            artifactId = "inno-flow-testing"
            pom {
                name = "InnoFlow Testing"
                description = "TestStore assertions for InnoFlow Kotlin reducers"
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
