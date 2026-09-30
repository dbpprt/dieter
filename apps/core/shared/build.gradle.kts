plugins {
    id("dieter.kmp")
}

kotlin {
    sourceSets {
        commonMain.dependencies {
            api(project(":model"))
            api(libs.kotlinx.coroutines.core)
            api(libs.okio)
            implementation(libs.kotlinx.serialization.json)
        }
        getByName("jvmSharedMain").dependencies {
            implementation(libs.okhttp)
        }
        commonTest.dependencies {
            implementation(project(":testing"))
            implementation(kotlin("test"))
        }
    }
}

// End-to-end tests drive the core against a disposable gateway and daemon built
// from this repository; they never contact an operator's gateway.
val isolatedGateway = layout.buildDirectory.file("fixture/isolated-gateway")
val buildIsolatedGateway by tasks.registering(Exec::class) {
    workingDir = rootProject.file("../..")
    val go = providers.gradleProperty("dieter.go").orElse("go").get()
    commandLine(go, "build", "-o", isolatedGateway.get().asFile.absolutePath, "./scripts/isolated-gateway")
    outputs.file(isolatedGateway)
    outputs.upToDateWhen { false } // Go's build cache decides what to rebuild.
}

tasks.named<Test>("jvmTest") {
    dependsOn(buildIsolatedGateway)
    systemProperty("dieter.isolatedGateway", isolatedGateway.get().asFile.absolutePath)
    // The mock harness answering fixture turns runs on the repository's Node runtime.
    environment("DIETER_HARNESS_RUNTIME_DIR", rootProject.file("../../internal/harness/runtime").absolutePath)
    maxParallelForks = 1
    testLogging {
        events("passed", "failed", "skipped")
        exceptionFormat = org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL
    }
}
