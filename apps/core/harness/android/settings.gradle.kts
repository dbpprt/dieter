pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
    // Pin every version to the Dieter app's catalog.
    versionCatalogs {
        create("libs") {
            from(files("../../../android/gradle/libs.versions.toml"))
        }
    }
}

rootProject.name = "CoreHarnessAndroid"
// The Android app consumes the shared core the same way: as an included build.
includeBuild("../..")
include(":app")
