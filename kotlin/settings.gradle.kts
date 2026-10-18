pluginManagement {
    repositories {
        gradlePluginPortal()
        google()
        mavenCentral()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "inno-flow-kotlin"

include(":inno-flow-core")
include(":inno-flow-android")
include(":inno-flow-compose")
include(":inno-flow-testing")
include(":inno-flow-ksp")
include(":sample")
include(":android-sample")
