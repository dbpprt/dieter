package com.dbpprt.dieter.shared

import com.dbpprt.dieter.client.v1.Command
import com.dbpprt.dieter.client.v1.Failure
import com.dbpprt.dieter.client.v1.Reply
import com.dbpprt.dieter.client.v1.Slice
import com.dbpprt.dieter.core.CoreRuntime
import com.dbpprt.dieter.core.RuntimeConfig
import com.dbpprt.dieter.core.client.ClientApi
import com.dbpprt.dieter.core.client.ClientFailure
import com.dbpprt.dieter.core.client.ClientSubscription
import com.dbpprt.dieter.core.conversation.ConversationConfig
import com.dbpprt.dieter.core.conversation.TranscriptRetention
import com.dbpprt.dieter.core.legacy.AppleLegacyInput
import com.dbpprt.dieter.core.legacy.LegacyInputs
import com.dbpprt.dieter.core.notifications.NotificationContent
import com.dbpprt.dieter.core.notifications.NotificationSink
import com.dbpprt.dieter.core.platform.AuthHttp
import com.dbpprt.dieter.core.platform.DeviceSettings
import com.dbpprt.dieter.core.platform.HttpResponse
import com.dbpprt.dieter.core.platform.Platform
import com.dbpprt.dieter.core.platform.SecureStore
import com.dbpprt.dieter.core.platform.SignatureVerifier
import com.dbpprt.dieter.core.runtime.CoreLogger
import kotlin.coroutines.cancellation.CancellationException
import kotlin.coroutines.resume
import kotlinx.coroutines.suspendCancellableCoroutine
import okio.FileSystem
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

/** UserNotifications. [role] is the core's NotificationRole name. */
interface NativeNotifications {
    fun post(key: String, role: String, title: String, text: String, expanded: String?): Boolean
    fun cancel(key: String)
}

/** Receives encoded `dieter.client.v1.Update`s on a core thread; hop to the main actor. */
interface SharedObserver {
    fun update(bytes: NSData)
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
    /** The install's existing client ID from the legacy app, kept for idempotency. */
    val legacyClientId: String?,
    /** Only macOS can run a daemon itself, so only it tries loopback routes. */
    val includeLoopbackRoutes: Boolean,
    /** Phones keep a smaller transcript window than desktops. */
    val compactTranscripts: Boolean,
)

class SharedExtensions(
    val rpc: NativeRpcBridge,
    val secureStore: NativeSecureStore,
    val settings: NativeSettings,
    val http: NativeHttp,
    val signatures: NativeSignatures?,
    val logger: NativeLogger?,
    val notifications: NativeNotifications?,
)

/**
 * The Apple entry point to the shared core. Swift dispatches encoded
 * `dieter.client.v1.Command`s and observes encoded slices; SwiftProtobuf
 * types stay the Apple UI model. Only this module's API is exported.
 */
class DieterShared(configuration: SharedConfiguration, extensions: SharedExtensions) {
    private val runtime = CoreRuntime(
        Platform(
            transport = NativeRpcTransport(extensions.rpc),
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
                    override fun post(content: NotificationContent) = native.post(content.key, content.role.name, content.title, content.text, content.expanded)
                    override fun cancel(key: String) = native.cancel(key)
                }
            },
            logger = extensions.logger?.let { native ->
                object : CoreLogger {
                    override fun debug(tag: String, message: String) = native.log(0, tag, message)
                    override fun info(tag: String, message: String) = native.log(1, tag, message)
                    override fun warn(tag: String, message: String, error: Throwable?) =
                        native.log(2, tag, if (error == null) message else "$message: ${error.message}")
                }
            } ?: com.dbpprt.dieter.core.runtime.SilentLogger,
        ),
        RuntimeConfig(
            clientVersion = configuration.clientVersion,
            oauthRedirectUri = configuration.oauthRedirectUri,
            includeLoopbackRoutes = configuration.includeLoopbackRoutes,
            clientIdPrefix = configuration.clientIdPrefix,
            legacyClientId = { configuration.legacyClientId },
            conversations = ConversationConfig(retention = if (configuration.compactTranscripts) TranscriptRetention.MOBILE else TranscriptRetention.DESKTOP),
        ),
    )
    private val api = ClientApi(runtime)

    val clientId: String get() = runtime.clientId

    /** Whether the legacy app's state still has to be imported; do it before [start]. */
    val needsLegacyImport: Boolean get() = runtime.needsLegacyImport

    /** Moves the legacy app's state into the core once; returns a summary for the log. */
    @Throws(Exception::class)
    suspend fun importLegacy(input: AppleLegacyInput): String = runtime.importLegacy(LegacyInputs.apple(input)).toString()

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

    /** Observes [slice] (a `dieter.client.v1.Slice` number); [scope] is the card ID for conversations. */
    fun observe(slice: Int, scope: String, observer: SharedObserver): SharedSubscription {
        val kind = Slice.fromValue(slice) ?: Slice.SLICE_UNSPECIFIED
        return SharedSubscription(api.observe(kind, scope) { update -> observer.update(update.encode().toNSData()) })
    }

    @Throws(CancellationException::class)
    suspend fun shutdown() = runtime.shutdown()
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
