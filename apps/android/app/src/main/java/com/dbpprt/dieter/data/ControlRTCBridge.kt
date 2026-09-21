package com.dbpprt.dieter.data

import android.content.Context
import com.dbpprt.dieter.BuildConfig
import com.dbpprt.dieter.gateway.v1.RTCConfiguration
import io.grpc.*
import kotlinx.coroutines.*
import org.webrtc.*
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.nio.ByteBuffer
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.Semaphore
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/** Bounded byte transport only. Existing gRPC TLS still authenticates the daemon. */
internal class ControlRTCBridge(context: Context, configuration: RTCConfiguration) : AutoCloseable {
    internal data class CandidateSummary(val host: Int, val srflx: Int, val relay: Int)

    private val closed = AtomicBoolean(false)
    private val credits = Semaphore(16)
    private val outstanding = AtomicInteger(0)
    private val incoming = LinkedBlockingQueue<ByteArray>(16)
    private val opened = CompletableDeferred<Unit>()
    private val gathered = CompletableDeferred<Unit>()
    @Volatile private var listener: ServerSocket? = null
    @Volatile private var socket: Socket? = null
    private val workers = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val peer: PeerConnection
    private val channel: DataChannel

    init {
        val config = PeerConnection.RTCConfiguration(configuration.iceServersList.map {
            PeerConnection.IceServer.builder(it.urlsList).setUsername(it.username).setPassword(it.credential).createIceServer()
        }).apply {
            sdpSemantics = PeerConnection.SdpSemantics.UNIFIED_PLAN
            if (BuildConfig.DEBUG && java.lang.Boolean.getBoolean("dieter.test.forceTURN")) {
                iceTransportsType = PeerConnection.IceTransportsType.RELAY
            }
        }
        peer = requireNotNull(factory(context).createPeerConnection(config, object : PeerConnection.Observer {
            override fun onSignalingChange(state: PeerConnection.SignalingState) {}
            override fun onIceConnectionChange(state: PeerConnection.IceConnectionState) {
                if (state == PeerConnection.IceConnectionState.FAILED || state == PeerConnection.IceConnectionState.CLOSED) close()
            }
            override fun onIceConnectionReceivingChange(receiving: Boolean) {}
            override fun onIceGatheringChange(state: PeerConnection.IceGatheringState) { if (state == PeerConnection.IceGatheringState.COMPLETE) gathered.complete(Unit) }
            override fun onIceCandidate(candidate: IceCandidate) {}
            override fun onIceCandidatesRemoved(candidates: Array<out IceCandidate>) {}
            override fun onAddStream(stream: MediaStream) {}
            override fun onRemoveStream(stream: MediaStream) {}
            override fun onDataChannel(channel: DataChannel) { close() }
            override fun onRenegotiationNeeded() {}
        }))
        channel = peer.createDataChannel("dieter-control-tls-v1", DataChannel.Init().apply { ordered = true })
        channel.registerObserver(object : DataChannel.Observer {
            override fun onBufferedAmountChange(previousAmount: Long) {}
            override fun onStateChange() {
                if (channel.state() == DataChannel.State.OPEN) opened.complete(Unit)
                else if (channel.state() == DataChannel.State.CLOSED) close()
            }
            override fun onMessage(buffer: DataChannel.Buffer) {
                if (closed.get()) return
                val size = buffer.data.remaining()
                if (!buffer.binary || size !in 1..16384) { close(); return }
                val data = ByteArray(size); buffer.data.get(data)
                when {
                    data[0] == 1.toByte() && size == 1 -> {
                        if (outstanding.decrementAndGet() < 0) { close(); return }
                        credits.release()
                    }
                    data[0] == 0.toByte() && size > 1 -> if (!incoming.offer(data.copyOfRange(1, size))) close()
                    else -> close()
                }
            }
        })
    }

    suspend fun offer(): String {
        val description = suspendCancellableCoroutine<SessionDescription> { continuation ->
            peer.createOffer(object : SDPObserver() {
                override fun onCreateSuccess(description: SessionDescription) { if (continuation.isActive) continuation.resume(description) }
                override fun onCreateFailure(error: String) { if (continuation.isActive) continuation.resumeWithException(IllegalStateException(error)) }
            }, MediaConstraints())
        }
        setDescription(description, true)
        withTimeoutOrNull(3000) { gathered.await() }
        return requireNotNull(peer.localDescription).description.also { require(it.toByteArray().size <= 65536) }
    }

    suspend fun connect(answer: String): Int {
        require(answer.toByteArray().size <= 65536)
        setDescription(SessionDescription(SessionDescription.Type.ANSWER, answer), false)
        withTimeoutOrNull(8000) { opened.await() } ?: error("WebRTC control connection timed out")
        return withContext(Dispatchers.IO) {
            check(!closed.get())
            val server = ServerSocket(0, 1, InetAddress.getByName("127.0.0.1"))
            listener = server
            if (closed.get()) { server.close(); error("Control connection closed") }
            workers.launch {
                try {
                    val client = server.accept()
                    socket = client
                    server.close()
                    if (closed.get()) { client.close(); return@launch }
                    client.tcpNoDelay = true
                    launch {
                        try {
                            val output = client.getOutputStream()
                            while (isActive && !closed.get()) {
                                val frame = incoming.poll(1, TimeUnit.SECONDS) ?: continue
                                output.write(frame)
                                check(channel.send(DataChannel.Buffer(ByteBuffer.wrap(byteArrayOf(1)), true)))
                            }
                        } catch (_: Exception) { /* Transport failure is reported by gRPC. */ } finally { close() }
                    }
                    val input = client.getInputStream()
                    val bytes = ByteArray(16384)
                    while (isActive && !closed.get()) {
                        if (!credits.tryAcquire(1, TimeUnit.SECONDS)) continue
                        val count = input.read(bytes, 1, 16383)
                        if (count < 0) break
                        outstanding.incrementAndGet()
                        check(channel.send(DataChannel.Buffer(ByteBuffer.wrap(bytes.copyOf(count + 1)), true)))
                    }
                } catch (_: Exception) { /* Transport failure is reported by gRPC. */ } finally { close() }
            }
            server.localPort
        }
    }

    private suspend fun setDescription(description: SessionDescription, local: Boolean) {
        suspendCancellableCoroutine<Unit> { continuation ->
            val observer = object : SDPObserver() {
                override fun onSetSuccess() { if (continuation.isActive) continuation.resume(Unit) }
                override fun onSetFailure(error: String) { if (continuation.isActive) continuation.resumeWithException(IllegalStateException(error)) }
            }
            if (local) peer.setLocalDescription(observer, description) else peer.setRemoteDescription(observer, description)
        }
    }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        opened.completeExceptionally(IllegalStateException("Control connection closed"))
        gathered.complete(Unit)
        runCatching { listener?.close() }; runCatching { socket?.close() }
        workers.cancel()
        incoming.clear()
        // Never dispose libwebrtc on its signaling/callback thread.
        CoroutineScope(Dispatchers.IO).launch {
            channel.unregisterObserver(); channel.close(); peer.close(); channel.dispose(); peer.dispose()
        }
    }
    private open class SDPObserver : SdpObserver {
        override fun onCreateSuccess(description: SessionDescription) {}
        override fun onSetSuccess() {}
        override fun onCreateFailure(error: String) {}
        override fun onSetFailure(error: String) {}
    }
    companion object {
        private var sharedFactory: PeerConnectionFactory? = null
        fun candidateSummary(sdp: String): CandidateSummary {
            var host = 0
            var srflx = 0
            var relay = 0
            sdp.lineSequence().filter { it.startsWith("a=candidate:") }.forEach { line ->
                val tokens = line.trim().split(Regex("\\s+"))
                val type = tokens.indexOf("typ").takeIf { it >= 0 }?.let { tokens.getOrNull(it + 1) }
                when (type) {
                    "host" -> host++
                    "srflx" -> srflx++
                    "relay" -> relay++
                }
            }
            return CandidateSummary(host, srflx, relay)
        }
        @Synchronized private fun factory(context: Context): PeerConnectionFactory {
            sharedFactory?.let { return it }
            PeerConnectionFactory.initialize(PeerConnectionFactory.InitializationOptions.builder(context.applicationContext).createInitializationOptions())
            return PeerConnectionFactory.builder().createPeerConnectionFactory().also { sharedFactory = it }
        }
    }
}

/** Channel shutdown owns the RTC peer and its one-use loopback listener. */
internal class ControlRTCChannel(private val delegate: ManagedChannel, private val bridge: ControlRTCBridge) : ManagedChannel() {
    override fun shutdown(): ManagedChannel { bridge.close(); delegate.shutdown(); return this }
    override fun shutdownNow(): ManagedChannel { bridge.close(); delegate.shutdownNow(); return this }
    override fun isShutdown() = delegate.isShutdown
    override fun isTerminated() = delegate.isTerminated
    override fun awaitTermination(timeout: Long, unit: TimeUnit) = delegate.awaitTermination(timeout, unit)
    override fun authority() = delegate.authority()
    override fun <RequestT : Any?, ResponseT : Any?> newCall(methodDescriptor: MethodDescriptor<RequestT, ResponseT>, callOptions: CallOptions): ClientCall<RequestT, ResponseT> = delegate.newCall(methodDescriptor, callOptions)
    override fun getState(requestConnection: Boolean) = delegate.getState(requestConnection)
    override fun notifyWhenStateChanged(source: ConnectivityState, callback: Runnable) = delegate.notifyWhenStateChanged(source, callback)
    override fun resetConnectBackoff() = delegate.resetConnectBackoff()
    override fun enterIdle() = delegate.enterIdle()
}
