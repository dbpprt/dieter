package com.dbpprt.dieter.screens

import android.content.Context
import androidx.test.platform.app.InstrumentationRegistry
import com.dbpprt.dieter.api.gateway.v1.RTCConfiguration
import com.dbpprt.dieter.api.v1.DieterServiceClient
import com.dbpprt.dieter.core.screens.ScreenRoute
import com.dbpprt.dieter.e2e.TestCore
import com.squareup.wire.GrpcClient
import com.squareup.wire.GrpcException
import com.squareup.wire.GrpcStatus
import java.util.Base64
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import okhttp3.Headers.Companion.headersOf
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import okhttp3.TrailersSource
import org.json.JSONObject

/**
 * The disposable native screen service `just e2e run --suite screens` starts
 * on the host and reverses to the device's loopback. Routes to it are plain
 * HTTP/2 with the fixture's token, counted, and optionally made to fail.
 */
internal class ScreenFixture(private val json: JSONObject) {
    val port: Int = json.getInt("port")
    val token: String = json.getString("token")
    val real: Boolean get() = json.optBoolean("real")
    val multi: Boolean get() = json.optBoolean("multi")
    fun double(name: String): Double = json.getDouble(name)

    private val certificatePem = String(Base64.getDecoder().decode(json.getString("certificate")))
    private val rtc = RTCConfiguration.ADAPTER.decode(Base64.getDecoder().decode(json.getString("rtc")))

    /** Routes opened so far; recovery must open a fresh one. */
    val routesOpened = AtomicInteger()

    /** UpdateRemoteDesktopSession calls; local canvas gestures must not configure the stream. */
    val configurations = AtomicInteger()

    /** The next configuration call fails with this status instead of reaching the fixture. */
    val nextConfigurationFailure = AtomicReference<GrpcStatus?>()

    /** Route openings that fail as if the host's network slept. */
    val unavailableRoutes = AtomicInteger()

    private val cores = mutableListOf<TestCore>()

    private fun http(): OkHttpClient = OkHttpClient.Builder()
        .protocols(listOf(Protocol.H2_PRIOR_KNOWLEDGE))
        .readTimeout(0, TimeUnit.MILLISECONDS)
        .addInterceptor { chain ->
            val request = chain.request().newBuilder().header("authorization", "Bearer $token").build()
            if (!request.url.encodedPath.endsWith("/UpdateRemoteDesktopSession")) return@addInterceptor chain.proceed(request)
            configurations.incrementAndGet()
            val failure = nextConfigurationFailure.getAndSet(null) ?: return@addInterceptor chain.proceed(request)
            // A trailers-only gRPC response, as a daemon rejecting the call would send.
            val status = headersOf("grpc-status", failure.code.toString(), "grpc-message", "Injected ${failure.name}")
            Response.Builder().request(request).protocol(Protocol.HTTP_2).code(200).message("OK")
                .headers(status.newBuilder().add("content-type", "application/grpc").build())
                .body(ByteArray(0).toResponseBody("application/grpc".toMediaType()))
                .trailers(object : TrailersSource {
                    override fun get() = status
                })
                .build()
        }
        .build()

    /** A direct client to the fixture, for the host-side assertions the app never makes. */
    fun client(): Pair<DieterServiceClient, OkHttpClient> {
        val http = http()
        val grpc = GrpcClient.Builder().client(http).baseUrl("http://127.0.0.1:$port").minMessageToCompress(Long.MAX_VALUE).build()
        return grpc.create(DieterServiceClient::class) to http
    }

    suspend fun route(): ScreenRoute {
        if (unavailableRoutes.getAndUpdate { maxOf(0, it - 1) } > 0) throw GrpcException(GrpcStatus.UNAVAILABLE, "Injected sleeping laptop network")
        routesOpened.incrementAndGet()
        val (client, http) = client()
        return ScreenRoute(client, certificatePem, rtc, "Isolated native fixture") { http.connectionPool.evictAll() }
    }

    /** A screen host over an isolated, never-connected core whose routes lead to this fixture. */
    fun host(context: Context, configure: AndroidScreenMedia.() -> Unit = {}): ScreenHost {
        val core = TestCore(context).also { cores += it }
        val media = AndroidScreenMedia(context).apply(configure)
        return ScreenHost(context, core.core, media) { { route() } }
    }

    /** POSTs a fixture control endpoint such as `expire-screen` or `stop-capture`. */
    fun control(path: String): Int {
        val connection = java.net.URL("http://127.0.0.1:$port/test/$path").openConnection() as java.net.HttpURLConnection
        try {
            connection.requestMethod = "POST"
            connection.connectTimeout = 5_000
            connection.readTimeout = 5_000
            connection.setRequestProperty("Authorization", "Bearer $token")
            return connection.responseCode
        } finally {
            connection.disconnect()
        }
    }

    fun close() = cores.forEach { it.close(); it.delete() }

    companion object {
        /** The fixture passed by the e2e runner, or null outside `--suite screens`. */
        fun fromArguments(): ScreenFixture? =
            InstrumentationRegistry.getArguments().getString("screenFixture")?.let { ScreenFixture(JSONObject(String(Base64.getDecoder().decode(it)))) }
    }
}
