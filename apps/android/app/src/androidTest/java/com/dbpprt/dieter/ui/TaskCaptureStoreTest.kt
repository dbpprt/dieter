package com.dbpprt.dieter.ui

import android.content.ClipData
import android.content.Intent
import android.net.Uri
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.util.UUID

class TaskCaptureStoreTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val root by lazy { File(context.noBackupFilesDir, "capture-store-test-${UUID.randomUUID()}") }
    private val context get() = instrumentation.targetContext
    private fun uri(name: String, bytes: ByteArray? = null): Uri {
        bytes?.let { File(context.filesDir, "capture-fixture/$name").apply { parentFile!!.mkdirs(); writeBytes(it) } }
        return Uri.parse("content://${context.packageName}.capture-fixture/$name")
    }
    private fun <T> onMain(block: () -> T): T = runBlocking { withContext(Dispatchers.Main) { block() } }
    private fun await(condition: () -> Boolean) = runBlocking { withTimeout(10_000) { while (!onMain(condition)) delay(25) } }
    private fun store(): TaskCaptureStore = onMain { TaskCaptureStore(context, root) }.also { await { it.loaded } }

    @Test fun sharedContentSurvivesNewStoreAndExpiredSource() {
        val store = store()
        val name = "${UUID.randomUUID()}.txt"
        val source = uri(name, "persisted attachment".toByteArray())
        val intent = Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_STREAM, source)
            .putExtra(Intent.EXTRA_TEXT, "  Preserve exactly\nsecond line ")
        onMain { store.receive(intent, "account-test") }
        await { store.incoming?.attachments?.size == 1 && store.incoming?.importing == false }
        val draft = onMain { store.incoming!! }
        runBlocking { withContext(Dispatchers.Main) { store.flush(draft) } }
        onMain { store.close() }
        File(context.filesDir, "capture-fixture/$name").delete()
        val restored = store()
        val copy = onMain { restored.drafts.single { it.id == draft.id } }
        assertEquals("  Preserve exactly\nsecond line ", copy.prompt)
        assertEquals("persisted attachment", copy.attachments.single().data.toStringUtf8())
        assertEquals("account-test", copy.accountId)
        onMain { restored.receive(intent, "account-test") }
        await { restored.incoming != null }
        assertEquals(1, copy.attachments.size)
        onMain { restored.discard(copy); restored.close() }
    }

    @Test fun mixedImportsReportFailuresAndRetryWithoutLosingGoodFiles() {
        val store = store()
        val draft = onMain { store.create("import-test") }
        val good = uri("good.txt", "good".toByteArray())
        val missing = uri("missing.txt")
        val denied = uri("denied.txt")
        onMain { store.import(draft, listOf(good, good, missing, denied)) }
        await { !draft.importing }
        assertEquals(1, draft.attachments.size)
        assertEquals(2, draft.importFailures.size)
        assertFalse(draft.ready)
        uri("missing.txt", "now available".toByteArray())
        onMain { store.retry(draft, draft.importFailures.first { it.uri == missing.toString() }) }
        await { !draft.importing }
        assertEquals(2, draft.attachments.size)
        onMain { draft.importFailures.clear() }
        assertTrue(draft.ready)
        onMain { store.discard(draft); store.close() }
    }

    @Test fun actualByteLimitsApplyWithoutDeclaredSize() {
        val source = uri("large.txt", ByteArray(MAX_COMPOSER_ATTACHMENT_BYTES + 1) { 1 }).buildUpon().appendQueryParameter("unknown", "true").build()
        val failure = runCatching { readAttachmentPart(context, source, false) }.exceptionOrNull()
        assertTrue(failure?.message.orEmpty().contains("5 MB"))
        val exact = uri("exact.txt", ByteArray(MAX_COMPOSER_ATTACHMENT_BYTES) { 1 })
        assertEquals(MAX_COMPOSER_ATTACHMENT_BYTES, readAttachmentPart(context, exact, false).data.size())
        assertNotNull(runCatching { readAttachmentPart(context, uri("empty.txt", byteArrayOf()), false) }.exceptionOrNull())
        assertNotNull(runCatching { readAttachmentPart(context, Uri.parse("file:///etc/passwd"), false) }.exceptionOrNull())
    }

    @Test fun capacityAndStorageFailureKeepExistingDrafts() {
        val store = store()
        repeat(20) { onMain { store.create("bounded").prompt = "Keep draft $it" } }
        assertNotNull(runCatching { onMain { store.create("bounded") } }.exceptionOrNull())
        assertEquals(20, store.drafts.size)
        onMain { store.close() }
        val blockedRoot = File(context.noBackupFilesDir, "blocked-${UUID.randomUUID()}").apply { writeText("not a directory") }
        val blocked = onMain { TaskCaptureStore(context, blockedRoot) }
        await { blocked.loaded }
        val draft = onMain { blocked.create("disk-failure") }
        await { draft.persistenceError != null }
        assertFalse(draft.ready)
        onMain { blocked.close() }
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
        assertEquals(MAX_COMPOSER_ATTACHMENTS + 1, sharedUris(intent).size)
    }

    @Test fun submissionSnapshotAndInterruptedImportRestoreAtomically() {
        val store = store()
        val draft = onMain { store.create("submission-test") }
        onMain {
            draft.prompt = "original"
            draft.submissionId = "stable-command"
            draft.submittedRequest = draft.snapshot()
            draft.prompt = "late edit"
            draft.importing = true
        }
        runBlocking { withContext(Dispatchers.Main) { store.flush(draft) } }
        onMain { store.close() }
        val restored = store()
        val copy = onMain { restored.drafts.single { it.id == draft.id } }
        assertEquals("stable-command", copy.submissionId)
        assertEquals("original", copy.prompt)
        assertEquals("original", copy.submittedRequest!!.prompt)
        assertTrue(copy.importFailures.single().message.contains("interrupted"))
        onMain { restored.discard(copy); restored.close() }
    }
}
