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

rootProject.name = "core"

// Wire models for the daemon/gateway API and the core's own on-device records.
include(":model")

// All client business logic, platform-extension contracts, and their tests.
include(":shared")

// Test kit: fakes, scripted transport, fixture launcher, fault proxy.
include(":testing")

// The Swift-facing façade; only its API is exported to Objective-C/Swift.
include(":apple")

// The Compose Multiplatform UI of the Android and iOS apps.
include(":mobile")
