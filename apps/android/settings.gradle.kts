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
        maven("https://jitpack.io") {
            content { includeGroup("com.github.termux.termux-app") }
        }
    }
    versionCatalogs {
        // Kotlin, AGP, coroutines, and OkHttp versions shared with the included core.
        create("coreLibs") { from(files("../core/gradle/libs.versions.toml")) }
    }
}

rootProject.name = "DieterAndroid"
include(":app")
// The shared Kotlin client core (apps/core), consumed from source.
includeBuild("../core")
