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

// Wire generates every Dieter schema straight from the repository's api/proto:
// the network API (dieter.v1, dieter.gateway.v1), the clients' UI contract
// (dieter.client.v1) and the core's on-device records (dieter.core.v1). Each
// schema's java_package sets its Kotlin package (com.getdieter.*).
wire {
    sourcePath { srcDir(rootProject.file("../../api/proto")) }
    kotlin {
        rpcRole = "client"
        rpcCallStyle = "suspending"
        // Server streams get GrpcServerStreamingCall, which native transports implement.
        explicitStreamingCalls = true
    }
}
