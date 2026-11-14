// End-to-end tests of the core and the shared UI against a disposable gateway
// and daemon built from this repository (tools/fixtures/gateway) with the mock
// harness. They never contact an operator's gateway or daemon. They need Go and
// Node (`npm --prefix internal/harness/runtime ci`), so `check` on the other
// modules stays fast; run them with `./gradlew :core:e2e:test`.
plugins {
    id("org.jetbrains.kotlin.jvm")
}

kotlin {
    compilerOptions {
        // Same bytecode level as the multiplatform modules' JVM target.
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
        optIn.addAll(
            "kotlin.uuid.ExperimentalUuidApi",
            "kotlin.time.ExperimentalTime",
            "kotlinx.coroutines.ExperimentalCoroutinesApi",
        )
    }
}

java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}

dependencies {
    testImplementation(project(":core:testing"))
    testImplementation(project(":ui"))
    testImplementation(kotlin("test"))
    testImplementation(libs.okhttp)
}

val repository = rootProject.layout.projectDirectory.dir("../..")
val isolatedGateway = layout.buildDirectory.file("fixture/isolated-gateway")
val buildIsolatedGateway =
    tasks.register<Exec>("buildIsolatedGateway") {
        description =
            "Builds the fixture gateway (tools/fixtures/gateway) the end-to-end tests launch."
        workingDir = repository.asFile
        val go = providers.gradleProperty("dieter.go").orElse("go").get()
        commandLine(
            go,
            "build",
            "-o",
            isolatedGateway.get().asFile.absolutePath,
            "./tools/fixtures/gateway",
        )
        // Every Go package, embedded file, and module pin the fixture can link.
        inputs
            .files(repository.file("go.mod"), repository.file("go.sum"))
            .withPropertyName("goModule")
        inputs
            .files(
                repository.asFileTree.matching {
                    include("cmd/**", "internal/**", "tools/fixtures/**", "config/**", "api/**")
                    exclude("**/node_modules/**", "**/.npm/**", "**/testdata/**", "**/*_test.go")
                }
            )
            .withPropertyName("goSources")
            .withPathSensitivity(PathSensitivity.RELATIVE)
        inputs.property("go", go)
        outputs.file(isolatedGateway)
    }

tasks.test {
    dependsOn(buildIsolatedGateway)
    inputs
        .file(isolatedGateway)
        .withPropertyName("isolatedGateway")
        .withPathSensitivity(PathSensitivity.NONE)
    val harnessRuntime = repository.dir("internal/harness/runtime")
    inputs
        .files(
            harnessRuntime.asFileTree.matching {
                include("**/*.mjs", "package.json", "package-lock.json")
                exclude("node_modules/**", ".npm/**", "**/*.test.mjs")
            }
        )
        .withPropertyName("mockHarnessRuntime")
        .withPathSensitivity(PathSensitivity.RELATIVE)
    systemProperty("dieter.isolatedGateway", isolatedGateway.get().asFile.absolutePath)
    // The mock harness answering fixture turns runs on the repository's Node runtime.
    environment("DIETER_HARNESS_RUNTIME_DIR", harnessRuntime.asFile.absolutePath)
    maxParallelForks = 1
    testLogging {
        events("passed", "failed", "skipped")
        exceptionFormat = org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL
    }
}
