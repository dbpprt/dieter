package com.dbpprt.dieter.sharedcore

import android.content.Context
import com.dbpprt.dieter.BuildConfig
import com.dbpprt.dieter.api.gateway.v1.RTCConfiguration
import com.dbpprt.dieter.core.platform.ControlChannel
import com.dbpprt.dieter.core.platform.ControlChannelFactory
import com.dbpprt.dieter.core.platform.ControlFrames
import com.dbpprt.dieter.core.platform.ControlWindow
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
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/** The WebRTC control route for the shared core, as a loopback port that carries the daemon's TLS. */
internal class AndroidControlChannels(context: Context) : ControlChannelFactory {
    private val context = context.applicationContext

    // libwebrtc initializes synchronously; keep it off the core's single dispatcher.
    override suspend fun create(configuration: ByteArray): ControlChannel =
        withContext(Dispatchers.IO) { ControlRTCBridge(context, RTCConfiguration.ADAPTER.decode(configuration)) }
}

/** Bounded byte transport only. Existing gRPC TLS still authenticates the daemon. */
internal class ControlRTCBridge(context: Context, configuration: RTCConfiguration) : ControlChannel, AutoCloseable {
    private val closed = AtomicBoolean(false)
    private val credits = Semaphore(ControlFrames.WINDOW)
    private val window = ControlWindow()
    private val incoming = LinkedBlockingQueue<ByteArray>(ControlFrames.WINDOW)
    private val opened = CompletableDeferred<Unit>()
    private val gathered = CompletableDeferred<Unit>()
    @Volatile private var listener: ServerSocket? = null
    @Volatile private var socket: Socket? = null
    private val workers = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val peer: PeerConnection
    private val channel: DataChannel

    init {
        val config = PeerConnection.RTCConfiguration(configuration.ice_servers.map {
            PeerConnection.IceServer.builder(it.urls).setUsername(it.username).setPassword(it.credential).createIceServer()
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
        channel = peer.createDataChannel(ControlFrames.LABEL, DataChannel.Init().apply { ordered = true })
        channel.registerObserver(object : DataChannel.Observer {
            override fun onBufferedAmountChange(previousAmount: Long) {}
            override fun onStateChange() {
                if (channel.state() == DataChannel.State.OPEN) opened.complete(Unit)
                else if (channel.state() == DataChannel.State.CLOSED) close()
            }
            override fun onMessage(buffer: DataChannel.Buffer) {
                if (closed.get()) return
                val size = buffer.data.remaining()
                if (size !in 1..ControlFrames.MAX_FRAME) { close(); return }
                val data = ByteArray(size); buffer.data.get(data)
                when (val frame = ControlFrames.decode(data, buffer.binary)) {
                    ControlFrames.Frame.Ack -> if (window.acknowledge()) credits.release() else close()
                    is ControlFrames.Frame.Data -> if (!incoming.offer(frame.payload)) close()
                    null -> close()
                }
            }
        })
    }

    override suspend fun offer(): String {
        val description = suspendCancellableCoroutine<SessionDescription> { continuation ->
            peer.createOffer(object : SDPObserver() {
                override fun onCreateSuccess(description: SessionDescription) { if (continuation.isActive) continuation.resume(description) }
                override fun onCreateFailure(error: String) { if (continuation.isActive) continuation.resumeWithException(IllegalStateException(error)) }
            }, MediaConstraints())
        }
        setDescription(description, true)
        withTimeoutOrNull(3000) { gathered.await() }
        return requireNotNull(peer.localDescription).description.also { require(it.toByteArray().size <= ControlFrames.MAX_SDP_BYTES) }
    }

    override suspend fun connect(answerSdp: String): Int {
        val answer = answerSdp
        require(answer.toByteArray().size <= ControlFrames.MAX_SDP_BYTES)
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
                                check(channel.send(DataChannel.Buffer(ByteBuffer.wrap(ControlFrames.ack), true)))
                            }
                        } catch (_: Exception) { /* Transport failure is reported by gRPC. */ } finally { close() }
                    }
                    val input = client.getInputStream()
                    val bytes = ByteArray(ControlFrames.MAX_PAYLOAD)
                    while (isActive && !closed.get()) {
                        if (!credits.tryAcquire(1, TimeUnit.SECONDS)) continue
                        val count = input.read(bytes)
                        if (count < 0) break
                        check(count > 0 && window.reserve())
                        check(channel.send(DataChannel.Buffer(ByteBuffer.wrap(ControlFrames.data(bytes, count)), true)))
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
        @Synchronized private fun factory(context: Context): PeerConnectionFactory {
            sharedFactory?.let { return it }
            PeerConnectionFactory.initialize(PeerConnectionFactory.InitializationOptions.builder(context.applicationContext).createInitializationOptions())
            return PeerConnectionFactory.builder().createPeerConnectionFactory().also { sharedFactory = it }
        }
    }
}
