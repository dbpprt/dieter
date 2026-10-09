plugins {
    alias(coreLibs.plugins.android.application)
    alias(coreLibs.plugins.compose.compiler)
}

val reuseNativeAdapters =
    tasks.register<Sync>("reuseNativeAdapters") {
        from("../../../android/app/src/main/java") {
            include(
                "com/dbpprt/dieter/data/**",
                "com/dbpprt/dieter/screens/AndroidScreenMedia.kt",
                "com/dbpprt/dieter/screens/ScreenCanvasView.kt",
                "com/dbpprt/dieter/screens/ScreenCanvasHost.kt",
                "com/dbpprt/dieter/screens/ScreenInputConnection.kt",
                "com/dbpprt/dieter/screens/ScreenDecoderFactory.kt",
                "com/dbpprt/dieter/screens/AndroidClipboard.kt",
                "com/dbpprt/dieter/screens/ScreenClipboardProvider.kt",
                "com/dbpprt/dieter/sharedcore/ControlRTCBridge.kt",
            )
        }
        into(layout.buildDirectory.dir("generated/nativeAdapters"))
    }

// The shipping monochrome launcher icon, without copying its artwork.
val reuseLauncherIcon =
    tasks.register<Sync>("reuseLauncherIcon") {
        from("../../../android/app/src/main/res") {
            include(
                "drawable-nodpi/ic_dieter_foreground_monochrome.png",
                "drawable-nodpi/ic_dieter_monochrome.png",
                "drawable/ic_dieter_foreground_monochrome_layer.xml",
                "drawable/ic_dieter_monochrome_layer.xml",
                "mipmap-anydpi-v26/ic_launcher_monochrome.xml",
                "mipmap-anydpi-v26/ic_launcher_monochrome_round.xml",
                "mipmap-anydpi-v33/ic_launcher_monochrome.xml",
                "mipmap-anydpi-v33/ic_launcher_monochrome_round.xml",
            )
        }
        into(layout.buildDirectory.dir("generated/launcherIcon"))
    }

android {
    namespace = "com.dbpprt.dieter.spike"
    compileSdk = 37
    compileSdkMinor = 1
    defaultConfig {
        applicationId = "com.dbpprt.dieter.compose.spike"
        minSdk = 26
        targetSdk = 37
        versionName =
            providers.environmentVariable("DIETER_RELEASE_VERSION").orElse("0.0.0-dev.0").get()
        versionCode = 1
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }
    buildFeatures {
        compose = true
        buildConfig = true
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    sourceSets["main"]
        .kotlin
        .srcDir(layout.buildDirectory.dir("generated/nativeAdapters").get().asFile)
    sourceSets["main"].java.srcDir("../../../android/app/src/main/java/org/webrtc")
    sourceSets["main"].res.srcDir(layout.buildDirectory.dir("generated/launcherIcon").get().asFile)
    packaging.jniLibs.excludes += setOf("**/libtermux.so")
}

dependencies {
    implementation("com.dbpprt.dieter:mobile")
    implementation("androidx.activity:activity-compose:1.13.0")
    implementation("androidx.compose.foundation:foundation:1.12.1")
    implementation(coreLibs.kotlinx.coroutines.android)
    implementation("org.bouncycastle:bcprov-jdk18on:1.83")
    implementation("org.bouncycastle:bctls-jdk18on:1.83")
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
    androidTestImplementation("androidx.test:runner:1.7.0")
    androidTestImplementation("androidx.compose.ui:ui-test-junit4:1.12.1")
}

apply(from = rootProject.file("../../../native/android-webrtc/sdk.gradle"))

tasks.named("preBuild") { dependsOn(reuseNativeAdapters, reuseLauncherIcon) }
