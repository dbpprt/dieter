package com.dbpprt.dieter.fixtures

import android.app.Service
import android.content.Intent
import android.os.*
import com.dbpprt.dieter.core.CoreRuntime
import com.dbpprt.dieter.core.composition.TaskDrafts
import com.dbpprt.dieter.core.composition.task
import com.dbpprt.dieter.sharedcore.SharedCore
import com.dbpprt.dieter.ui.TaskCaptureStore
import java.io.File
import kotlinx.coroutines.*

/**
 * Separate fixture process lets instrumentation kill/recreate the real draft
 * store over its own shared core; the journal lives in a private test directory.
 */
class CaptureRecoveryService : Service() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private lateinit var core: CoreRuntime
    private lateinit var store: TaskCaptureStore
    override fun onCreate() {
        super.onCreate()
        core = SharedCore.create(this, null, File(noBackupFilesDir, "capture-recovery-core")).also { it.start() }
        store = TaskCaptureStore(this, core)
    }
    private val messenger = Messenger(object : Handler(Looper.getMainLooper()) {
        override fun handleMessage(message: Message) {
            val reply = message.replyTo
            val operation = message.what
            val id = message.data.getString("id").orEmpty()
            val uri = message.data.getString("uri").orEmpty()
            scope.launch {
                while (!store.view.value.bound) delay(10)
                val result = runCatching {
                    val draft = if (operation == 1) {
                        val editor = store.begin()
                        editor.edit { TaskDrafts.prompt(it, "Persist through actual process death") }
                        store.import(editor, listOf(android.net.Uri.parse(uri)))
                        while (editor.state.value.importing) delay(10)
                        check(editor.state.value.task.attachments.size == 1) {
                            "Import failed: ${editor.state.value.failures.map { failure -> failure.message }}; ${editor.error.value}"
                        }
                        store.flush(editor)
                        editor.state.value
                    } else store.view.value.drafts.single { it.id == id }
                    Bundle().apply {
                        putString("id", draft.id); putString("prompt", draft.task.prompt)
                        putByteArray("bytes", draft.task.attachments.single().data_.toByteArray())
                        putInt("pid", Process.myPid())
                    }
                }
                val response = result.getOrElse { Bundle().apply { putString("error", it.toString()) } }
                reply.send(Message.obtain().apply { what = operation; data = response })
            }
        }
    })
    override fun onBind(intent: Intent) = messenger.binder
    override fun onDestroy() { scope.cancel(); store.close(); runBlocking { core.shutdown() }; super.onDestroy() }
}
