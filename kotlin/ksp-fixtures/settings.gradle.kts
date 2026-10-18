pluginManagement {
    repositories { gradlePluginPortal(); google(); mavenCentral() }
}
dependencyResolutionManagement {
    repositories {
        maven { url = uri("../build/test-maven") }
        mavenCentral()
    }
}
rootProject.name = "innoflow-ksp-contracts"
