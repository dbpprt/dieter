package com.dbpprt.dieter.e2e

import android.content.Context
import androidx.test.platform.app.InstrumentationRegistry
import com.dbpprt.dieter.core.CoreRuntime
import com.dbpprt.dieter.core.navigation.KvActive
import com.dbpprt.dieter.settings.AppPreferences
import com.dbpprt.dieter.sharedcore.ConnectionPolicy
import com.dbpprt.dieter.sharedcore.SharedCore
import com.dbpprt.dieter.ui.AppHost
import com.dbpprt.dieter.ui.DieterViewModel
import java.io.File
import java.util.UUID
import kotlinx.coroutines.runBlocking

/**
 * An isolated shared core for component tests: a private state directory,
 * never connected, and no background service. With [navigationAccount] the
 * shared navigation namespace is bound to that account, so folder and order
 * edits queue offline exactly as they do for a signed-in user.
 */
class TestCore(
    val context: Context = InstrumentationRegistry.getInstrumentation().targetContext,
    navigationAccount: String? = null,
    val directory: File = File(context.noBackupFilesDir, "test-core-${UUID.randomUUID()}"),
) : AutoCloseable {
    val core: CoreRuntime = SharedCore.create(context, null, directory)
    val preferences = AppPreferences(context)
    val policy = ConnectionPolicy(context, core) { _, _ -> }
    val openedUrls = mutableListOf<String>()

    init {
        navigationAccount?.let { account ->
            core.storageFor(core.accounts.state.value.active).scope("navigation")
                .write("kv-active-navigation.pb", KvActive.ADAPTER.encode(KvActive(account = account)))
        }
        core.start()
    }

    fun viewModel(): DieterViewModel = DieterViewModel(core, preferences, policy, object : AppHost {
        override fun openUrl(url: String) {
            openedUrls += url
        }
    }, null)

    /** A second core over the same state, as after a process restart. */
    fun reopen(): TestCore = TestCore(context, directory = directory)

    override fun close() = runBlocking { core.shutdown() }

    /** Removes the state directory; call once every core over it is closed. */
    fun delete() {
        directory.deleteRecursively()
    }
}
