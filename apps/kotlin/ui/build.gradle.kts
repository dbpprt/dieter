plugins {
    id("org.jetbrains.kotlin.multiplatform")
    id("com.android.kotlin.multiplatform.library")
    alias(libs.plugins.compose.multiplatform)
    alias(libs.plugins.compose.compiler)
}

group = "com.getdieter"

version = providers.environmentVariable("DIETER_RELEASE_VERSION").orElse("0.0.0-dev.0").get()

compose.resources { packageOfResClass = "com.getdieter.mobile.resources" }

kotlin {
    jvm()
    android {
        namespace = "com.getdieter.mobile"
        compileSdk { version = release(37) { minorApiLevel = 1 } }
        minSdk = 26
    }
    // The iOS app links this framework as DieterCore. It exports the :core:apple
    // façade, so iOS needs no second Kotlin framework.
    listOf(iosArm64(), iosSimulatorArm64()).forEach { target ->
        target.binaries.framework {
            baseName = "DieterCore"
            isStatic = true
            export(project(":core:apple"))
        }
    }
    sourceSets {
        all { languageSettings.optIn("kotlin.time.ExperimentalTime") }
        androidMain.dependencies {
            implementation(libs.androidx.activity.compose)
            implementation(libs.termux.terminal.emulator)
            implementation(libs.termux.terminal.view)
        }
        commonMain.dependencies {
            api(project(":core:runtime"))
            implementation(compose.runtime)
            implementation(compose.foundation)
            implementation(compose.material3)
            implementation(compose.components.resources)
            implementation(libs.compose.material.icons.core)
        }
        iosMain.dependencies { api(project(":core:apple")) }
        jvmTest.dependencies {
            implementation(kotlin("test"))
            implementation(libs.kotlinx.coroutines.test)
        }
    }
}

tasks.named<Test>("jvmTest") { testLogging { events("passed", "failed", "skipped") } }
