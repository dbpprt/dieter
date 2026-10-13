package com.getdieter.core.testing

import com.getdieter.core.platform.GrpcTunnelFactory
import com.getdieter.core.platform.OkHttpAuthHttp
import com.getdieter.core.platform.OkHttpRpcTransport
import com.getdieter.core.platform.Platform
import com.getdieter.core.platform.SignatureVerifier
import com.getdieter.core.platform.SoftwareDeviceKeys
import com.getdieter.core.runtime.CoreLogger
import java.nio.file.Files
import kotlin.time.Clock
import okio.FileSystem
import okio.Path
import okio.Path.Companion.toOkioPath

/** Prints core logs with a tag so failing end-to-end runs explain themselves. */
object PrintLogger : CoreLogger {
    override fun debug(tag: String, message: String) = println("D/$tag: $message")

    override fun info(tag: String, message: String) = println("I/$tag: $message")

    override fun warn(tag: String, message: String, error: Throwable?) =
        println("W/$tag: $message ${error ?: ""}")
}

/**
 * A host-JVM platform over real OkHttp and a fresh private state directory. Its device key is a
 * software P-256 key in the state directory, so a runtime restarted on [stateDirectory] keeps its
 * device and pinned roster.
 */
fun jvmTestPlatform(
    stateDirectory: Path = Files.createTempDirectory("dieter-core-state").toOkioPath(),
    secureStore: MemorySecureStore = MemorySecureStore(),
    clock: Clock = Clock.System,
    signatures: SignatureVerifier = JcaSignatureVerifier,
    deviceKeys: SoftwareDeviceKeys =
        SoftwareDeviceKeys(stateDirectory.resolve("device-key").toFile(), deviceName = "JVM test"),
): Platform {
    val transport = OkHttpRpcTransport(deviceKeys)
    return Platform(
        transport = transport,
        tunnels = GrpcTunnelFactory(transport),
        deviceKeys = deviceKeys,
        signatures = signatures,
        secureStore = secureStore,
        settings = MemoryDeviceSettings(),
        http = OkHttpAuthHttp(),
        fileSystem = FileSystem.SYSTEM,
        stateDirectory = stateDirectory,
        logger = PrintLogger,
        clock = clock,
    )
}
