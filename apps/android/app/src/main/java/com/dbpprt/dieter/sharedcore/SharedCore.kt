package com.dbpprt.dieter.sharedcore

import android.content.Context
import android.util.Log
import com.dbpprt.dieter.BuildConfig
import com.dbpprt.dieter.core.CoreRuntime
import com.dbpprt.dieter.core.RuntimeConfig
import com.dbpprt.dieter.core.conversation.ConversationConfig
import com.dbpprt.dieter.core.conversation.TranscriptRetention
import com.dbpprt.dieter.core.notifications.NotificationSink
import com.dbpprt.dieter.core.platform.DeviceSettings
import com.dbpprt.dieter.core.platform.DirectTlsProviders
import com.dbpprt.dieter.core.platform.OkHttpAuthHttp
import com.dbpprt.dieter.core.platform.OkHttpRpcTransport
import com.dbpprt.dieter.core.platform.Platform
import com.dbpprt.dieter.core.platform.SecureStore
import com.dbpprt.dieter.core.platform.SignatureVerifier
import com.dbpprt.dieter.core.runtime.CoreLogger
import com.dbpprt.dieter.data.DieterCredentialStore
import okio.FileSystem
import okio.Path.Companion.toOkioPath
import org.bouncycastle.crypto.params.Ed25519PublicKeyParameters
import org.bouncycastle.crypto.signers.Ed25519Signer
import org.bouncycastle.jce.provider.BouncyCastleProvider
import org.bouncycastle.jsse.provider.BouncyCastleJsseProvider

/** The OAuth callback registered in the manifest. */
const val OAUTH_REDIRECT_URI = "dieter-android://oauth/callback"

/**
 * Builds the shared Kotlin core with Android's native extensions. All client
 * logic (sign-in, routing, sync, the outbox, conversations, features) runs in
 * the core; the app renders its state and supplies platform services.
 */
object SharedCore {
    /** Device-local core preferences, including the background-sync keys the boot receiver reads. */
    const val SETTINGS = "dieter_core"

    fun settings(context: Context): DeviceSettings {
        val preferences = context.applicationContext.getSharedPreferences(SETTINGS, Context.MODE_PRIVATE)
        return object : DeviceSettings {
            override fun string(key: String): String? = preferences.getString(key, null)
            override fun putString(key: String, value: String?) {
                preferences.edit().apply { if (value == null) remove(key) else putString(key, value) }.apply()
            }
        }
    }

    /** [stateDirectory] is overridden only by tests that need an isolated core. */
    fun create(
        context: Context,
        notifications: NotificationSink?,
        stateDirectory: java.io.File = context.applicationContext.noBackupFilesDir.resolve("core"),
    ): CoreRuntime {
        val appContext = context.applicationContext
        val credentials = DieterCredentialStore(appContext)
        // Android's platform TLS provider does not negotiate Ed25519 daemon certificates.
        val crypto = BouncyCastleProvider()
        return CoreRuntime(
            Platform(
                transport = OkHttpRpcTransport(providers = DirectTlsProviders(crypto, BouncyCastleJsseProvider(crypto))),
                secureStore = object : SecureStore {
                    override fun read(key: String) = credentials.get(key)
                    override fun write(key: String, value: String) = credentials.set(key, value)
                    override fun delete(key: String) = credentials.set(key, null)
                },
                settings = settings(appContext),
                http = OkHttpAuthHttp(),
                fileSystem = FileSystem.SYSTEM,
                stateDirectory = stateDirectory.toOkioPath(),
                controlChannels = AndroidControlChannels(appContext),
                signatures = BouncyCastleSignatures,
                notifications = notifications,
                logger = AndroidLogger,
            ),
            RuntimeConfig(
                clientVersion = BuildConfig.VERSION_NAME,
                oauthRedirectUri = OAUTH_REDIRECT_URI,
                includeLoopbackRoutes = false,
                clientIdPrefix = "android",
                conversations = ConversationConfig(retention = TranscriptRetention.MOBILE),
            ),
        )
    }
}

/** Screen-session bindings are signed by the daemon's enrolled Ed25519 key. */
private object BouncyCastleSignatures : SignatureVerifier {
    override fun verifyEd25519(publicKey: ByteArray, message: ByteArray, signature: ByteArray): Boolean = runCatching {
        Ed25519Signer().run {
            init(false, Ed25519PublicKeyParameters(publicKey, 0))
            update(message, 0, message.size)
            verifySignature(signature)
        }
    }.getOrDefault(false)
}

private object AndroidLogger : CoreLogger {
    override fun debug(tag: String, message: String) {
        if (BuildConfig.DEBUG) Log.d("Core/$tag", message)
    }

    override fun info(tag: String, message: String) {
        Log.i("Core/$tag", message)
    }

    override fun warn(tag: String, message: String, error: Throwable?) {
        Log.w("Core/$tag", message, error)
    }
}
