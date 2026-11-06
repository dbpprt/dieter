package com.getdieter.core.platform

import com.getdieter.api.gateway.v1.DaemonAccessToken
import com.getdieter.api.gateway.v1.RelayLane
import com.getdieter.core.notifications.NotificationSink
import com.getdieter.core.runtime.CoreLogger
import com.getdieter.core.runtime.SilentLogger
import com.squareup.wire.GrpcClient
import kotlin.time.Clock
import okio.ByteString
import okio.FileSystem
import okio.Path

/**
 * Everything the shared core needs from its host app. Each member is a "native extension": platform
 * code the core drives but never reimplements.
 */
class Platform(
    val transport: RpcTransport,
    /** The gateway relay's opaque byte tunnels to daemons. */
    val tunnels: TunnelFactory,
    /** This install's device key, which the account's device roster trusts once paired. */
    val deviceKeys: DeviceKeys,
    /** Verifies roster entries and screen-session bindings. */
    val signatures: SignatureVerifier,
    val secureStore: SecureStore,
    val settings: DeviceSettings,
    val http: AuthHttp,
    val fileSystem: FileSystem,
    /** Private, per-install directory: Application Support or noBackupFilesDir. */
    val stateDirectory: Path,
    val controlChannels: ControlChannelFactory? = null,
    /** Posts local notifications; absent on platforms without them. */
    val notifications: NotificationSink? = null,
    val logger: CoreLogger = SilentLogger,
    val clock: Clock = Clock.System,
)

/**
 * HTTP/2 gRPC with trailers and TLS: OkHttp on Android and the JVM, grpc-swift on Apple. The core
 * chooses which channel to use.
 */
interface RpcTransport {
    /** Gateway RPCs, authenticated with the user session. */
    fun gateway(access: GatewayAccess): RpcChannel

    /**
     * Daemon API (dieter.v1) RPCs over mutually authenticated TLS 1.3 to [target], whatever the
     * carrier (a direct candidate, a WebRTC bridge or a relay tunnel on loopback). Implementations
     * accept the handshake only if the server's leaf certificate's DER SubjectPublicKeyInfo equals
     * [DirectTarget.daemonPublicKey], ignoring issuers, validity and host names, and present
     * [DirectTarget.clientCertificate] with this install's device key ([DeviceKeys]) as the TLS
     * client certificate.
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

/**
 * One daemon endpoint. [daemonPublicKey] is the daemon's DER SubjectPublicKeyInfo from the pinned
 * device roster; [clientCertificate] is this device's self-signed DER certificate
 * ([com.getdieter.core.trust.DeviceCertificate]).
 */
data class DirectTarget(
    val daemonId: String,
    val host: String,
    val port: Int,
    val daemonPublicKey: ByteString,
    val clientCertificate: ByteString,
    val clientVersion: String,
)

/** Supplies a current daemon bearer token before each direct RPC. */
fun interface DaemonTokenSource {
    suspend fun token(): String
}

/** Exchanges a daemon token through the gateway. */
fun interface DaemonTokenExchange {
    suspend fun exchange(): DaemonAccessToken
}

/**
 * A WebRTC data channel to one daemon, exposed as a loopback TCP port that carries TLS:
 * `ControlRTCBridge` on Android and Apple.
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

/** Signature verification for roster entries and screen bindings (CryptoKit, JCA/BouncyCastle). */
interface SignatureVerifier {
    /** [publicKey] is the raw 32-byte Ed25519 key. */
    fun verifyEd25519(publicKey: ByteArray, message: ByteArray, signature: ByteArray): Boolean

    /**
     * [publicKey] is the DER SubjectPublicKeyInfo of an uncompressed ECDSA P-256 key; [signature]
     * is a DER ECDSA signature over SHA-256([message]) (JCA `SHA256withECDSA`, CryptoKit
     * `P256.Signing.ECDSASignature(derRepresentation:)`). False for any malformed input.
     */
    fun verifyEcdsaP256(publicKey: ByteArray, message: ByteArray, signature: ByteArray): Boolean
}

/**
 * This install's device key: an ECDSA P-256 key whose private half never leaves the device
 * (AndroidKeyStore, Secure Enclave, or a software key where neither is usable). The roster lists
 * its public half; TLS client authentication and roster entries this device signs use it. Calls may
 * block briefly and come from any thread.
 */
interface DeviceKeys {
    /** "android", "ios", "macos", or "jvm": 1..16 characters of [a-z0-9]. */
    val platform: String

    /** The name other devices show, e.g. "Pixel 9"; the core uses at most 64 bytes of it. */
    val deviceName: String

    /**
     * The key's DER SubjectPublicKeyInfo (uncompressed point). Creates and persists the key on
     * first use, so it survives restarts and sign-out.
     */
    fun publicKey(): ByteArray

    /** A DER ECDSA signature over SHA-256([message]). */
    fun sign(message: ByteArray): ByteArray

    /** Deletes the key; the next [publicKey] creates a new one. */
    fun reset()
}

/**
 * Opens relay tunnels: `RelayService.OpenTunnel` to the gateway with the user session, bridged to a
 * loopback TCP port. Protocol: send OPEN{daemon_id, lane}; wait for OPENED (CLOSE fails the open
 * with its status); then DATA frames of at most 64 KiB both ways, at most 8 DATA frames in flight
 * per direction, each side crediting with WINDOW{credit} after writing DATA to its socket; CLOSE or
 * the end of the stream ends the tunnel. The core runs the same TLS as [RpcTransport.direct] over
 * the port, so the gateway relays ciphertext only.
 */
interface TunnelFactory {
    /**
     * Opens a tunnel to [daemonId] on [lane] and returns once the gateway answered OPENED. The
     * returned port accepts exactly one loopback connection.
     */
    suspend fun open(access: GatewayAccess, daemonId: String, lane: RelayLane): Tunnel
}

/** One open relay tunnel bridged to a loopback port. */
interface Tunnel {
    /** The loopback port (127.0.0.1) that carries the tunnel. */
    val port: Int

    /** Ends the tunnel in both directions; safe to call more than once. */
    fun close()
}
