package com.getdieter.android

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import com.getdieter.android.update.AppUpdateManager
import com.getdieter.client.v1.*
import com.getdieter.core.*
import com.getdieter.core.client.ClientApi
import com.getdieter.mobile.platform.*
import com.getdieter.mobile.store.*
import kotlinx.coroutines.*

/** Keeps the core session and shared drafts/forms alive across Activity recreation. */
class DieterSession(application: Application) : AndroidViewModel(application) {
    val runtime: CoreRuntime
    val store: MobileStore
    val screenMedia: com.getdieter.android.screens.AndroidScreenMedia
    var fixtureAdopted = false
        private set

    val updates = AppUpdateManager(application)

    init {
        val applicationContext = application
        val preferences =
            application.getSharedPreferences("dieter_core", android.content.Context.MODE_PRIVATE)
        screenMedia = com.getdieter.android.screens.AndroidScreenMedia(applicationContext)
        // Shared with background folder windows, which can run without this session.
        runtime = DieterRuntime.acquire(applicationContext)
        store =
            MobileStore(
                RuntimeMobileCore(
                    ClientApi(
                        runtime,
                        com.getdieter.core.client.ScreenHost(
                            { screenMedia },
                            com.getdieter.android.screens.AndroidClipboard(applicationContext),
                            com.getdieter.core.screens.ScreenConfig(
                                "Compose Android",
                                com.getdieter.core.screens.ViewportPolicy.Fixed,
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
        com.getdieter.android.folders.FolderNotifications.channels(applicationContext)
    }

    /** Maestro flows: the isolated fixture's session and the code its machine approves. */
    fun adoptFixture(url: String, token: String, pairingCode: String) {
        if (fixtureAdopted) return
        fixtureAdopted = true
        store.action {
            store.core.dispatch(
                Command(
                    adopt_session =
                        AdoptSession(url, token, "Isolated journey", pairing_code = pairingCode)
                )
            )
            store.creation.agentSelection =
                com.getdieter.api.v1.HarnessSelection("mock", "mock", "low")
        }
    }

    override fun onCleared() {
        CoroutineScope(Dispatchers.Main).launch {
            try {
                store.conversation.flushDrafts()
            } finally {
                store.close()
                DieterRuntime.release()
                screenMedia.close()
                AndroidNativeViews.screen = null
            }
        }
        super.onCleared()
    }
}
