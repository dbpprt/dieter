package com.dbpprt.dieter.core.platform

import com.squareup.wire.GrpcClient
import java.io.ByteArrayInputStream
import java.security.Provider
import java.security.cert.CertPathValidator
import java.security.cert.CertificateException
import java.security.cert.CertificateFactory
import java.security.cert.PKIXParameters
import java.security.cert.TrustAnchor
import java.security.cert.X509Certificate
import java.util.concurrent.TimeUnit
import javax.net.ssl.SSLContext
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
 * Security providers for direct daemon TLS. Desktop JDKs support Ed25519
 * daemon certificates natively; Android passes BouncyCastle's crypto and JSSE
 * providers, without touching the process-wide security registry.
 */
class DirectTlsProviders(val crypto: Provider? = null, val jsse: Provider? = null)

/**
 * OkHttp-backed transport for Android and host JVMs. Every channel shares one
 * connection pool.
 */
class OkHttpRpcTransport(
    base: OkHttpClient = OkHttpClient(),
    private val providers: DirectTlsProviders = DirectTlsProviders(),
) : RpcTransport {
    // Wire runs every call, including long-lived streams, on OkHttp's async
    // dispatcher. Its default of 5 calls per host would queue a unary call
    // behind the feed, navigation, presence, quota, and feature streams that
    // all share the gateway host. HTTP/2 multiplexes them on one connection.
    private val base = base.newBuilder()
        .dispatcher(Dispatcher().apply { maxRequests = MAX_CALLS; maxRequestsPerHost = MAX_CALLS_PER_HOST })
        .build()

    override fun gateway(access: GatewayAccess): RpcChannel = channel(access.url) {
        mapOf("authorization" to "Bearer ${access.sessionToken}", "x-dieter-client-version" to access.clientVersion)
    }

    override fun relay(access: GatewayAccess, daemonId: String): RpcChannel = channel(access.url) {
        mapOf(
            "authorization" to "Bearer ${access.sessionToken}",
            "x-dieter-client-version" to access.clientVersion,
            "x-dieter-daemon-id" to daemonId,
        )
    }

    override fun direct(target: DirectTarget, tokens: DaemonTokenSource): RpcChannel {
        val trust = DaemonTrustManager(target.daemonCaPem, target.spiffeIdentity, providers.crypto)
        val context = providers.jsse?.let { SSLContext.getInstance("TLSv1.3", it) } ?: SSLContext.getInstance("TLSv1.3")
        val tls = context.apply { init(null, arrayOf(trust), null) }
        val host = if (':' in target.host) "[${target.host}]" else target.host
        return channel("https://$host:${target.port}", configure = {
            // Identity is the SPIFFE URI checked by the trust manager, not the host name.
            sslSocketFactory(tls.socketFactory, trust).hostnameVerifier { _, _ -> true }
        }) {
            // OkHttp interceptors run on its own threads, so blocking here is safe.
            mapOf("authorization" to "Bearer ${runBlocking { tokens.token() }}", "x-dieter-client-version" to target.clientVersion)
        }
    }

    private companion object {
        const val MAX_CALLS = 256
        const val MAX_CALLS_PER_HOST = 128
    }

    private fun channel(url: String, configure: OkHttpClient.Builder.() -> Unit = {}, headers: () -> Map<String, String>): RpcChannel {
        val http = base.newBuilder()
            // Plaintext is only for loopback development gateways.
            .protocols(if (url.startsWith("https://")) listOf(Protocol.HTTP_2, Protocol.HTTP_1_1) else listOf(Protocol.H2_PRIOR_KNOWLEDGE))
            .readTimeout(0, TimeUnit.MILLISECONDS) // Streams are bounded by the core's liveness deadlines.
            .addInterceptor { chain ->
                val request = chain.request().newBuilder()
                headers().forEach { (name, value) -> request.header(name, value) }
                chain.proceed(request.build())
            }
            .apply(configure)
            .build()
        // Wire gzips requests by default; the Go gateway and daemon register no decompressor.
        val client: GrpcClient = GrpcClient.Builder().client(http).baseUrl(url).minMessageToCompress(Long.MAX_VALUE).build()
        return RpcChannel(client)
    }
}

/** Trusts exactly one enrolled daemon: its CA chain plus its SPIFFE identity. */
internal class DaemonTrustManager(caPem: String, private val identity: String, private val crypto: Provider? = null) : X509TrustManager {
    private val factory = crypto?.let { CertificateFactory.getInstance("X.509", it) } ?: CertificateFactory.getInstance("X.509")
    private val authority = factory.generateCertificates(ByteArrayInputStream(caPem.toByteArray()))
        .filterIsInstance<X509Certificate>()
        .ifEmpty { throw IllegalArgumentException("daemon CA is invalid") }

    override fun checkServerTrusted(chain: Array<out X509Certificate>, authType: String) {
        val leaf = chain.firstOrNull() ?: throw CertificateException("daemon certificate is missing")
        val parameters = PKIXParameters(authority.map { TrustAnchor(it, null) }.toSet()).apply { isRevocationEnabled = false }
        try {
            val validator = crypto?.let { CertPathValidator.getInstance("PKIX", it) } ?: CertPathValidator.getInstance("PKIX")
            validator.validate(factory.generateCertPath(chain.toList()), parameters)
        } catch (error: Exception) {
            throw CertificateException("daemon certificate is not trusted", error)
        }
        val uris = leaf.subjectAlternativeNames.orEmpty().filter { it[0] == 6 }.map { it[1] as String }
        if (identity !in uris) throw CertificateException("daemon certificate identity does not match the route")
    }

    override fun checkClientTrusted(chain: Array<out X509Certificate>, authType: String) =
        throw CertificateException("client certificates are not accepted")

    override fun getAcceptedIssuers(): Array<X509Certificate> = authority.toTypedArray()
}

/** The OAuth code exchange over OkHttp. */
class OkHttpAuthHttp(private val client: OkHttpClient = OkHttpClient.Builder().callTimeout(30, TimeUnit.SECONDS).build()) : AuthHttp {
    override suspend fun postJson(url: String, body: String): HttpResponse = suspendCancellableCoroutine { continuation ->
        val call = client.newCall(Request.Builder().url(url).post(body.toRequestBody("application/json".toMediaType())).build())
        continuation.invokeOnCancellation { call.cancel() }
        call.enqueue(object : Callback {
            override fun onFailure(call: Call, e: java.io.IOException) = continuation.resumeWithException(e)
            override fun onResponse(call: Call, response: Response) {
                response.use { continuation.resume(HttpResponse(it.code, it.body.string())) }
            }
        })
    }
}
