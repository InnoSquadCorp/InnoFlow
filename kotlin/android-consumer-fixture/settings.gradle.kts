pluginManagement {
    repositories { google(); gradlePluginPortal(); mavenCentral() }
}
dependencyResolutionManagement {
    repositories {
        maven {
            url = uri(providers.gradleProperty("innoFlowRepository").getOrElse("../build/test-maven"))
            if (url.scheme == "https") {
                credentials {
                    username = providers.environmentVariable("GITHUB_ACTOR").orNull
                    password = providers.environmentVariable("GITHUB_TOKEN").orNull
                }
            }
        }
        google(); mavenCentral()
    }
}
rootProject.name = "innoflow-aar-consumer"
