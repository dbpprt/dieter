pluginManagement {
    includeBuild("build-logic")
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
        maven("https://jitpack.io") { content { includeGroup("com.github.termux.termux-app") } }
    }
}

rootProject.name = "dieter"

// Wire models for the daemon/gateway API, the core's on-device records, and
// the client contract (client.proto).
include(":core:model")

// All client business logic, platform-extension contracts, and their unit tests.
include(":core:runtime")

// Test kit: fakes, slice folds, the JVM platform, and the isolated fixture launcher.
include(":core:testing")

// The Swift-facing façade; only its API is exported to Objective-C/Swift as DieterCore.
include(":core:apple")

// End-to-end tests against a disposable gateway and daemon built from this
// repository (opt-in: they need Go and Node).
include(":core:e2e")

// The Compose Multiplatform UI of the Android and iOS apps.
include(":ui")

// The Android app shell.
include(":android")
