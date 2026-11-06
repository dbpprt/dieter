plugins {
    id("org.jetbrains.kotlin.multiplatform")
}

// Only this module's public API reaches the Objective-C header. Keeping the
// runtime module and its Wire models unexported keeps the header small and
// avoids generating Objective-C adapters for every protocol message.
// The Mac links this module's macOS framework as DieterCore; the iOS app links
// :ui's framework, which exports this module under the same DieterCore name.
// Their Swift side is DieterKit's DieterPlatform target (apps/apple/DieterKit).
kotlin {
    iosArm64()
    iosSimulatorArm64()
    macosArm64 {
        binaries.framework {
            baseName = "DieterCore"
            isStatic = true
        }
    }

    sourceSets {
        all {
            languageSettings.optIn("kotlinx.cinterop.ExperimentalForeignApi")
            languageSettings.optIn("kotlin.time.ExperimentalTime")
        }
        appleMain.dependencies {
            implementation(project(":core:runtime"))
        }
        appleTest.dependencies {
            implementation(kotlin("test"))
        }
    }
}
