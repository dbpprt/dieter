package com.getdieter.core.platform

import com.squareup.wire.GrpcClient
import java.io.ByteArrayInputStream
import java.net.Socket
import java.security.MessageDigest
import java.security.Principal
import java.security.PrivateKey
import java.security.Provider
import java.security.cert.CertificateException
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import java.util.concurrent.TimeUnit
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLEngine
import javax.net.ssl.X509ExtendedKeyManager
import javax.net.ssl.X509TrustManager
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.suspendCancellableCoroutine
import okhttp3.Call
import okhttp3.Callback
import okhttp3.Dispatcher
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response

/**
 * Security providers for daemon TLS. Desktop JDKs support Ed25519 daemon certificates natively;
 * Android passes BouncyCastle's crypto and JSSE providers, without touching the process-wide
 * security registry.
 */
class DirectTlsProviders(val crypto: Provider? = null, val jsse: Provider? = null)

/**
 * The private half of this install's device key, which TLS client authentication signs with: a
 * software key ([SoftwareDeviceKeys]) or a key-store handle the JSSE provider can use. The
 * certificate presenting it comes from the core ([DirectTarget.clientCertificate]).
 */
fun interface DeviceTlsIdentity {
    fun privateKey(): PrivateKey
}

/** OkHttp-backed transport for Android and host JVMs. Every channel shares one connection pool. */
class OkHttpRpcTransport(
    private val identity: DeviceTlsIdentity,
    base: OkHttpClient = OkHttpClient(),
    private val providers: DirectTlsProviders = DirectTlsProviders(),
) : RpcTransport {
    // Wire runs every call, including long-lived streams, on OkHttp's async
    // dispatcher. Its default of 5 calls per host would queue a unary call
    // behind every machine's change stream and the presence, quota, and
    // feature streams that all share the gateway host. HTTP/2 multiplexes
    // them on one connection.
    private val base =
        base
            .newBuilder()
            .dispatcher(
                Dispatcher().apply {
                    maxRequests = MAX_CALLS
                    maxRequestsPerHost = MAX_CALLS_PER_HOST
                }
            )
            .build()

    override fun gateway(access: GatewayAccess): RpcChannel =
        channel(access.url) {
            mapOf(
                "authorization" to "Bearer ${access.sessionToken}",
                "x-dieter-client-version" to access.clientVersion,
            )
        }

    override fun direct(target: DirectTarget, tokens: DaemonTokenSource): RpcChannel {
        val trust = PinnedDaemonTrustManager(target.daemonPublicKey.toByteArray())
        val tls = DirectTls.context(target, identity, trust, providers)
        val host = if (':' in target.host) "[${target.host}]" else target.host
        return channel(
            "https://$host:${target.port}",
            configure = {
                // Identity is the pinned roster key checked by the trust manager, not the host
                // name.
                sslSocketFactory(tls.socketFactory, trust).hostnameVerifier { _, _ -> true }
            },
        ) {
            // OkHttp interceptors run on its own threads, so blocking here is safe.
            mapOf(
                "authorization" to "Bearer ${runBlocking { tokens.token() }}",
                "x-dieter-client-version" to target.clientVersion,
            )
        }
    }

    private companion object {
        const val MAX_CALLS = 256
        const val MAX_CALLS_PER_HOST = 128
    }

    private fun channel(
        url: String,
        configure: OkHttpClient.Builder.() -> Unit = {},
        headers: () -> Map<String, String>,
    ): RpcChannel {
        val http =
            base
                .newBuilder()
                // Plaintext is only for loopback development gateways.
                .protocols(
                    if (url.startsWith("https://")) listOf(Protocol.HTTP_2, Protocol.HTTP_1_1)
                    else listOf(Protocol.H2_PRIOR_KNOWLEDGE)
                )
                .readTimeout(
                    0,
                    TimeUnit.MILLISECONDS,
                ) // Streams are bounded by the core's liveness deadlines.
                .addInterceptor { chain ->
                    val request = chain.request().newBuilder()
                    headers().forEach { (name, value) -> request.header(name, value) }
                    chain.proceed(request.build())
                }
                .apply(configure)
                .build()
        // Wire gzips requests by default; the Go gateway and daemon register no decompressor.
        val client: GrpcClient =
            GrpcClient.Builder()
                .client(http)
                .baseUrl(url)
                .minMessageToCompress(Long.MAX_VALUE)
                .build()
        return RpcChannel(client)
    }
}

/** Mutually authenticated TLS 1.3 to one daemon, pinned to its roster key. */
object DirectTls {
    /**
     * A TLS context that presents [target]'s client certificate with [identity]'s key and trusts
     * exactly [trust]'s pinned server key.
     */
    fun context(
        target: DirectTarget,
        identity: DeviceTlsIdentity,
        trust: X509TrustManager,
        providers: DirectTlsProviders = DirectTlsProviders(),
    ): SSLContext {
        val factory =
            providers.crypto?.let { CertificateFactory.getInstance("X.509", it) }
                ?: CertificateFactory.getInstance("X.509")
        val certificate =
            factory.generateCertificate(
                ByteArrayInputStream(target.clientCertificate.toByteArray())
            ) as X509Certificate
        val context =
            providers.jsse?.let { SSLContext.getInstance("TLSv1.3", it) }
                ?: SSLContext.getInstance("TLSv1.3")
        return context.apply {
            init(arrayOf(DeviceKeyManager(identity, arrayOf(certificate))), arrayOf(trust), null)
        }
    }
}

/**
 * Trusts exactly one daemon key: the leaf certificate's DER SubjectPublicKeyInfo must equal the
 * machine's key in the pinned device roster. Issuers, validity and names carry no trust.
 */
class PinnedDaemonTrustManager(private val expected: ByteArray) : X509TrustManager {
    override fun checkServerTrusted(chain: Array<out X509Certificate>, authType: String) {
        val leaf =
            chain.firstOrNull() ?: throw CertificateException("The machine presented no key.")
        val presented =
            leaf.publicKey?.encoded
                ?: throw CertificateException("The machine's key is unreadable.")
        if (!MessageDigest.isEqual(presented, expected))
            throw CertificateException("The machine's key does not match your trusted devices.")
    }

    override fun checkClientTrusted(chain: Array<out X509Certificate>, authType: String) =
        throw CertificateException("client certificates are not accepted")

    override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
}

/** Presents this device's certificate for every client-authentication request. */
internal class DeviceKeyManager(
    private val identity: DeviceTlsIdentity,
    private val chain: Array<X509Certificate>,
) : X509ExtendedKeyManager() {
    private fun alias(keyTypes: Array<out String>?): String? = ALIAS.takeIf {
        keyTypes == null || keyTypes.any { it.uppercase().startsWith("EC") }
    }

    override fun chooseClientAlias(
        keyType: Array<out String>?,
        issuers: Array<out Principal>?,
        socket: Socket?,
    ): String? = alias(keyType)

    override fun chooseEngineClientAlias(
        keyType: Array<out String>?,
        issuers: Array<out Principal>?,
        engine: SSLEngine?,
    ): String? = alias(keyType)

    override fun getClientAliases(keyType: String?, issuers: Array<out Principal>?): Array<String> =
        arrayOf(ALIAS)

    override fun getCertificateChain(alias: String?): Array<X509Certificate>? = chain.takeIf {
        alias == ALIAS
    }

    override fun getPrivateKey(alias: String?): PrivateKey? =
        if (alias == ALIAS) identity.privateKey() else null

    override fun chooseServerAlias(
        keyType: String?,
        issuers: Array<out Principal>?,
        socket: Socket?,
    ): String? = null

    override fun getServerAliases(
        keyType: String?,
        issuers: Array<out Principal>?,
    ): Array<String>? = null

    private companion object {
        const val ALIAS = "dieter-device"
    }
}

/** The OAuth code exchange over OkHttp. */
class OkHttpAuthHttp(
    private val client: OkHttpClient =
        OkHttpClient.Builder().callTimeout(30, TimeUnit.SECONDS).build()
) : AuthHttp {
    override suspend fun postJson(url: String, body: String): HttpResponse =
        suspendCancellableCoroutine { continuation ->
            val call =
                client.newCall(
                    Request.Builder()
                        .url(url)
                        .post(body.toRequestBody("application/json".toMediaType()))
                        .build()
                )
            continuation.invokeOnCancellation { call.cancel() }
            call.enqueue(
                object : Callback {
                    override fun onFailure(call: Call, e: java.io.IOException) =
                        continuation.resumeWithException(e)

                    override fun onResponse(call: Call, response: Response) {
                        response.use {
                            continuation.resume(HttpResponse(it.code, it.body.string()))
                        }
                    }
                }
            )
        }
}
