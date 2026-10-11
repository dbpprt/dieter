import groovy.json.JsonSlurper

plugins {
    id("com.android.application")
    alias(libs.plugins.compose.compiler)
}

// The distribution identity (config/identity.json) owns the application ID, so a
// fork changes one file.
val bundlePrefix =
    providers
        .fileContents(rootProject.layout.projectDirectory.file("../../config/identity.json"))
        .asText
        .map { (JsonSlurper().parseText(it) as Map<*, *>)["bundle_prefix"] as String }
        .get()

val releaseKeystorePath = providers.environmentVariable("DIETER_ANDROID_KEYSTORE_PATH")
val releaseKeystorePassword = providers.environmentVariable("DIETER_ANDROID_KEYSTORE_PASSWORD")
val releaseKeyAlias = providers.environmentVariable("DIETER_ANDROID_KEY_ALIAS")
val releaseKeyPassword = providers.environmentVariable("DIETER_ANDROID_KEY_PASSWORD")
val releaseVersionName =
    providers.environmentVariable("DIETER_RELEASE_VERSION").orElse("0.0.0-dev.0")
val releaseVersionCode =
    providers.environmentVariable("DIETER_RELEASE_VERSION_CODE").map { it.toInt() }.orElse(1)
val releaseSigningConfigured =
    listOf(
            releaseKeystorePath,
            releaseKeystorePassword,
            releaseKeyAlias,
            releaseKeyPassword,
        )
        .all { it.isPresent }

android {
    namespace = "com.getdieter.android"
    compileSdk = 37
    compileSdkMinor = 1

    defaultConfig {
        applicationId = "$bundlePrefix.android"
        minSdk = 26
        targetSdk = 37
        versionCode = releaseVersionCode.get()
        versionName = releaseVersionName.get()
    }

    signingConfigs {
        if (releaseSigningConfigured) {
            create("release") {
                storeFile = file(releaseKeystorePath.get())
                storePassword = releaseKeystorePassword.get()
                keyAlias = releaseKeyAlias.get()
                keyPassword = releaseKeyPassword.get()
            }
        }
    }

    buildTypes {
        // Maestro flows install this separate application, preserving the operator's
        // installed app and session.
        create("e2e") {
            initWith(getByName("debug"))
            applicationIdSuffix = ".e2e"
            matchingFallbacks += listOf("debug")
        }
        getByName("release") {
            if (releaseSigningConfigured) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    packaging {
        // Dieter uses only Termux's pure-Java VT emulator and renderer. The
        // bundled local-process JNI bridge is unused and is not 16 KiB aligned.
        jniLibs.excludes += setOf("**/libtermux.so")
    }
}

dependencies {
    // The shared Compose UI and, through it, all client logic in the core.
    implementation(project(":ui"))
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.compose.foundation)
    implementation(libs.androidx.compose.material3)
    implementation(libs.kotlinx.coroutines.android)
    implementation(libs.bouncycastle)
    implementation(libs.bouncycastle.tls)

    // JVM unit tests of the shell's pure logic (src/test/kotlin): no device or emulator.
    testImplementation(libs.junit)
    testImplementation(libs.kotlin.test.junit)
    testImplementation(libs.org.json)
}

// The adapter uses a package-private injection seam. Pin the exact AAR, so an
// accidental dependency substitution cannot silently change that contract.
apply(from = file("webrtc/sdk.gradle"))
