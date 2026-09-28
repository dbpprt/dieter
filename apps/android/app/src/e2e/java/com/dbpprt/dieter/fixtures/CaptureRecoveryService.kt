package com.dbpprt.dieter.fixtures

import android.app.Service
import android.content.Intent
import android.os.*
import com.dbpprt.dieter.ui.TaskCaptureStore
import kotlinx.coroutines.*

/** Separate fixture process lets instrumentation kill/recreate the real draft store. */
class CaptureRecoveryService : Service() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private lateinit var store: TaskCaptureStore
    override fun onCreate() { super.onCreate(); store = TaskCaptureStore(this) }
    private val messenger = Messenger(object : Handler(Looper.getMainLooper()) {
        override fun handleMessage(message: Message) {
            val reply = message.replyTo
            val operation = message.what
            val id = message.data.getString("id").orEmpty()
            val uri = message.data.getString("uri").orEmpty()
            scope.launch {
                while (!store.loaded) delay(10)
                val result = runCatching {
                    val draft = if (operation == 1) store.create("process-recovery").also {
                        it.prompt = "Persist through actual process death"
                        store.import(it, listOf(android.net.Uri.parse(uri)))
                        while (it.importing) delay(10)
                        check(it.attachments.size == 1) { "Import failed: ${it.importFailures.map { failure -> failure.message }}; ${it.persistenceError}" }
                        store.flush(it)
                    } else store.drafts.single { it.id == id }
                    Bundle().apply {
                        putString("id", draft.id); putString("prompt", draft.prompt)
                        putByteArray("bytes", draft.attachments.single().data.toByteArray())
                        putInt("pid", Process.myPid())
                    }
                }
                val response = result.getOrElse { Bundle().apply { putString("error", it.toString()) } }
                reply.send(Message.obtain().apply { what = operation; data = response })
            }
        }
    })
    override fun onBind(intent: Intent) = messenger.binder
    override fun onDestroy() { scope.cancel(); store.close(); super.onDestroy() }
}
