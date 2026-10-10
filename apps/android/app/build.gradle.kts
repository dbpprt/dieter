plugins {
    alias(coreLibs.plugins.android.application)
    alias(coreLibs.plugins.compose.compiler)
}

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
    namespace = "com.dbpprt.dieter"
    compileSdk = 37
    compileSdkMinor = 1

    defaultConfig {
        applicationId = "com.dbpprt.dieter"
        minSdk = 26
        targetSdk = 37
        versionCode = releaseVersionCode.get()
        versionName = releaseVersionName.get()
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
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
        // Journeys install a separate application, preserving the operator's app and session.
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

    testBuildType =
        providers.gradleProperty("dieter.testBuildType").orElse("debug").get().also {
            require(it in listOf("debug", "e2e")) { "Unsupported test build type" }
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
    implementation("com.dbpprt.dieter:mobile")
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(libs.compose.foundation)
    implementation(libs.compose.material3)
    implementation(coreLibs.kotlinx.coroutines.android)
    implementation(libs.bouncycastle)
    implementation(libs.bouncycastle.tls)

    androidTestImplementation(libs.androidx.junit)
    androidTestImplementation(libs.androidx.test.runner)
    androidTestImplementation(libs.compose.ui.test.junit4)
}

// The adapter uses a package-private injection seam. Pin the exact AAR, so an
// accidental dependency substitution cannot silently change that contract.
apply(from = rootProject.file("../../native/android-webrtc/sdk.gradle"))
