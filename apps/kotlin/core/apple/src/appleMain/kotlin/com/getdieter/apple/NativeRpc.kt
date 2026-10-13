package com.getdieter.apple

import com.getdieter.core.platform.DaemonTokenSource
import com.getdieter.core.platform.DirectTarget
import com.getdieter.core.platform.GatewayAccess
import com.getdieter.core.platform.RpcChannel
import com.getdieter.core.platform.RpcTransport
import com.squareup.wire.GrpcCall
import com.squareup.wire.GrpcClient
import com.squareup.wire.GrpcClientStreamingCall
import com.squareup.wire.GrpcException
import com.squareup.wire.GrpcMethod
import com.squareup.wire.GrpcServerStreamingCall
import com.squareup.wire.GrpcStatus
import com.squareup.wire.GrpcStreamingCall
import com.squareup.wire.MessageSource
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.ReceiveChannel
import kotlinx.coroutines.suspendCancellableCoroutine
import okio.IOException
import okio.Timeout
import platform.Foundation.NSData

/**
 * Implemented in Swift with grpc-swift, which owns HTTP/2, gRPC trailers, and roster-pinned mutual
 * TLS. Callbacks may arrive on any thread, at most once per completion. The core chooses routes;
 * the bridge only moves bytes.
 */
interface NativeRpcBridge {
    fun unary(
        target: NativeRpcTarget,
        path: String,
        request: NSData,
        completion: NativeUnaryCompletion,
    ): NativeRpcCancellable

    fun serverStreaming(
        target: NativeRpcTarget,
        path: String,
        request: NSData,
        observer: NativeStreamObserver,
    ): NativeRpcCancellable

    /** Releases connections held for [channelId] once the core retires that channel. */
    fun release(channelId: String)
}

interface NativeUnaryCompletion {
    fun succeeded(response: NSData)

    fun failed(status: Int, message: String)
}

interface NativeStreamObserver {
    fun message(payload: NSData)

    /** [status] 0 is a normal end of stream. */
    fun closed(status: Int, message: String)
}

interface NativeRpcCancellable {
    fun cancel()
}

/**
 * Where one RPC goes. [channelId] groups the calls of one logical channel onto one HTTP/2
 * connection. Gateway targets use the system trust store. Direct targets (direct candidates, WebRTC
 * bridges and relay tunnels, all on [host]:[port]) run TLS 1.3 that accepts the server only if its
 * leaf certificate's DER SubjectPublicKeyInfo equals [daemonPublicKey] (no CA, host name or expiry
 * checks), and present [clientCertificate] (DER) signed with this device's key ([NativeDeviceKeys])
 * as the client certificate. Both are empty for gateway targets.
 */
class NativeRpcTarget(
    val kind: String,
    val channelId: String,
    val url: String,
    val authorization: String,
    val clientVersion: String,
    val daemonId: String,
    val host: String,
    val port: Int,
    val daemonPublicKey: NSData,
    val clientCertificate: NSData,
) {
    companion object {
        const val GATEWAY = "gateway"
        const val DIRECT = "direct"
    }
}

internal class NativeRpcTransport(private val bridge: NativeRpcBridge) : RpcTransport {
    private var channels = 0L

    private fun channel(target: suspend (String) -> NativeRpcTarget): RpcChannel {
        val id = "c${++channels}"
        return RpcChannel(BridgeGrpcClient(bridge) { target(id) }) { bridge.release(id) }
    }

    override fun gateway(access: GatewayAccess): RpcChannel = channel { id ->
        NativeRpcTarget(
            NativeRpcTarget.GATEWAY,
            id,
            access.url,
            "Bearer ${access.sessionToken}",
            access.clientVersion,
            "",
            "",
            0,
            NSData(),
            NSData(),
        )
    }

    override fun direct(target: DirectTarget, tokens: DaemonTokenSource): RpcChannel =
        channel { id ->
            NativeRpcTarget(
                NativeRpcTarget.DIRECT,
                id,
                "https://${if (':' in target.host) "[${target.host}]" else target.host}:${target.port}",
                "Bearer ${tokens.token()}",
                target.clientVersion,
                target.daemonId,
                target.host,
                target.port,
                target.daemonPublicKey.toByteArray().toNSData(),
                target.clientCertificate.toByteArray().toNSData(),
            )
        }
}

// Bounds frames buffered between a native stream and a slow consumer.
private const val STREAM_BUFFER = 256

internal class BridgeGrpcClient(
    private val bridge: NativeRpcBridge,
    private val target: suspend () -> NativeRpcTarget,
) : GrpcClient() {
    override fun <S : Any, R : Any> newCall(method: GrpcMethod<S, R>): GrpcCall<S, R> =
        UnaryCall(method)

    override fun <S : Any, R : Any> newServerStreamingCall(
        method: GrpcMethod<S, R>
    ): GrpcServerStreamingCall<S, R> = ServerStreamingCall(method)

    override fun <S : Any, R : Any> newStreamingCall(
        method: GrpcMethod<S, R>
    ): GrpcStreamingCall<S, R> =
        throw UnsupportedOperationException("Dieter exposes only unary and server-streaming RPCs")

    override fun <S : Any, R : Any> newClientStreamingCall(
        method: GrpcMethod<S, R>
    ): GrpcClientStreamingCall<S, R> =
        throw UnsupportedOperationException("Dieter exposes only unary and server-streaming RPCs")

    private abstract inner class Call<S : Any, R : Any>(val method: GrpcMethod<S, R>) {
        var handle: NativeRpcCancellable? = null
        var canceled = false
        var executed = false
        val timeout: Timeout = Timeout.NONE
        var requestMetadata: Map<String, String> = emptyMap()
        val responseMetadata: Map<String, String>? = null

        fun cancel() {
            canceled = true
            handle?.cancel()
        }

        fun begin() {
            check(!executed) { "already executed" }
            executed = true
        }
    }

    private inner class UnaryCall<S : Any, R : Any>(method: GrpcMethod<S, R>) :
        Call<S, R>(method), GrpcCall<S, R> {
        override suspend fun execute(request: S): R {
            begin()
            val destination = target()
            val payload = method.requestAdapter.encode(request).toNSData()
            val response = suspendCancellableCoroutine { continuation ->
                handle =
                    bridge.unary(
                        destination,
                        method.path,
                        payload,
                        object : NativeUnaryCompletion {
                            override fun succeeded(response: NSData) {
                                if (continuation.isActive)
                                    continuation.resume(response.toByteArray())
                            }

                            override fun failed(status: Int, message: String) {
                                if (continuation.isActive)
                                    continuation.resumeWithException(
                                        GrpcException(GrpcStatus.get(status), message)
                                    )
                            }
                        },
                    )
                continuation.invokeOnCancellation { cancel() }
            }
            return method.responseAdapter.decode(response)
        }

        override fun executeBlocking(request: S): R =
            throw UnsupportedOperationException(
                "blocking calls are not available on Apple platforms"
            )

        override fun enqueue(request: S, callback: GrpcCall.Callback<S, R>) =
            throw UnsupportedOperationException("use execute")

        override fun isCanceled() = canceled

        override fun isExecuted() = executed

        override fun clone(): GrpcCall<S, R> =
            UnaryCall(method).also { it.requestMetadata = requestMetadata }
    }

    private inner class ServerStreamingCall<S : Any, R : Any>(method: GrpcMethod<S, R>) :
        Call<S, R>(method), GrpcServerStreamingCall<S, R> {
        override suspend fun executeIn(scope: CoroutineScope, request: S): ReceiveChannel<R> {
            begin()
            val destination = target()
            val channel = Channel<R>(STREAM_BUFFER)
            channel.invokeOnClose { cancel() }
            handle =
                bridge.serverStreaming(
                    destination,
                    method.path,
                    method.requestAdapter.encode(request).toNSData(),
                    object : NativeStreamObserver {
                        override fun message(payload: NSData) {
                            val decoded = runCatching {
                                method.responseAdapter.decode(payload.toByteArray())
                            }
                            val sent = decoded.fold({ channel.trySend(it).isSuccess }, { false })
                            if (!sent)
                                channel.close(
                                    decoded.exceptionOrNull()
                                        ?: IOException("stream consumer fell behind")
                                )
                        }

                        override fun closed(status: Int, message: String) {
                            channel.close(
                                if (status == 0) null
                                else GrpcException(GrpcStatus.get(status), message)
                            )
                        }
                    },
                )
            return channel
        }

        override fun executeBlocking(request: S): MessageSource<R> =
            throw UnsupportedOperationException(
                "blocking calls are not available on Apple platforms"
            )

        override fun isCanceled() = canceled

        override fun isExecuted() = executed

        override fun clone(): GrpcServerStreamingCall<S, R> =
            ServerStreamingCall(method).also { it.requestMetadata = requestMetadata }
    }
}
