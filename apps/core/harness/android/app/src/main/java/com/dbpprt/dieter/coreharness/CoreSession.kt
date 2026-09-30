package com.dbpprt.dieter.coreharness

import android.content.Context
import com.dbpprt.dieter.core.CoreRuntime
import com.dbpprt.dieter.core.RuntimeConfig
import com.dbpprt.dieter.core.conversation.ConversationConfig
import com.dbpprt.dieter.core.conversation.TranscriptRetention
import com.dbpprt.dieter.core.platform.DeviceSettings
import com.dbpprt.dieter.core.platform.OkHttpAuthHttp
import com.dbpprt.dieter.core.platform.OkHttpRpcTransport
import com.dbpprt.dieter.core.platform.Platform
import com.dbpprt.dieter.core.platform.SecureStore
import okio.FileSystem
import okio.Path.Companion.toOkioPath

/**
 * What DieterConnectionManager shrinks to: platform wiring around the shared
 * core. ViewModels collect the runtime's StateFlows exactly as today. The
 * app passes its AndroidKeyStore-backed store instead of [secureStore].
 */
class CoreSession(context: Context, clientVersion: String, secureStore: SecureStore) {
    private val preferences = context.getSharedPreferences("dieter_core", Context.MODE_PRIVATE)

    val runtime = CoreRuntime(
        Platform(
            transport = OkHttpRpcTransport(),
            secureStore = secureStore,
            settings = object : DeviceSettings {
                override fun string(key: String): String? = preferences.getString(key, null)
                override fun putString(key: String, value: String?) = preferences.edit().putString(key, value).apply()
            },
            http = OkHttpAuthHttp(),
            fileSystem = FileSystem.SYSTEM,
            stateDirectory = context.noBackupFilesDir.resolve("core").toOkioPath(),
        ),
        RuntimeConfig(
            clientVersion = clientVersion,
            oauthRedirectUri = "dieter-android://oauth/callback",
            includeLoopbackRoutes = false,
            clientIdPrefix = "android",
            conversations = ConversationConfig(retention = TranscriptRetention.MOBILE),
        ),
    )
}
