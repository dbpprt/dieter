package com.getdieter.core.platform

import com.getdieter.api.gateway.v1.GrpcRelayServiceClient
import com.getdieter.api.gateway.v1.RelayLane
import com.getdieter.api.gateway.v1.TunnelFrame
import com.getdieter.api.gateway.v1.TunnelFrameKind
import com.squareup.wire.GrpcException
import com.squareup.wire.GrpcStatus
import java.io.IOException
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.ClosedReceiveChannelException
import kotlinx.coroutines.channels.ReceiveChannel
import kotlinx.coroutines.channels.SendChannel
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Semaphore
import okio.ByteString.Companion.toByteString

/**
 * Relay tunnels over the gateway's `RelayService.OpenTunnel`, a bidirectional gRPC stream on
 * [transport]'s gateway channel, each bridged to a loopback port ([TunnelBridge]).
 */
class GrpcTunnelFactory(private val transport: RpcTransport) : TunnelFactory {
    override suspend fun open(access: GatewayAccess, daemonId: String, lane: RelayLane): Tunnel {
        val channel = transport.gateway(access)
        val call = GrpcRelayServiceClient(channel.client).OpenTunnel()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        try {
            val (send, receive) = call.executeIn(scope)
            send.send(
                TunnelFrame(
                    kind = TunnelFrameKind.TUNNEL_FRAME_KIND_OPEN,
                    daemon_id = daemonId,
                    lane = lane,
                )
            )
            val answer =
                try {
                    receive.receive()
                } catch (closed: ClosedReceiveChannelException) {
                    throw IOException("The relay ended the tunnel before it opened.", closed)
                }
            when (answer.kind) {
                TunnelFrameKind.TUNNEL_FRAME_KIND_OPENED -> {}
                TunnelFrameKind.TUNNEL_FRAME_KIND_CLOSE -> throw closeFailure(answer)
                else -> throw IOException("The relay answered the tunnel with ${answer.kind}.")
            }
            return TunnelBridge(send, receive, scope) {
                    call.cancel()
                    channel.close()
                }
                .also { it.start() }
        } catch (error: Throwable) {
            call.cancel()
            scope.cancel()
            channel.close()
            throw error
        }
    }

    private fun closeFailure(frame: TunnelFrame): GrpcException =
        GrpcException(
            GrpcStatus.get(frame.status_code).takeIf { it != GrpcStatus.OK }
                ?: GrpcStatus.UNAVAILABLE,
            frame.status_message.ifEmpty { "The relay could not reach this machine." },
        )
}

/**
 * Bridges one open tunnel ([send] and [receive] carry its frames after OPENED) to a loopback port
 * that accepts exactly one connection. Bytes read from the socket leave as DATA frames of at most
 * [MAX_DATA] bytes while fewer than [WINDOW] are uncredited; received DATA is written to the socket
 * before it is credited with WINDOW{1}. CLOSE, the end of either side, or [close] ends both
 * directions, once.
 */
class TunnelBridge(
    private val send: SendChannel<TunnelFrame>,
    private val receive: ReceiveChannel<TunnelFrame>,
    private val scope: CoroutineScope,
    private val acceptTimeoutMillis: Int = 30_000,
    private val onClose: () -> Unit = {},
) : Tunnel {
    private val closed = AtomicBoolean(false)
    private val server =
        ServerSocket(0, 1, InetAddress.getByName("127.0.0.1")).apply {
            soTimeout = acceptTimeoutMillis
        }
    @Volatile private var socket: Socket? = null
    private val credits = Semaphore(WINDOW)

    /** DATA frames sent and not yet credited. */
    private val uncredited = AtomicInteger()

    override val port: Int = server.localPort

    /** Accepts the one loopback connection and starts both directions. */
    fun start() {
        scope.launch {
            try {
                val accepted = server.accept()
                server.close()
                socket = accepted
                if (closed.get()) return@launch accepted.close()
                accepted.tcpNoDelay = true
                launch { downstream(accepted) }
                upstream(accepted)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Throwable) {
                // The TLS client above reports the failure.
            } finally {
                close()
            }
        }
    }

    /** Socket to gateway, within the credit window. */
    private suspend fun upstream(socket: Socket) {
        val input = socket.getInputStream()
        val buffer = ByteArray(MAX_DATA)
        while (!closed.get()) {
            credits.acquire()
            val count = input.read(buffer)
            if (count < 0) break
            if (count == 0) {
                credits.release()
                continue
            }
            uncredited.incrementAndGet()
            send.send(
                TunnelFrame(
                    kind = TunnelFrameKind.TUNNEL_FRAME_KIND_DATA,
                    data_ = buffer.toByteString(0, count),
                )
            )
        }
    }

    /** Gateway to socket; each DATA frame is credited once written. */
    private suspend fun downstream(socket: Socket) {
        try {
            val output = socket.getOutputStream()
            for (frame in receive) {
                when (frame.kind) {
                    TunnelFrameKind.TUNNEL_FRAME_KIND_DATA -> {
                        if (frame.data_.size > MAX_DATA) break
                        frame.data_.write(output)
                        output.flush()
                        send.send(
                            TunnelFrame(kind = TunnelFrameKind.TUNNEL_FRAME_KIND_WINDOW, credit = 1)
                        )
                    }
                    TunnelFrameKind.TUNNEL_FRAME_KIND_WINDOW -> {
                        // Credit for frames never sent is a protocol violation.
                        val credit = frame.credit
                        if (credit <= 0 || uncredited.addAndGet(-credit) < 0) break
                        repeat(credit) { credits.release() }
                    }
                    else -> break
                }
            }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (_: Throwable) {
            // The TLS client above reports the failure.
        } finally {
            close()
        }
    }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        send.trySend(TunnelFrame(kind = TunnelFrameKind.TUNNEL_FRAME_KIND_CLOSE))
        send.close()
        runCatching { socket?.close() }
        runCatching { server.close() }
        receive.cancel()
        scope.cancel()
        onClose()
    }

    val isClosed: Boolean
        get() = closed.get()

    companion object {
        /** DATA frames each side may have uncredited. */
        const val WINDOW = 8

        /** The largest DATA payload. */
        const val MAX_DATA = 64 * 1024
    }
}
