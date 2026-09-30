plugins {
    id("dieter.kmp")
    alias(libs.plugins.wire)
}

kotlin {
    sourceSets {
        commonMain.dependencies {
            api(libs.wire.runtime)
            api(libs.wire.grpc.client)
        }
    }
}

// Wire derives the Kotlin package from java_package. Every client imports the
// API models as com.dbpprt.dieter.api.*, so relocate them on copy.
val relocatedProto = layout.buildDirectory.dir("relocated-proto")
val relocateProto by tasks.registering(Sync::class) {
    from(rootProject.file("../../api/proto")) { include("dieter/**/*.proto") }
    into(relocatedProto)
    filter { line ->
        line.replace("\"com.dbpprt.dieter.v1\"", "\"com.dbpprt.dieter.api.v1\"")
            .replace("\"com.dbpprt.dieter.gateway.v1\"", "\"com.dbpprt.dieter.api.gateway.v1\"")
    }
}

wire {
    sourcePath { srcDir(relocatedProto) }
    sourcePath { srcDir("src/commonMain/proto") }
    kotlin {
        rpcRole = "client"
        rpcCallStyle = "suspending"
        // Server streams get GrpcServerStreamingCall, which native transports implement.
        explicitStreamingCalls = true
    }
}

tasks.matching { it.name.startsWith("generate") && it.name.endsWith("Protos") }.configureEach {
    dependsOn(relocateProto)
}
