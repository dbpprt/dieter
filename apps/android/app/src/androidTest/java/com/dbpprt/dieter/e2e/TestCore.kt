package com.dbpprt.dieter.e2e

import android.content.Context
import androidx.test.platform.app.InstrumentationRegistry
import com.dbpprt.dieter.core.CoreRuntime
import com.dbpprt.dieter.settings.AppPreferences
import com.dbpprt.dieter.sharedcore.ConnectionPolicy
import com.dbpprt.dieter.sharedcore.SharedCore
import com.dbpprt.dieter.ui.AppHost
import com.dbpprt.dieter.ui.DieterViewModel
import com.dbpprt.dieter.ui.TaskCaptureStore
import java.io.File
import java.util.UUID
import kotlinx.coroutines.runBlocking

/**
 * An isolated shared core for component tests: a private state directory,
 * never connected, and no background service. Folder and order edits queue
 * offline exactly as they do for a signed-in user.
 */
class TestCore(
    val context: Context = InstrumentationRegistry.getInstrumentation().targetContext,
    val directory: File = File(context.noBackupFilesDir, "test-core-${UUID.randomUUID()}"),
) : AutoCloseable {
    val core: CoreRuntime = SharedCore.create(context, null, directory)
    val preferences = AppPreferences(context)
    val policy = ConnectionPolicy(context, core) { _, _ -> }
    private val captures = lazy { TaskCaptureStore(context, core) }

    init {
        core.start()
    }

    fun viewModel(withCaptures: Boolean = false): DieterViewModel = DieterViewModel(core, preferences, policy, object : AppHost {
        override fun openUrl(url: String) = Unit
    }, if (withCaptures) captures.value else null)

    /** A second core over the same state, as after a process restart. */
    fun reopen(): TestCore = TestCore(context, directory = directory)

    override fun close() = runBlocking {
        if (captures.isInitialized()) captures.value.close()
        core.shutdown()
    }

    /** Removes the state directory; call once every core over it is closed. */
    fun delete() {
        directory.deleteRecursively()
    }
}
