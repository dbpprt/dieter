import org.jetbrains.kotlin.gradle.ExperimentalKotlinGradlePluginApi
import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import org.jetbrains.kotlin.gradle.plugin.KotlinPlatformType
import org.jetbrains.kotlin.gradle.plugin.mpp.KotlinNativeTargetWithSimulatorTests

// Every core module targets the same platforms, so shared code can depend on
// any of them. Android and host JVM share the OkHttp-backed `jvmShared` set.
plugins {
    id("org.jetbrains.kotlin.multiplatform")
    id("com.android.kotlin.multiplatform.library")
}

group = "com.dbpprt.dieter"
version = providers.environmentVariable("DIETER_RELEASE_VERSION").orElse("0.0.0-dev.0").get()

kotlin {
    @OptIn(ExperimentalKotlinGradlePluginApi::class)
    applyDefaultHierarchyTemplate {
        common {
            group("jvmShared") {
                withCompilations { it.platformType == KotlinPlatformType.jvm || it.platformType == KotlinPlatformType.androidJvm }
            }
        }
    }

    jvm {
        compilerOptions { jvmTarget.set(JvmTarget.JVM_17) }
    }
    android {
        namespace = "com.dbpprt.dieter.core." + project.name
        // Matches apps/android, which builds against Android 37.1.
        compileSdk {
            version = release(37) { minorApiLevel = 1 }
        }
        minSdk = 26
    }
    iosArm64()
    iosSimulatorArm64()
    macosArm64()

    sourceSets.all {
        languageSettings.optIn("kotlin.uuid.ExperimentalUuidApi")
        languageSettings.optIn("kotlin.time.ExperimentalTime")
        languageSettings.optIn("kotlinx.coroutines.ExperimentalCoroutinesApi")
    }
}

// Native tests run on a caller-provided simulator; tests never boot or reuse an operator's device.
kotlin.targets.withType<KotlinNativeTargetWithSimulatorTests>().configureEach {
    testRuns.configureEach {
        providers.gradleProperty("dieter.simulator").orNull?.let { deviceId = it }
    }
}
