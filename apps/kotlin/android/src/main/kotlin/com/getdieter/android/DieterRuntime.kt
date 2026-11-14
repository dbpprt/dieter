package com.getdieter.android

import android.content.Context
import com.getdieter.android.data.AndroidDeviceKeys
import com.getdieter.android.data.DieterCredentialStore
import com.getdieter.android.data.KeyStoreTls
import com.getdieter.android.folders.AndroidDeviceConditions
import com.getdieter.android.folders.AndroidFolderFileSystem
import com.getdieter.android.folders.AndroidFolderScheduler
import com.getdieter.android.folders.AndroidFolderSources
import com.getdieter.android.folders.FolderNotifier
import com.getdieter.android.notifications.AndroidNotifications
import com.getdieter.core.*
import com.getdieter.core.folders.FolderPlatform
import com.getdieter.core.identity.DistributionIdentity
import com.getdieter.core.platform.*
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import okio.FileSystem
import okio.Path.Companion.toOkioPath
import org.bouncycastle.jce.provider.BouncyCastleProvider

/**
 * The process's one core runtime, shared by the activity's session and the background folder
 * windows (WorkManager workers and the user-initiated transfer job), which can run without an
 * activity. Each holder acquires it and releases it; the last release shuts it down, persisting
 * every machine's view, and the next acquire starts a fresh one once that shutdown finished.
 */
object DieterRuntime {
    private class Running(
        val runtime: CoreRuntime,
        val scope: CoroutineScope,
        val notifications: AndroidNotifications,
    )

    private val lock = Any()
    private var running: Running? = null
    private var holders = 0
    private var stopping: Job? = null

    fun acquire(context: Context): CoreRuntime =
        synchronized(lock) {
            holders++
            running?.let {
                return it.runtime
            }
            // The previous runtime still persists its views: never let two share the state.
            stopping?.let { previous -> runBlocking { previous.join() } }
            stopping = null
            val application = context.applicationContext
            val notifications = AndroidNotifications(application)
            val runtime = create(application, notifications)
            val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
            running = Running(runtime, scope, notifications)
            notifications.refreshRegistration = runtime::refreshPushRegistration
            notifications.refreshToken()
            runtime.start()
            FolderNotifier(application, runtime).start(scope)
            runtime
        }

    /** Notification delivery lives as long as the shared runtime, including folder windows. */
    fun notifications(runtime: CoreRuntime): AndroidNotifications =
        synchronized(lock) {
            val active = checkNotNull(running)
            check(active.runtime === runtime)
            active.notifications
        }

    fun release() {
        synchronized(lock) {
            if (holders == 0) return
            holders--
            if (holders > 0) return
            val last = running ?: return
            running = null
            last.notifications.close()
            last.scope.cancel()
            stopping = CoroutineScope(Dispatchers.Default).launch { last.runtime.shutdown() }
        }
    }

    private fun create(application: Context, notifications: AndroidNotifications): CoreRuntime {
        val credentials = DieterCredentialStore(application)
        val preferences =
            application.getSharedPreferences("dieter_core", android.content.Context.MODE_PRIVATE)
        val deviceKeys = AndroidDeviceKeys()
        val transport =
            OkHttpRpcTransport(
                identity = deviceKeys,
                providers = KeyStoreTls.providers(BouncyCastleProvider()),
            )
        return CoreRuntime(
            Platform(
                transport = transport,
                attentionNotifications = notifications,
                tunnels = GrpcTunnelFactory(transport),
                deviceKeys = deviceKeys,
                secureStore =
                    object : SecureStore {
                        override fun read(key: String) = credentials.get(key)

                        override fun write(key: String, value: String) = credentials.set(key, value)

                        override fun delete(key: String) = credentials.set(key, null)
                    },
                settings =
                    object : DeviceSettings {
                        override fun string(key: String) = preferences.getString(key, null)

                        override fun putString(key: String, value: String?) {
                            preferences.edit().putString(key, value).apply()
                        }
                    },
                http = OkHttpAuthHttp(),
                fileSystem = FileSystem.SYSTEM,
                stateDirectory = application.noBackupFilesDir.resolve("core").toOkioPath(),
                controlChannels =
                    com.getdieter.android.sharedcore.AndroidControlChannels(application),
                signatures =
                    object : SignatureVerifier {
                        override fun verifyEd25519(
                            publicKey: ByteArray,
                            message: ByteArray,
                            signature: ByteArray,
                        ): Boolean = runCatching {
                            val verifier = org.bouncycastle.crypto.signers.Ed25519Signer()
                            verifier.init(
                                false,
                                org.bouncycastle.crypto.params.Ed25519PublicKeyParameters(
                                    publicKey,
                                    0,
                                ),
                            )
                            verifier.update(message, 0, message.size)
                            verifier.verifySignature(signature)
                        }
                            .getOrDefault(false)

                        override fun verifyEcdsaP256(
                            publicKey: ByteArray,
                            message: ByteArray,
                            signature: ByteArray,
                        ): Boolean = JcaEcdsa.verify(publicKey, message, signature)
                    },
                // Synced folders: nothing is scheduled or runs until a folder is on this device.
                folders =
                    FolderPlatform(
                        AndroidFolderFileSystem(application),
                        AndroidDeviceConditions(application),
                        AndroidFolderScheduler(application),
                        "android",
                        AndroidFolderSources(application),
                    ),
            ),
            RuntimeConfig(
                BuildConfig.VERSION_NAME,
                "${DistributionIdentity.ANDROID_URL_SCHEME}://oauth/callback",
                false,
                "android",
            ),
        )
    }
}
