package com.dbpprt.dieter.core.testing

import com.dbpprt.dieter.core.platform.OkHttpAuthHttp
import com.dbpprt.dieter.core.platform.OkHttpRpcTransport
import com.dbpprt.dieter.core.platform.Platform
import com.dbpprt.dieter.core.platform.SignatureVerifier
import com.dbpprt.dieter.core.runtime.CoreLogger
import java.nio.file.Files
import kotlin.time.Clock
import okio.FileSystem
import okio.Path
import okio.Path.Companion.toOkioPath

/** Prints core logs with a tag so failing end-to-end runs explain themselves. */
object PrintLogger : CoreLogger {
    override fun debug(tag: String, message: String) = println("D/$tag: $message")
    override fun info(tag: String, message: String) = println("I/$tag: $message")
    override fun warn(tag: String, message: String, error: Throwable?) = println("W/$tag: $message ${error ?: ""}")
}

/** A host-JVM platform over real OkHttp and a fresh private state directory. */
fun jvmTestPlatform(
    stateDirectory: Path = Files.createTempDirectory("dieter-core-state").toOkioPath(),
    secureStore: MemorySecureStore = MemorySecureStore(),
    clock: Clock = Clock.System,
    signatures: SignatureVerifier? = JcaSignatureVerifier,
): Platform = Platform(
    transport = OkHttpRpcTransport(), secureStore = secureStore, settings = MemoryDeviceSettings(), http = OkHttpAuthHttp(),
    fileSystem = FileSystem.SYSTEM, stateDirectory = stateDirectory, signatures = signatures, logger = PrintLogger, clock = clock,
)
