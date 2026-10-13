package com.getdieter.core.testing

import com.getdieter.core.platform.DaemonTokenSource
import com.getdieter.core.platform.DirectTarget
import com.getdieter.core.platform.GatewayAccess
import com.getdieter.core.platform.OkHttpAuthHttp
import com.getdieter.core.platform.OkHttpRpcTransport
import com.getdieter.core.platform.Platform
import com.getdieter.core.platform.RpcChannel
import com.getdieter.core.platform.RpcTransport
import com.getdieter.core.platform.SignatureVerifier
import com.getdieter.core.runtime.CoreLogger
import java.nio.file.Files
import kotlin.time.Clock
import okhttp3.OkHttpClient
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

/** A host-JVM platform over real OkHttp and a fresh private state directory. */
fun jvmTestPlatform(
    stateDirectory: Path = Files.createTempDirectory("dieter-core-state").toOkioPath(),
    secureStore: MemorySecureStore = MemorySecureStore(),
    clock: Clock = Clock.System,
    signatures: SignatureVerifier? = JcaSignatureVerifier,
    transport: RpcTransport = OkHttpRpcTransport(),
): Platform =
    Platform(
        transport = transport,
        secureStore = secureStore,
        settings = MemoryDeviceSettings(),
        http = OkHttpAuthHttp(),
        fileSystem = FileSystem.SYSTEM,
        stateDirectory = stateDirectory,
        signatures = signatures,
        logger = PrintLogger,
        clock = clock,
    )

/**
 * OkHttp with one connection per core channel, closed when the core retires the channel, as the
 * Apple bridge does. [OkHttpRpcTransport] shares one pool, so it would reuse a silent connection.
 */
class ConnectionPerChannelTransport : RpcTransport {
    private fun isolated(open: (OkHttpRpcTransport) -> RpcChannel): RpcChannel {
        val http = OkHttpClient()
        val channel = open(OkHttpRpcTransport(http))
        return RpcChannel(channel.client) {
            channel.close()
            http.connectionPool.evictAll()
        }
    }

    override fun gateway(access: GatewayAccess) = isolated { it.gateway(access) }

    override fun relay(access: GatewayAccess, daemonId: String) = isolated {
        it.relay(access, daemonId)
    }

    override fun direct(target: DirectTarget, tokens: DaemonTokenSource) = isolated {
        it.direct(target, tokens)
    }
}
