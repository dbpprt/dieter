package com.dbpprt.dieter.core.platform

import com.dbpprt.dieter.api.gateway.v1.DaemonAccessToken
import com.dbpprt.dieter.core.notifications.NotificationSink
import com.dbpprt.dieter.core.runtime.CoreLogger
import com.dbpprt.dieter.core.runtime.SilentLogger
import com.squareup.wire.GrpcClient
import kotlin.time.Clock
import okio.FileSystem
import okio.Path

/**
 * Everything the shared core needs from its host app. Each member is a
 * "native extension": platform code the core drives but never reimplements.
 */
class Platform(
    val transport: RpcTransport,
    val secureStore: SecureStore,
    val settings: DeviceSettings,
    val http: AuthHttp,
    val fileSystem: FileSystem,
    /** Private, per-install directory: Application Support or noBackupFilesDir. */
    val stateDirectory: Path,
    val controlChannels: ControlChannelFactory? = null,
    val signatures: SignatureVerifier? = null,
    /** Posts local notifications; absent on platforms without them. */
    val notifications: NotificationSink? = null,
    val logger: CoreLogger = SilentLogger,
    val clock: Clock = Clock.System,
)

/**
 * HTTP/2 gRPC with trailers, TLS, and certificate pinning: OkHttp on Android
 * and the JVM, grpc-swift on Apple. The core chooses which channel to use.
 */
interface RpcTransport {
    /** Gateway RPCs, authenticated with the user session. */
    fun gateway(access: GatewayAccess): RpcChannel

    /** DieterService RPCs relayed to one daemon through the gateway. */
    fun relay(access: GatewayAccess, daemonId: String): RpcChannel

    /**
     * DieterService RPCs over TLS 1.3 to [target]. Implementations verify the
     * chain against [DirectTarget.daemonCaPem] and require the leaf URI SAN
     * `spiffe://board/daemon/<daemonId>`; host names are not trusted.
     */
    fun direct(target: DirectTarget, tokens: DaemonTokenSource): RpcChannel
}

/** One logical channel. [close] releases its underlying connection. */
class RpcChannel(val client: GrpcClient, private val onClose: () -> Unit = {}) {
    private var closed = false

    fun close() {
        if (closed) return
        closed = true
        onClose()
    }
}

data class GatewayAccess(val url: String, val sessionToken: String, val clientVersion: String)

data class DirectTarget(
    val daemonId: String,
    val host: String,
    val port: Int,
    val daemonCaPem: String,
    val clientVersion: String,
) {
    val spiffeIdentity get() = "spiffe://board/daemon/$daemonId"
}

/** Supplies a current daemon bearer token before each direct RPC. */
fun interface DaemonTokenSource {
    suspend fun token(): String
}

/** Exchanges a daemon token through the gateway. */
fun interface DaemonTokenExchange {
    suspend fun exchange(): DaemonAccessToken
}

/**
 * A WebRTC data channel to one daemon, exposed as a loopback TCP port that
 * carries TLS: `ControlRTCBridge` on Android and Apple.
 */
interface ControlChannelFactory {
    /** [configuration] is an encoded `dieter.gateway.v1.RTCConfiguration`. */
    suspend fun create(configuration: ByteArray): ControlChannel
}

interface ControlChannel {
    /** Gathers ICE and returns the local SDP offer. */
    suspend fun offer(): String

    /** Applies the daemon's answer; returns the loopback port bridged to the channel. */
    suspend fun connect(answerSdp: String): Int

    fun close()
}

/** Gateway session tokens: AndroidKeyStore, Keychain, or a 0600 file on macOS. */
interface SecureStore {
    fun read(key: String): String?
    fun write(key: String, value: String)
    fun delete(key: String)
}

/** Device-local preferences that never leave the device. */
interface DeviceSettings {
    fun string(key: String): String?
    fun putString(key: String, value: String?)
}

/** The one plain-HTTP call the core makes: the native OAuth code exchange. */
interface AuthHttp {
    suspend fun postJson(url: String, body: String): HttpResponse
}

class HttpResponse(val status: Int, val body: String)

/** Ed25519 verification for screen-session bindings (CryptoKit, JCA/BouncyCastle). */
interface SignatureVerifier {
    /** [publicKey] is the raw 32-byte Ed25519 key. */
    fun verifyEd25519(publicKey: ByteArray, message: ByteArray, signature: ByteArray): Boolean
}
