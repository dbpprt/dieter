package com.dbpprt.dieter.ui

import android.content.ClipData
import android.content.Intent
import android.net.Uri
import androidx.test.platform.app.InstrumentationRegistry
import com.dbpprt.dieter.core.composition.Attachments
import com.dbpprt.dieter.core.composition.TaskDrafts
import com.dbpprt.dieter.core.composition.ready
import com.dbpprt.dieter.core.composition.task
import com.dbpprt.dieter.e2e.TestCore
import kotlinx.coroutines.*
import org.junit.After
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.util.UUID

/**
 * The Android intake (share intents, content URIs, process death) over an isolated shared core whose
 * journal lives in a private test directory. The capture rules and the journal are the core's tests.
 */
class TaskCaptureStoreTest {
    private val cores = mutableListOf<TestCore>()
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val root by lazy { File(context.noBackupFilesDir, "capture-store-test-${UUID.randomUUID()}") }
    private val context get() = instrumentation.targetContext
    private fun uri(name: String, bytes: ByteArray? = null): Uri {
        bytes?.let { File(context.filesDir, "capture-fixture/$name").apply { parentFile!!.mkdirs(); writeBytes(it) } }
        return Uri.parse("content://${context.packageName}.capture-fixture/$name")
    }
    private fun <T> onMain(block: () -> T): T = runBlocking { withContext(Dispatchers.Main) { block() } }
    private fun await(condition: () -> Boolean) = runBlocking { withTimeout(10_000) { while (!onMain(condition)) delay(25) } }
    private fun store(): TaskCaptureStore = onMain { TaskCaptureStore(context, TestCore(context, directory = root).also { cores += it }.core) }.also { await { it.view.value.bound } }
    private fun drafts(store: TaskCaptureStore) = store.view.value.drafts
    private fun <T> suspending(block: suspend () -> T): T = runBlocking { block() }

    @After fun tearDown() {
        cores.forEach { it.close() }
        root.deleteRecursively()
    }

    @Test fun sharedContentSurvivesNewStoreAndExpiredSource() {
        val store = store()
        val name = "${UUID.randomUUID()}.txt"
        val source = uri(name, "persisted attachment".toByteArray())
        val intent = Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_STREAM, source)
            .putExtra(Intent.EXTRA_TEXT, "  Preserve exactly\nsecond line ")
        onMain { store.receive(intent) }
        await { store.incoming?.state?.value?.let { it.task.attachments.size == 1 && !it.importing } == true }
        val editor = onMain { store.incoming!! }
        suspending { store.flush(editor) }
        onMain { store.close() }
        File(context.filesDir, "capture-fixture/$name").delete()
        cores.removeLast().close()
        val restored = store()
        await { drafts(restored).any { it.id == editor.id } }
        val copy = drafts(restored).single { it.id == editor.id }
        assertEquals("  Preserve exactly\nsecond line ", copy.task.prompt)
        assertEquals("persisted attachment", copy.task.attachments.single().data_.utf8())
        // The same share delivered again (e.g. after recreation) is not imported twice.
        onMain { restored.receive(intent) }
        await { restored.incoming != null }
        assertEquals(1, restored.incoming!!.state.value.task.attachments.size)
        onMain { restored.discard(copy.id); restored.close() }
    }

    @Test fun mixedImportsReportFailuresAndRetryWithoutLosingGoodFiles() {
        val store = store()
        val editor = suspending { store.begin() }
        val good = uri("good.txt", "good".toByteArray())
        val missing = uri("missing.txt")
        val denied = uri("denied.txt")
        onMain { store.import(editor, listOf(good, good, missing, denied)) }
        await { !editor.state.value.importing }
        assertEquals(1, editor.state.value.task.attachments.size)
        assertEquals(2, editor.state.value.failures.size)
        assertFalse(editor.state.value.ready)
        uri("missing.txt", "now available".toByteArray())
        onMain { store.retry(editor, editor.state.value.failures.first { it.source == missing.toString() }) }
        await { !editor.state.value.importing }
        assertEquals(2, editor.state.value.task.attachments.size)
        editor.edit { draft -> draft.failures.fold(draft) { next, failure -> TaskDrafts.removeFailure(next, failure) } }
        assertTrue(editor.state.value.ready)
        onMain { store.discard(editor.id); store.close() }
    }

    @Test fun actualByteLimitsApplyWithoutDeclaredSize() {
        val source = uri("large.txt", ByteArray(Attachments.MAX_FILE_BYTES.toInt() + 1) { 1 }).buildUpon().appendQueryParameter("unknown", "true").build()
        val failure = runCatching { readAttachmentPart(context, source, false) }.exceptionOrNull()
        assertTrue(failure?.message.orEmpty().contains("5 MB"))
        val exact = uri("exact.txt", ByteArray(Attachments.MAX_FILE_BYTES.toInt()) { 1 })
        assertEquals(Attachments.MAX_FILE_BYTES.toInt(), readAttachmentPart(context, exact, false).data_.size)
        assertNotNull(runCatching { readAttachmentPart(context, uri("empty.txt", byteArrayOf()), false) }.exceptionOrNull())
        assertNotNull(runCatching { readAttachmentPart(context, Uri.parse("file:///etc/passwd"), false) }.exceptionOrNull())
    }

    @Test fun actualProcessDeathPreservesCopiedAttachments() {
        val source = uri("process.txt", "process-safe bytes".toByteArray())
        fun exchange(operation: Int, id: String = ""): android.os.Bundle {
            val connected = java.util.concurrent.ArrayBlockingQueue<android.os.IBinder>(1)
            val replies = java.util.concurrent.ArrayBlockingQueue<android.os.Bundle>(1)
            val connection = object : android.content.ServiceConnection {
                override fun onServiceConnected(name: android.content.ComponentName, binder: android.os.IBinder) { connected.offer(binder) }
                override fun onServiceDisconnected(name: android.content.ComponentName) = Unit
            }
            val intent = Intent().setClassName(context.packageName, "com.dbpprt.dieter.fixtures.CaptureRecoveryService")
            assertTrue(context.bindService(intent, connection, android.content.Context.BIND_AUTO_CREATE))
            try {
                val binder = requireNotNull(connected.poll(15, java.util.concurrent.TimeUnit.SECONDS))
                val reply = android.os.Messenger(object : android.os.Handler(android.os.Looper.getMainLooper()) {
                    override fun handleMessage(message: android.os.Message) { replies.offer(message.data) }
                })
                android.os.Messenger(binder).send(android.os.Message.obtain().apply {
                    what = operation; replyTo = reply
                    data = android.os.Bundle().apply { putString("id", id); putString("uri", source.toString()) }
                })
                val result = requireNotNull(replies.poll(15, java.util.concurrent.TimeUnit.SECONDS))
                assertNull(result.getString("error"))
                if (operation == 1) {
                    val died = java.util.concurrent.CountDownLatch(1)
                    binder.linkToDeath({ died.countDown() }, 0)
                    android.os.Process.killProcess(result.getInt("pid"))
                    assertTrue(died.await(10, java.util.concurrent.TimeUnit.SECONDS))
                }
                return result
            } finally { context.unbindService(connection) }
        }
        val before = exchange(1)
        File(context.filesDir, "capture-fixture/process.txt").delete()
        val after = exchange(2, before.getString("id")!!)
        assertNotEquals(before.getInt("pid"), after.getInt("pid"))
        assertEquals(before.getString("prompt"), after.getString("prompt"))
        assertArrayEquals(before.getByteArray("bytes"), after.getByteArray("bytes"))
    }

    @Test fun streamAndClipDataDeduplicateAndCountIsBounded() {
        val first = uri("one.txt")
        val second = uri("two.txt")
        val intent = Intent(Intent.ACTION_SEND_MULTIPLE).putParcelableArrayListExtra(Intent.EXTRA_STREAM, arrayListOf(first, second))
        intent.clipData = ClipData.newUri(context.contentResolver, "one", first)
        assertEquals(listOf(first, second), sharedUris(intent))
        repeat(20) { intent.clipData!!.addItem(ClipData.Item(uri("file$it.txt"))) }
        assertEquals(Attachments.MAX_COUNT + 1, sharedUris(intent).size)
    }
}
