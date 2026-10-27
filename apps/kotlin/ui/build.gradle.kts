plugins {
    id("org.jetbrains.kotlin.multiplatform")
    id("com.android.kotlin.multiplatform.library")
    alias(libs.plugins.compose.multiplatform)
    alias(libs.plugins.compose.compiler)
}

group = "com.getdieter"

version = providers.environmentVariable("DIETER_RELEASE_VERSION").orElse("0.0.0-dev.0").get()

// Mail and Mac Files ship the very same pinned offline renderer, including licenses.
val previewSource = rootProject.layout.projectDirectory.dir("../apple/mac/MarkdownPreview")
val previewResources = layout.buildDirectory.dir("generated/markdownResources")
val buildMarkdownPreview =
    tasks.register<Exec>("buildMarkdownPreview") {
        inputs.dir(previewSource.dir("src"))
        inputs.files(
            previewSource.file("build.mjs"),
            previewSource.file("package.json"),
            previewSource.file("package-lock.json"),
        )
        outputs.dir(previewResources)
        workingDir(previewSource)
        commandLine(
            "sh",
            "-c",
            "npm ci --ignore-scripts --no-audit --no-fund && node build.mjs --output \"\$1\"",
            "markdown-preview",
            previewResources.get().dir("files/markdown-preview").asFile.absolutePath,
        )
    }
val mergedResources = layout.buildDirectory.dir("generated/mailComposeResources")
val mergeMarkdownResources =
    tasks.register<Sync>("mergeMarkdownResources") {
        dependsOn(buildMarkdownPreview)
        from(layout.projectDirectory.dir("src/commonMain/composeResources"))
        from(previewResources)
        into(mergedResources)
    }

compose.resources {
    packageOfResClass = "com.getdieter.mobile.resources"
    customDirectory(
        sourceSetName = "commonMain",
        directoryProvider = mergeMarkdownResources.map { mergedResources.get() },
    )
}

kotlin {
    jvm()
    android {
        namespace = "com.getdieter.mobile"
        androidResources { enable = true }
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
            implementation(libs.kotlinx.serialization.json)
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
