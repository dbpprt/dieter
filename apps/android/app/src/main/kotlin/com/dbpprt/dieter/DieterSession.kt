package com.dbpprt.dieter

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import com.dbpprt.dieter.client.v1.*
import com.dbpprt.dieter.core.*
import com.dbpprt.dieter.core.client.ClientApi
import com.dbpprt.dieter.core.platform.*
import com.dbpprt.dieter.data.DieterCredentialStore
import com.dbpprt.dieter.mobile.*
import com.dbpprt.dieter.update.AppUpdateManager
import kotlinx.coroutines.*
import okio.FileSystem
import okio.Path.Companion.toOkioPath
import org.bouncycastle.jce.provider.BouncyCastleProvider
import org.bouncycastle.jsse.provider.BouncyCastleJsseProvider

/** Keeps the core session and shared drafts/forms alive across Activity recreation. */
class DieterSession(application: Application) : AndroidViewModel(application) {
    val runtime: CoreRuntime
    val store: MobileStore
    val screenMedia: com.dbpprt.dieter.screens.AndroidScreenMedia
    var fixtureAdopted = false
        private set

    val updates = AppUpdateManager(application)

    init {
        val applicationContext = application
        val noBackupFilesDir = application.noBackupFilesDir
        val credentials = DieterCredentialStore(applicationContext)
        val preferences =
            application.getSharedPreferences("dieter_core", android.content.Context.MODE_PRIVATE)
        val crypto = BouncyCastleProvider()
        screenMedia = com.dbpprt.dieter.screens.AndroidScreenMedia(applicationContext)
        runtime =
            CoreRuntime(
                Platform(
                    transport =
                        OkHttpRpcTransport(
                            providers = DirectTlsProviders(crypto, BouncyCastleJsseProvider(crypto))
                        ),
                    secureStore =
                        object : SecureStore {
                            override fun read(key: String) = credentials.get(key)

                            override fun write(key: String, value: String) =
                                credentials.set(key, value)

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
                    stateDirectory = noBackupFilesDir.resolve("core").toOkioPath(),
                    controlChannels =
                        com.dbpprt.dieter.sharedcore.AndroidControlChannels(applicationContext),
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
                        },
                ),
                RuntimeConfig(
                    BuildConfig.VERSION_NAME,
                    "dieter-android://oauth/callback",
                    false,
                    "android",
                ),
            )
        store =
            MobileStore(
                RuntimeMobileCore(
                    ClientApi(
                        runtime,
                        com.dbpprt.dieter.core.client.ScreenHost(
                            { screenMedia },
                            com.dbpprt.dieter.screens.AndroidClipboard(applicationContext),
                            com.dbpprt.dieter.core.screens.ScreenConfig(
                                "Compose Android",
                                com.dbpprt.dieter.core.screens.ViewportPolicy.Fixed,
                            ),
                        ),
                    )
                ),
                preferences =
                    MobilePreferences(
                        { preferences.getString(it, null) },
                        { key, value -> preferences.edit().putString(key, value).apply() },
                    ),
            )
        AndroidNativeViews.screen = { context, store ->
            ComposeScreenSurface(context, store, screenMedia)
        }
        screenMedia.onDecoderSurfaceReplaced = {
            store.command(
                Command(screen = ScreenCommand(scope = MobileStore.SCREEN_SCOPE, resume = Step()))
            )
        }
        runtime.start()
    }

    fun adoptFixture(url: String, token: String) {
        if (fixtureAdopted) return
        fixtureAdopted = true
        store.action {
            store.core.dispatch(
                Command(adopt_session = AdoptSession(url, token, "Isolated journey"))
            )
            store.agentSelection = com.dbpprt.dieter.api.v1.HarnessSelection("mock", "mock", "low")
        }
    }

    override fun onCleared() {
        CoroutineScope(Dispatchers.Main).launch {
            try {
                store.flushDrafts()
            } finally {
                store.close()
                runtime.shutdown()
                screenMedia.close()
                AndroidNativeViews.screen = null
            }
        }
        super.onCleared()
    }
}
