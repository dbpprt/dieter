package com.dbpprt.dieter.spike

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.*
import androidx.compose.ui.Modifier
import com.dbpprt.dieter.client.v1.*
import com.dbpprt.dieter.core.*
import com.dbpprt.dieter.core.client.ClientApi
import com.dbpprt.dieter.core.platform.*
import com.dbpprt.dieter.data.DieterCredentialStore
import com.dbpprt.dieter.mobile.*
import kotlinx.coroutines.*
import okio.FileSystem
import okio.Path.Companion.toOkioPath
import org.bouncycastle.jce.provider.BouncyCastleProvider
import org.bouncycastle.jsse.provider.BouncyCastleJsseProvider

class SpikeActivity : ComponentActivity() {
    private lateinit var runtime: CoreRuntime
    private lateinit var store: MobileStore

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val credentials = DieterCredentialStore(applicationContext)
        val preferences = getSharedPreferences("spike", MODE_PRIVATE)
        val crypto = BouncyCastleProvider()
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
                    stateDirectory = noBackupFilesDir.resolve("compose-core").toOkioPath(),
                ),
                RuntimeConfig(
                    BuildConfig.VERSION_NAME,
                    "dieter-compose://oauth/callback",
                    false,
                    "compose-android",
                ),
            )
        store = MobileStore(RuntimeMobileCore(ClientApi(runtime)))
        runtime.start()
        // Isolated fixture injection exists only in this separately identified Debug spike.
        if (BuildConfig.DEBUG) {
            val url = intent.getStringExtra("fixture_url")
            val token = intent.getStringExtra("fixture_token")
            if (url != null && token != null)
                store.action {
                    store.core.dispatch(
                        Command(adopt_session = AdoptSession(url, token, "Isolated Compose spike"))
                    )
                    store.agentSelection =
                        com.dbpprt.dieter.api.v1.HarnessSelection("mock", "mock", "low")
                }
        }
        intent.data?.let { store.completeSignIn(it.toString()) }
        setContent {
            Box(Modifier.fillMaxSize().safeDrawingPadding()) {
                MobileApp(
                    store,
                    openUrl = { startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(it))) },
                )
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        intent.data?.let { store.completeSignIn(it.toString()) }
    }

    override fun onStart() {
        super.onStart()
        if (::runtime.isInitialized) runtime.scope.launch { runtime.setActive(true) }
    }

    override fun onStop() {
        if (::runtime.isInitialized) runtime.scope.launch { runtime.setActive(false) }
        super.onStop()
    }

    override fun onDestroy() {
        store.close()
        CoroutineScope(Dispatchers.Default).launch { runtime.shutdown() }
        super.onDestroy()
    }
}
