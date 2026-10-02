package com.dbpprt.dieter.shared

import com.dbpprt.dieter.api.gateway.v1.RTCConfiguration
import com.dbpprt.dieter.api.v1.GrpcDieterServiceClient
import com.dbpprt.dieter.api.v1.RemoteDesktopClipboardItem
import com.dbpprt.dieter.api.v1.RemoteDesktopICECandidate
import com.dbpprt.dieter.api.v1.RemoteDesktopReceiverFeedback
import com.dbpprt.dieter.api.v1.RemoteDesktopRenderMeasurement
import com.dbpprt.dieter.client.v1.ClipboardContent
import com.dbpprt.dieter.client.v1.Command
import com.dbpprt.dieter.client.v1.Failure
import com.dbpprt.dieter.client.v1.Reply
import com.dbpprt.dieter.client.v1.RtpCodec as ClientRtpCodec
import com.dbpprt.dieter.client.v1.ScreenChannel
import com.dbpprt.dieter.client.v1.ScreenMediaCapabilities as ClientScreenMediaCapabilities
import com.dbpprt.dieter.client.v1.ScreenMediaConfig as ClientScreenMediaConfig
import com.dbpprt.dieter.client.v1.Slice
import com.dbpprt.dieter.core.CoreRuntime
import com.dbpprt.dieter.core.RuntimeConfig
import com.dbpprt.dieter.core.client.ClientApi
import com.dbpprt.dieter.core.client.ClientFailure
import com.dbpprt.dieter.core.client.ClientSubscription
import com.dbpprt.dieter.core.client.ScreenHost
import com.dbpprt.dieter.core.conversation.ConversationConfig
import com.dbpprt.dieter.core.conversation.TranscriptRetention
import com.dbpprt.dieter.core.notifications.NotificationContent
import com.dbpprt.dieter.core.notifications.NotificationSink
import com.dbpprt.dieter.core.platform.AuthHttp
import com.dbpprt.dieter.core.platform.ControlChannel
import com.dbpprt.dieter.core.platform.ControlChannelFactory
import com.dbpprt.dieter.core.platform.DeviceSettings
import com.dbpprt.dieter.core.platform.GatewayAccess
import com.dbpprt.dieter.core.platform.HttpResponse
import com.dbpprt.dieter.core.platform.Platform
import com.dbpprt.dieter.core.platform.SecureStore
import com.dbpprt.dieter.core.platform.SignatureVerifier
import com.dbpprt.dieter.core.runtime.CoreLogger
import com.dbpprt.dieter.core.runtime.SilentLogger
import com.dbpprt.dieter.core.screens.LocalClipboard
import com.dbpprt.dieter.core.screens.PeerState
import com.dbpprt.dieter.core.screens.ReceiverSample
import com.dbpprt.dieter.core.screens.ReceiverStatistics
import com.dbpprt.dieter.core.screens.RtpCodec
import com.dbpprt.dieter.core.screens.ScreenConfig
import com.dbpprt.dieter.core.screens.ScreenMediaCapabilities
import com.dbpprt.dieter.core.screens.ScreenMediaConfig
import com.dbpprt.dieter.core.screens.ScreenMediaEngine
import com.dbpprt.dieter.core.screens.ScreenMediaEngineFactory
import com.dbpprt.dieter.core.screens.ScreenMediaEvents
import com.dbpprt.dieter.core.screens.ScreenRoute
import com.dbpprt.dieter.core.screens.ScreenRouteFactory
import com.dbpprt.dieter.core.screens.ViewportPolicy
import com.squareup.wire.GrpcException
import com.squareup.wire.GrpcStatus
import kotlin.coroutines.cancellation.CancellationException
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.CancellableContinuation
import kotlinx.coroutines.suspendCancellableCoroutine
import okio.FileSystem
import okio.IOException
import okio.Path.Companion.toPath
import platform.Foundation.NSData

/** Keychain on Apple platforms. */
interface NativeSecureStore {
    fun read(key: String): String?
    fun write(key: String, value: String)
    fun delete(key: String)
}

/** UserDefaults: device-local preferences. */
interface NativeSettings {
    fun string(key: String): String?
    fun putString(key: String, value: String?)
}

/** URLSession: the OAuth code exchange. [completion] receives status and body, or status 0 on a transport error. */
interface NativeHttp {
    fun postJson(url: String, body: String, completion: NativeHttpCompletion)
}

interface NativeHttpCompletion {
    fun completed(status: Int, body: String)
}

/** CryptoKit `Curve25519.Signing.PublicKey` verification. */
interface NativeSignatures {
    fun verifyEd25519(publicKey: NSData, message: NSData, signature: NSData): Boolean
}

/** `os_log`. Levels: 0 debug, 1 info, 2 warning. */
interface NativeLogger {
    fun log(level: Int, tag: String, message: String)
}

/**
 * UserNotifications. [role] is the core's NotificationRole name; [actions]
 * are NotificationAction names (e.g. `MARK_DONE`, `OPEN`). [session] marks a
 * running chat's turn, so dismissing it hides only that turn.
 */
interface NativeNotifications {
    fun post(key: String, role: String, title: String, text: String, expanded: String?, actions: List<String>, session: String?): Boolean
    fun cancel(key: String)
}

/**
 * The WebRTC control route (`ControlRTCBridge`): a data channel to one daemon
 * exposed as a loopback port that carries the daemon's TLS. Each completion
 * is called once, on any thread.
 */
interface NativeControlChannels {
    /** [configuration] is an encoded `dieter.gateway.v1.RTCConfiguration`. */
    fun create(configuration: NSData, completion: NativeControlChannelCompletion)
}

interface NativeControlChannelCompletion {
    fun completed(channel: NativeControlChannel?, error: String?)
}

interface NativeControlChannel {
    /** Gathers ICE and returns the local SDP offer. */
    fun offer(completion: NativeControlOfferCompletion)

    /** Applies the daemon's answer; completes with the loopback port bridged to the channel. */
    fun connect(answerSdp: String, completion: NativeControlConnectCompletion)
    fun close()
}

interface NativeControlOfferCompletion {
    fun completed(sdp: String?, error: String?)
}

interface NativeControlConnectCompletion {
    fun completed(port: Int, error: String?)
}

/** Receives encoded `dieter.client.v1.Update`s on a core thread; hop to the main actor. */
interface SharedObserver {
    fun update(bytes: NSData)
}

/** The native WebRTC stack for screen sharing: peer, decoders, and renderer. */
interface NativeScreenMedia {
    /** An encoded `dieter.client.v1.ScreenMediaCapabilities`. */
    fun capabilities(): NSData

    /**
     * [configuration] is an encoded `dieter.client.v1.ScreenMediaConfig`;
     * [scope] is the screen view the engine renders into.
     */
    fun create(configuration: NSData, scope: String, events: NativeScreenMediaEvents): NativeScreenMediaEngine
}

/** Media events into the core; they may arrive on any thread. */
class NativeScreenMediaEvents internal constructor(private val events: ScreenMediaEvents) {
    /** [candidate] is an encoded `dieter.v1.RemoteDesktopICECandidate`. */
    fun localCandidate(candidate: NSData) = events.localCandidate(RemoteDesktopICECandidate.ADAPTER.decode(candidate.toByteArray()))

    /** [state] is the ordinal of new, connecting, connected, disconnected, failed, or closed. */
    fun peerState(state: Int) = events.peerState(PeerState.entries.getOrElse(state) { PeerState.FAILED })
    fun channelState(label: String, open: Boolean) = events.channelState(label, open)
    fun channelMessage(label: String, bytes: NSData) = events.channelMessage(label, bytes.toByteArray())
    fun decoded(rtpTimestamp: Long) = events.decoded(rtpTimestamp.toUInt())
    fun presented(rtpTimestamp: Long) = events.presented(rtpTimestamp.toUInt())
    fun hevcUnavailable(reason: String) = events.hevcUnavailable(reason)
    fun failure(message: String) = events.failure(message)
}

/** One peer connection, its tracks and channels, as the core drives it. */
interface NativeScreenMediaEngine {
    /** Creates and applies the local offer. */
    fun createOffer(completion: NativeScreenTextCompletion)
    fun applyAnswer(sdp: String, completion: NativeScreenDoneCompletion)

    /** [candidate] is an encoded `dieter.v1.RemoteDesktopICECandidate`. */
    fun addRemoteCandidate(candidate: NSData, completion: NativeScreenDoneCompletion)

    /** Thread-safe; false when the channel is not open or the send failed. */
    fun send(label: String, bytes: NSData): Boolean
    fun isOpen(label: String): Boolean
    fun bufferedAmount(label: String): Long

    /** Completes with the receiver's cumulative counters, or nil before media flows. */
    fun statistics(completion: NativeScreenSampleCompletion)
    fun updateFrameGate(token: Long, displayGeneration: Long, mediaGeneration: Long, mediaTimestamp: Long)
    fun resetVideo()
    fun close()
}

interface NativeScreenTextCompletion {
    fun completed(text: String?, error: String?)
}

interface NativeScreenDoneCompletion {
    fun completed(error: String?)
}

interface NativeScreenSampleCompletion {
    fun completed(sample: NativeReceiverSample?)
}

/** Cumulative WebRTC receiver counters and Metal presentations, sampled at [atMillis] (monotonic). */
class NativeReceiverSample(
    val atMillis: Long,
    val framesDecoded: Double,
    val totalDecodeTime: Double,
    val jitterBufferEmittedCount: Double,
    val jitterBufferDelay: Double,
    val packetsLost: Double,
    val packetsReceived: Double,
    val presented: Long,
    val renderMilliseconds: Double,
    val jitterSeconds: Double,
    val roundTripSeconds: Double,
    val decoderImplementation: String,
)

/**
 * Test-only: screens signal through an isolated loopback fixture instead of
 * the machine's route. Never set in the app.
 */
interface NativeScreenFixture {
    /** Null when the fixture's network is unavailable, which is retryable. */
    fun open(): NativeScreenFixtureRoute?
}

/** [rtc] is an encoded `dieter.gateway.v1.RTCConfiguration`; [url] must be loopback HTTP. */
class NativeScreenFixtureRoute(val url: String, val token: String, val certificatePem: String, val rtc: NSData, val label: String)

/** The pasteboard, as clipboard sync needs it. */
interface NativeClipboard {
    /** Changes whenever the pasteboard changes. */
    fun stamp(): Long

    /** An encoded `dieter.client.v1.ClipboardContent`, or nil when nothing can be shared. */
    fun read(binary: Boolean): NSData?

    /** [content] is an encoded `dieter.client.v1.ClipboardContent`. */
    fun apply(content: NSData)
}

class SharedSubscription internal constructor(private val subscription: ClientSubscription) {
    fun close() = subscription.close()
}

class SharedConfiguration(
    val stateDirectory: String,
    val clientVersion: String,
    val oauthRedirectUri: String,
    /** `mac` or `ios`: the prefix of a newly generated sync client ID. */
    val clientIdPrefix: String,
    /** Only macOS can run a daemon itself, so only it tries loopback routes. */
    val includeLoopbackRoutes: Boolean,
    /** Phones keep a smaller transcript window than desktops. */
    val compactTranscripts: Boolean,
    /** The name a shared screen's host shows for this client. */
    val screenClientName: String,
    /** Desktops ask for their view's size; tablets for a coarse grid. */
    val desktopScreens: Boolean,
)

class SharedExtensions(
    val rpc: NativeRpcBridge,
    val secureStore: NativeSecureStore,
    val settings: NativeSettings,
    val http: NativeHttp,
    val signatures: NativeSignatures?,
    val logger: NativeLogger?,
    val notifications: NativeNotifications?,
    /** Absent: the core never tries the WebRTC route. */
    val controlChannels: NativeControlChannels? = null,
    /** Absent: screen sharing is unavailable. */
    val screenMedia: NativeScreenMedia? = null,
    val clipboard: NativeClipboard? = null,
    /** Test-only; see [NativeScreenFixture]. */
    val screenFixture: NativeScreenFixture? = null,
)

/**
 * The Apple entry point to the shared core. Swift dispatches encoded
 * `dieter.client.v1.Command`s and observes encoded slices; SwiftProtobuf
 * types stay the Apple UI model. Only this module's API is exported.
 */
class DieterShared(configuration: SharedConfiguration, extensions: SharedExtensions) {
    private val transport = NativeRpcTransport(extensions.rpc)
    internal fun fixtureChannel(access: GatewayAccess) = transport.gateway(access)
    private val runtime = CoreRuntime(
        Platform(
            transport = transport,
            secureStore = object : SecureStore {
                override fun read(key: String) = extensions.secureStore.read(key)
                override fun write(key: String, value: String) = extensions.secureStore.write(key, value)
                override fun delete(key: String) = extensions.secureStore.delete(key)
            },
            settings = object : DeviceSettings {
                override fun string(key: String) = extensions.settings.string(key)
                override fun putString(key: String, value: String?) = extensions.settings.putString(key, value)
            },
            http = NativeAuthHttp(extensions.http),
            fileSystem = FileSystem.SYSTEM,
            stateDirectory = configuration.stateDirectory.toPath(),
            signatures = extensions.signatures?.let { native ->
                object : SignatureVerifier {
                    override fun verifyEd25519(publicKey: ByteArray, message: ByteArray, signature: ByteArray) =
                        native.verifyEd25519(publicKey.toNSData(), message.toNSData(), signature.toNSData())
                }
            },
            notifications = extensions.notifications?.let { native ->
                object : NotificationSink {
                    override fun post(content: NotificationContent) = native.post(
                        content.key, content.role.name, content.title, content.text, content.expanded,
                        content.actions.map { it.name }, content.session,
                    )
                    override fun cancel(key: String) = native.cancel(key)
                }
            },
            controlChannels = extensions.controlChannels?.let(::NativeControlChannelFactory),
            logger = extensions.logger?.let { native ->
                object : CoreLogger {
                    override fun debug(tag: String, message: String) = native.log(0, tag, message)
                    override fun info(tag: String, message: String) = native.log(1, tag, message)
                    override fun warn(tag: String, message: String, error: Throwable?) =
                        native.log(2, tag, if (error == null) message else "$message: ${error.message}")
                }
            } ?: SilentLogger,
        ),
        RuntimeConfig(
            clientVersion = configuration.clientVersion,
            oauthRedirectUri = configuration.oauthRedirectUri,
            includeLoopbackRoutes = configuration.includeLoopbackRoutes,
            clientIdPrefix = configuration.clientIdPrefix,
            conversations = ConversationConfig(retention = if (configuration.compactTranscripts) TranscriptRetention.MOBILE else TranscriptRetention.DESKTOP),
        ),
    )
    private val api = ClientApi(
        runtime,
        extensions.screenMedia?.let { media ->
            ScreenHost(
                { scope -> NativeScreenMediaFactory(media, scope) }, extensions.clipboard?.let(::NativeClipboardAdapter),
                ScreenConfig(configuration.screenClientName, if (configuration.desktopScreens) ViewportPolicy.Desktop else ViewportPolicy.Tablet),
                extensions.screenFixture?.let { fixture -> { _: String -> fixtureRoutes(fixture, configuration.clientVersion) } },
            )
        },
    )

    /** Starts supervision; cached state is observable before this. */
    fun start() = runtime.start()

    /**
     * Runs an encoded `Command` and returns an encoded `Reply`. Failures are
     * part of the reply, so Swift never parses an NSError.
     */
    @Throws(CancellationException::class)
    suspend fun dispatch(command: NSData): NSData {
        val reply = try {
            Reply(result = api.dispatch(Command.ADAPTER.decode(command.toByteArray())))
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (failure: ClientFailure) {
            Reply(failure = failure.failure)
        } catch (error: Throwable) {
            Reply(failure = Failure(Failure.Kind.KIND_INVALID, error.message ?: "The command could not be read."))
        }
        return Reply.ADAPTER.encode(reply).toNSData()
    }

    /**
     * Observes [slice] (a `dieter.client.v1.Slice` number); [scope] is the card
     * ID for conversations and the view's surface key for view-owned surfaces.
     */
    fun observe(slice: Int, scope: String, observer: SharedObserver): SharedSubscription =
        SharedSubscription(api.observe(Slice.fromValue(slice) ?: Slice.SLICE_UNSPECIFIED, scope) { update -> observer.update(update.encode().toNSData()) })

    @Throws(CancellationException::class)
    suspend fun shutdown() = runtime.shutdown()
}

private class NativeControlChannelFactory(private val native: NativeControlChannels) : ControlChannelFactory {
    override suspend fun create(configuration: ByteArray): ControlChannel = suspendCancellableCoroutine { continuation ->
        native.create(configuration.toNSData(), object : NativeControlChannelCompletion {
            override fun completed(channel: NativeControlChannel?, error: String?) {
                if (channel == null) {
                    if (continuation.isActive) continuation.resumeWithException(IOException(error ?: "The WebRTC control channel could not be created."))
                    return
                }
                val adapted = NativeControlChannelAdapter(channel)
                if (continuation.isActive) continuation.resume(adapted) else channel.close()
            }
        })
    }
}

private class NativeControlChannelAdapter(private val native: NativeControlChannel) : ControlChannel {
    override suspend fun offer(): String = suspendCancellableCoroutine { continuation ->
        continuation.invokeOnCancellation { native.close() }
        native.offer(object : NativeControlOfferCompletion {
            override fun completed(sdp: String?, error: String?) {
                if (!continuation.isActive) return
                if (sdp != null) continuation.resume(sdp) else continuation.resumeWithException(IOException(error ?: "The WebRTC offer failed."))
            }
        })
    }

    override suspend fun connect(answerSdp: String): Int = suspendCancellableCoroutine { continuation ->
        continuation.invokeOnCancellation { native.close() }
        native.connect(answerSdp, object : NativeControlConnectCompletion {
            override fun completed(port: Int, error: String?) {
                if (!continuation.isActive) return
                if (error == null && port > 0) continuation.resume(port) else continuation.resumeWithException(IOException(error ?: "The WebRTC control channel did not open."))
            }
        })
    }

    override fun close() = native.close()
}

private fun DieterShared.fixtureRoutes(fixture: NativeScreenFixture, clientVersion: String): ScreenRouteFactory = {
    val opened = fixture.open() ?: throw GrpcException(GrpcStatus.UNAVAILABLE, "Injected sleeping laptop network")
    require(opened.url.startsWith("http://127.0.0.1:")) { "A screen fixture must be loopback" }
    val channel = fixtureChannel(GatewayAccess(opened.url, opened.token, clientVersion))
    ScreenRoute(
        GrpcDieterServiceClient(channel.client), opened.certificatePem, RTCConfiguration.ADAPTER.decode(opened.rtc.toByteArray()), opened.label,
        onClose = channel::close,
    )
}

private class NativeScreenMediaFactory(private val native: NativeScreenMedia, private val scope: String) : ScreenMediaEngineFactory {
    override val capabilities: ScreenMediaCapabilities by lazy {
        val decoded = ClientScreenMediaCapabilities.ADAPTER.decode(native.capabilities().toByteArray())
        ScreenMediaCapabilities(
            receiveCodecs = decoded.receive_codecs.map { RtpCodec(it.name, it.profile.ifEmpty { null }) },
            hevcDecoder = decoded.hevc_decoder, referenceDependencies = decoded.reference_dependencies,
            millisecondTimestamps = decoded.millisecond_timestamps, initializationFailure = decoded.initialization_failure.ifEmpty { null },
        )
    }

    override fun create(config: ScreenMediaConfig, events: ScreenMediaEvents): ScreenMediaEngine {
        val encoded = ClientScreenMediaConfig(
            rtc = config.rtc, codecs = config.codecs.map { ClientRtpCodec(it.name, it.profile.orEmpty()) },
            enable_reference_dependencies = config.enableReferenceDependencies,
            channels = config.channels.map { ScreenChannel(it.label, it.ordered, it.maxRetransmits) }, relay_only = config.relayOnly,
        )
        return NativeScreenMediaEngineAdapter(native.create(ClientScreenMediaConfig.ADAPTER.encode(encoded).toNSData(), scope, NativeScreenMediaEvents(events)))
    }
}

private class NativeScreenMediaEngineAdapter(private val native: NativeScreenMediaEngine) : ScreenMediaEngine {
    override suspend fun createOffer(): String = suspendCancellableCoroutine { continuation ->
        native.createOffer(object : NativeScreenTextCompletion {
            override fun completed(text: String?, error: String?) {
                if (!continuation.isActive) return
                if (text != null) continuation.resume(text) else continuation.resumeWithException(IOException(error ?: "The screen offer failed."))
            }
        })
    }

    override suspend fun applyAnswer(sdp: String) = suspendCancellableCoroutine { continuation ->
        native.applyAnswer(sdp, done(continuation, "The screen answer could not be applied."))
    }

    override suspend fun addRemoteCandidate(candidate: RemoteDesktopICECandidate) = suspendCancellableCoroutine { continuation ->
        native.addRemoteCandidate(RemoteDesktopICECandidate.ADAPTER.encode(candidate).toNSData(), done(continuation, "The remote candidate could not be added."))
    }

    private fun done(continuation: CancellableContinuation<Unit>, fallback: String) = object : NativeScreenDoneCompletion {
        override fun completed(error: String?) {
            if (!continuation.isActive) return
            if (error == null) continuation.resume(Unit) else continuation.resumeWithException(IOException(error.ifEmpty { fallback }))
        }
    }

    override fun send(label: String, bytes: ByteArray) = native.send(label, bytes.toNSData())
    override fun isOpen(label: String) = native.isOpen(label)
    override fun bufferedAmount(label: String) = native.bufferedAmount(label)

    private val receiver = ReceiverStatistics()

    override suspend fun statistics(): RemoteDesktopReceiverFeedback? {
        val sample = suspendCancellableCoroutine<NativeReceiverSample?> { continuation ->
            native.statistics(object : NativeScreenSampleCompletion {
                override fun completed(sample: NativeReceiverSample?) {
                    if (continuation.isActive) continuation.resume(sample)
                }
            })
        } ?: return null
        val (feedback, _) = receiver.next(
            ReceiverSample(
                sample.atMillis, sample.framesDecoded, sample.totalDecodeTime, sample.jitterBufferEmittedCount, sample.jitterBufferDelay,
                sample.packetsLost, sample.packetsReceived, sample.presented, sample.renderMilliseconds, sample.jitterSeconds,
                sample.roundTripSeconds, RemoteDesktopRenderMeasurement.REMOTE_DESKTOP_RENDER_MEASUREMENT_METAL_PRESENTED,
            ),
            null,
        )
        return feedback.copy(decoder_implementation = sample.decoderImplementation.take(256))
    }

    override fun updateFrameGate(token: Long, displayGeneration: Long, mediaGeneration: Long, mediaTimestamp: UInt) =
        native.updateFrameGate(token, displayGeneration, mediaGeneration, mediaTimestamp.toLong())

    override fun resetVideo() = native.resetVideo()
    override fun close() = native.close()
}

private class NativeClipboardAdapter(private val native: NativeClipboard) : LocalClipboard {
    override fun stamp(): Long = native.stamp()

    override fun read(binary: Boolean): Pair<String, List<RemoteDesktopClipboardItem>>? =
        native.read(binary)?.let { ClipboardContent.ADAPTER.decode(it.toByteArray()) }?.let { it.text to it.items }

    override fun apply(text: String, items: List<RemoteDesktopClipboardItem>) =
        native.apply(ClipboardContent.ADAPTER.encode(ClipboardContent(text, items)).toNSData())
}

private class NativeAuthHttp(private val native: NativeHttp) : AuthHttp {
    override suspend fun postJson(url: String, body: String): HttpResponse = suspendCancellableCoroutine { continuation ->
        native.postJson(url, body, object : NativeHttpCompletion {
            override fun completed(status: Int, body: String) {
                if (continuation.isActive) continuation.resume(HttpResponse(status, body))
            }
        })
    }
}
