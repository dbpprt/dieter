import org.jetbrains.kotlin.gradle.plugin.mpp.apple.XCFramework

plugins {
    id("org.jetbrains.kotlin.multiplatform")
    id("com.android.kotlin.multiplatform.library")
    id("org.jetbrains.compose") version "1.12.1"
    id("org.jetbrains.kotlin.plugin.compose") version "2.4.10"
}

group = "com.dbpprt.dieter"

version = providers.environmentVariable("DIETER_RELEASE_VERSION").orElse("0.0.0-dev.0").get()

compose.resources { packageOfResClass = "com.dbpprt.dieter.mobile.resources" }

kotlin {
    jvm()
    android {
        namespace = "com.dbpprt.dieter.mobile"
        compileSdk { version = release(37) { minorApiLevel = 1 } }
        minSdk = 26
    }
    val framework = XCFramework("DieterShared")
    listOf(iosArm64(), iosSimulatorArm64()).forEach { target ->
        target.binaries.framework {
            baseName = "DieterShared"
            isStatic = true
            export(project(":apple"))
            framework.add(this)
        }
    }
    sourceSets {
        all { languageSettings.optIn("kotlin.time.ExperimentalTime") }
        androidMain.dependencies {
            implementation("androidx.activity:activity-compose:1.13.0")
            implementation("com.github.termux.termux-app:terminal-emulator:v0.118.3")
            implementation("com.github.termux.termux-app:terminal-view:v0.118.3")
        }
        commonMain.dependencies {
            api(project(":shared"))
            implementation(compose.runtime)
            implementation(compose.foundation)
            implementation(compose.material3)
            implementation(compose.components.resources)
            implementation("org.jetbrains.compose.material:material-icons-core:1.7.3")
        }
        iosMain.dependencies { api(project(":apple")) }
        jvmTest.dependencies {
            implementation(project(":testing"))
            implementation(kotlin("test"))
        }
    }
}

tasks.named<Test>("jvmTest") {
    val isolatedGateway = project(":shared").layout.buildDirectory.file("fixture/isolated-gateway")
    dependsOn(":shared:buildIsolatedGateway")
    inputs
        .file(isolatedGateway)
        .withPropertyName("isolatedGateway")
        .withPathSensitivity(PathSensitivity.NONE)
    inputs
        .files(
            rootProject.fileTree("../../internal/harness/runtime") {
                include("**/*.mjs", "package.json", "package-lock.json")
                exclude("node_modules/**", ".npm/**", "**/*.test.mjs")
            }
        )
        .withPropertyName("mockHarnessRuntime")
        .withPathSensitivity(PathSensitivity.RELATIVE)
    systemProperty(
        "dieter.isolatedGateway",
        isolatedGateway.get().asFile.absolutePath,
    )
    environment(
        "DIETER_HARNESS_RUNTIME_DIR",
        rootProject.file("../../internal/harness/runtime").absolutePath,
    )
    testLogging { events("passed", "failed", "skipped") }
}
