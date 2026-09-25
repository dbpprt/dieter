import com.google.protobuf.gradle.id
import com.google.protobuf.gradle.proto
import java.security.MessageDigest

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.compose.compiler)
    alias(libs.plugins.protobuf)
}

val releaseKeystorePath = providers.environmentVariable("DIETER_ANDROID_KEYSTORE_PATH")
val releaseKeystorePassword = providers.environmentVariable("DIETER_ANDROID_KEYSTORE_PASSWORD")
val releaseKeyAlias = providers.environmentVariable("DIETER_ANDROID_KEY_ALIAS")
val releaseKeyPassword = providers.environmentVariable("DIETER_ANDROID_KEY_PASSWORD")
val releaseVersionName = providers.environmentVariable("DIETER_RELEASE_VERSION").orElse("0.1.0")
val releaseVersionCode = providers.environmentVariable("DIETER_RELEASE_VERSION_CODE").map { it.toInt() }.orElse(1)
val releaseSigningConfigured = listOf(
    releaseKeystorePath,
    releaseKeystorePassword,
    releaseKeyAlias,
    releaseKeyPassword,
).all { it.isPresent }

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
        testInstrumentationRunner = "com.dbpprt.dieter.e2e.DieterTestRunner"
        vectorDrawables.useSupportLibrary = true
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
        create("performance") {
            initWith(getByName("release"))
            applicationIdSuffix = ".e2e.performance"
            isDebuggable = false
            signingConfig = signingConfigs.getByName("debug")
            matchingFallbacks += listOf("release")
        }
    }

    // E2E and production-mode performance have separate test application IDs.
    testBuildType = providers.gradleProperty("dieter.testBuildType").orElse("debug").get().also {
        require(it in listOf("debug", "e2e", "performance")) { "Unsupported test build type" }
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    sourceSets {
        getByName("main") {
            proto {
                srcDir(rootProject.file("../../api/proto"))
            }
        }
    }

    packaging {
        // Dieter uses only Termux's pure-Java VT emulator and renderer. The
        // bundled local-process JNI bridge is unused and is not 16 KiB aligned.
        jniLibs.excludes += setOf("**/libtermux.so")
        resources.excludes += setOf(
            "META-INF/AL2.0",
            "META-INF/LGPL2.1",
            "META-INF/LICENSE.md",
            "META-INF/NOTICE.md",
        )
    }
}

protobuf {
    protoc {
        artifact = "com.google.protobuf:protoc:${libs.versions.protobuf.get()}"
    }
    plugins {
        id("grpc") {
            artifact = "io.grpc:protoc-gen-grpc-java:${libs.versions.grpc.get()}"
        }
        id("grpckt") {
            artifact = "io.grpc:protoc-gen-grpc-kotlin:${libs.versions.grpcKotlin.get()}:jdk8@jar"
        }
    }
    generateProtoTasks {
        all().configureEach {
            builtins {
                create("java") {
                    option("lite")
                }
            }
            plugins {
                id("grpc") {
                    option("lite")
                }
                id("grpckt") {
                    option("lite")
                }
            }
        }
    }
}

dependencies {
    implementation(libs.bouncycastle)
    implementation(libs.bouncycastle.tls)
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.graphics.path)
    implementation(libs.kotlinx.coroutines.android)
    // These two reusable Termux terminal modules are Apache-2.0 licensed.
    implementation(libs.termux.terminal.emulator)
    implementation(libs.termux.terminal.view)

    val composeBom = platform(libs.compose.bom)
    implementation(composeBom)
    androidTestImplementation(composeBom)
    implementation(libs.compose.ui)
    implementation(libs.compose.foundation)
    implementation(libs.compose.material3)
    implementation(libs.compose.material.icons)
    implementation(libs.compose.ui.tooling.preview)
    debugImplementation(libs.compose.ui.tooling)

    implementation(libs.grpc.android)
    implementation(libs.grpc.okhttp)
    implementation(libs.grpc.protobuf.lite)
    implementation(libs.grpc.stub)
    implementation(libs.grpc.kotlin.stub)
    implementation(libs.protobuf.javalite)
    compileOnly(libs.javax.annotation)

    testImplementation(libs.junit)
    androidTestImplementation(libs.androidx.junit)
    androidTestImplementation(libs.androidx.test.rules)
    androidTestImplementation(libs.espresso.core)
    androidTestImplementation(libs.compose.ui.test.junit4)
    debugImplementation(libs.compose.ui.test.manifest)
    add("e2eImplementation", libs.compose.ui.test.manifest)
    add("performanceImplementation", libs.compose.ui.test.manifest)
}

// The adapter uses a package-private injection seam. Pin the exact AAR, so an
// accidental dependency substitution cannot silently change that contract.
val screenWebRTCArtifact = configurations.create("screenWebRTCArtifact") { isTransitive = false }
dependencies.add(screenWebRTCArtifact.name, libs.webrtc)
val verifyScreenWebRTC = tasks.register("verifyScreenWebRTC") {
    val expected = "0a1627b1a48c2bc17d9a40d62fc47bd45166f44a311e95917f147c402de379b0"
    val stamp = layout.buildDirectory.file("screen-webrtc/verified.sha256")
    inputs.files(screenWebRTCArtifact)
    inputs.property("sha256", expected)
    outputs.file(stamp)
    doLast {
        val digest = MessageDigest.getInstance("SHA-256")
        screenWebRTCArtifact.singleFile.inputStream().use { input ->
            val buffer = ByteArray(65536)
            while (true) { val count = input.read(buffer); if (count < 0) break; digest.update(buffer, 0, count) }
        }
        val actual = digest.digest().joinToString("") { "%02x".format(it) }
        check(actual == expected) { "WebRTC adapter artifact changed; revalidate its codec and callback contract before updating the pin" }
        stamp.get().asFile.apply { parentFile.mkdirs(); writeText(actual + "\n") }
    }
}
tasks.named("preBuild") { dependsOn(verifyScreenWebRTC) }

// Build the audited Java surface-output contract around the unchanged native
// SDK. Every runtime class occurs exactly once in the resulting AAR.
val screenWebRTCAnnotations = configurations.create("screenWebRTCAnnotations") { isTransitive = false }
dependencies.add(screenWebRTCAnnotations.name, "androidx.annotation:annotation-jvm:1.10.0")
val patchedScreenWebRTC = layout.buildDirectory.file("screen-webrtc/dieter-webrtc.aar")
val buildScreenWebRTC = tasks.register("buildScreenWebRTC") {
    dependsOn(verifyScreenWebRTC)
    val source = rootProject.file("../../native/android-webrtc")
    val compiler = file(System.getProperty("java.home") + "/bin/javac")
    inputs.dir(source)
    inputs.files(screenWebRTCArtifact, screenWebRTCAnnotations)
    inputs.files(androidComponents.sdkComponents.bootClasspath)
    inputs.file(compiler)
    inputs.property("javaVersion", System.getProperty("java.version"))
    outputs.file(patchedScreenWebRTC)
    outputs.file(layout.buildDirectory.file("screen-webrtc/dieter-webrtc.json"))
    doLast {
        val process = ProcessBuilder("python3", source.resolve("build_sdk.py").absolutePath,
            "--aar", screenWebRTCArtifact.singleFile.absolutePath,
            "--android-jar", androidComponents.sdkComponents.bootClasspath.get().first().asFile.absolutePath,
            "--annotation", screenWebRTCAnnotations.singleFile.absolutePath,
            "--javac", compiler.absolutePath,
            "--output", patchedScreenWebRTC.get().asFile.absolutePath).inheritIO().start()
        check(process.waitFor() == 0) { "Failed to build the pinned WebRTC Java extension" }
    }
}
dependencies.add("implementation", files(patchedScreenWebRTC).builtBy(buildScreenWebRTC))
tasks.named("preBuild") { dependsOn(buildScreenWebRTC) }
