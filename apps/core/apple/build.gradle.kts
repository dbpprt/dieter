import org.jetbrains.kotlin.gradle.plugin.mpp.apple.XCFramework

plugins {
    id("org.jetbrains.kotlin.multiplatform")
}

// Only this module's public API reaches the Objective-C header. Keeping the
// shared module and its Wire models unexported keeps the header small and
// avoids generating Objective-C adapters for every protocol message.
// The framework is DieterShared; the apps' Swift side of it is SharedCore.
kotlin {
    val xcframework = XCFramework("DieterShared")
    listOf(iosArm64(), iosSimulatorArm64(), macosArm64()).forEach { target ->
        target.binaries.framework {
            baseName = "DieterShared"
            isStatic = true
            xcframework.add(this)
        }
    }

    sourceSets {
        all {
            languageSettings.optIn("kotlinx.cinterop.ExperimentalForeignApi")
            languageSettings.optIn("kotlin.time.ExperimentalTime")
        }
        appleMain.dependencies {
            implementation(project(":shared"))
        }
        appleTest.dependencies {
            implementation(kotlin("test"))
        }
    }
}
