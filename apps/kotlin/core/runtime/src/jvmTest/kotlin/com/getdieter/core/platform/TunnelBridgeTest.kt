package com.getdieter.core.platform

import com.getdieter.api.gateway.v1.TunnelFrame
import com.getdieter.api.gateway.v1.TunnelFrameKind
import java.net.Socket
import java.util.concurrent.atomic.AtomicInteger
import kotlin.concurrent.thread
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull
import okio.ByteString.Companion.toByteString

/** The loopback bridge of a relay tunnel: credit window, crediting after writes, and closing. */
class TunnelBridgeTest {
    /** Frames the bridge sends to the gateway. */
    private val toGateway = Channel<TunnelFrame>(Channel.UNLIMITED)

    /** Frames the gateway sends to the bridge. */
    private val fromGateway = Channel<TunnelFrame>(Channel.UNLIMITED)
    private val closes = AtomicInteger()
    private val bridge =
        TunnelBridge(
            toGateway,
            fromGateway,
            CoroutineScope(SupervisorJob() + Dispatchers.IO),
            onClose = { closes.incrementAndGet() },
        )
    private val socket by lazy { Socket("127.0.0.1", bridge.port) }

    init {
        bridge.start()
    }

    @AfterTest
    fun tearDown() {
        bridge.close()
        runCatching { socket.close() }
    }

    private suspend fun next(): TunnelFrame = withTimeout(5.seconds) { toGateway.receive() }

    @Test
    fun atMostEightUncreditedFramesLeaveUntilTheGatewayCreditsThem() = runBlocking {
        val payload = ByteArray(12 * TunnelBridge.MAX_DATA) { (it % 251).toByte() }
        val writer = thread {
            runCatching {
                socket.getOutputStream().apply {
                    write(payload)
                    flush()
                }
            }
        }
        val received = mutableListOf<TunnelFrame>()
        // Without credit the bridge stops at the window, however much the socket holds.
        while (true) {
            val frame = withTimeoutOrNull(500.milliseconds) { toGateway.receive() } ?: break
            received += frame
        }
        assertEquals(TunnelBridge.WINDOW, received.size)
        assertTrue(received.all { it.kind == TunnelFrameKind.TUNNEL_FRAME_KIND_DATA })
        assertTrue(received.all { it.data_.size in 1..TunnelBridge.MAX_DATA })
        // Credit releases the rest.
        var total = received.sumOf { it.data_.size }
        while (total < payload.size) {
            fromGateway.send(
                TunnelFrame(kind = TunnelFrameKind.TUNNEL_FRAME_KIND_WINDOW, credit = 1)
            )
            val frame = next()
            assertEquals(TunnelFrameKind.TUNNEL_FRAME_KIND_DATA, frame.kind)
            received += frame
            total += frame.data_.size
        }
        writer.join()
        val sent = received.fold(okio.Buffer()) { buffer, frame -> buffer.write(frame.data_) }
        assertContentEquals(payload, sent.readByteArray())
    }

    @Test
    fun gatewayDataReachesTheSocketBeforeItIsCredited() = runBlocking {
        socket.soTimeout = 5_000
        val input = socket.getInputStream()
        repeat(3) { index ->
            fromGateway.send(
                TunnelFrame(
                    kind = TunnelFrameKind.TUNNEL_FRAME_KIND_DATA,
                    data_ = byteArrayOf(index.toByte(), 7, 7).toByteString(),
                )
            )
        }
        val bytes = ByteArray(9)
        var read = 0
        while (read < bytes.size) read += input.read(bytes, read, bytes.size - read)
        assertContentEquals(byteArrayOf(0, 7, 7, 1, 7, 7, 2, 7, 7), bytes)
        repeat(3) {
            val credit = next()
            assertEquals(TunnelFrameKind.TUNNEL_FRAME_KIND_WINDOW, credit.kind)
            assertEquals(1, credit.credit)
        }
    }

    @Test
    fun aCloseFromTheGatewayEndsTheSocketOnce() = runBlocking {
        socket.soTimeout = 5_000
        fromGateway.send(TunnelFrame(kind = TunnelFrameKind.TUNNEL_FRAME_KIND_CLOSE))
        assertEquals(-1, socket.getInputStream().read())
        withTimeout(5.seconds) { while (!bridge.isClosed) delay(10) }
        bridge.close()
        bridge.close()
        assertEquals(1, closes.get())
    }

    @Test
    fun theSocketsEndClosesTheTunnel() = runBlocking {
        socket.shutdownOutput()
        val frames = mutableListOf<TunnelFrame>()
        withTimeout(5.seconds) {
            for (frame in toGateway) frames += frame
            // The gateway side ends before the bridge finishes closing.
            while (closes.get() == 0) delay(10)
        }
        assertEquals(TunnelFrameKind.TUNNEL_FRAME_KIND_CLOSE, frames.last().kind)
        assertEquals(1, closes.get())
    }

    @Test
    fun creditForFramesNeverSentIsAProtocolViolation() = runBlocking {
        socket.soTimeout = 5_000
        fromGateway.send(TunnelFrame(kind = TunnelFrameKind.TUNNEL_FRAME_KIND_WINDOW, credit = 1))
        assertEquals(-1, socket.getInputStream().read())
        withTimeout(5.seconds) { while (!bridge.isClosed) delay(10) }
    }
}
