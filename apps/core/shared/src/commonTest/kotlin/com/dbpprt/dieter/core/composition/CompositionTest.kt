package com.dbpprt.dieter.core.composition

import com.dbpprt.dieter.api.v1.Board
import com.dbpprt.dieter.api.v1.Checkout
import com.dbpprt.dieter.api.v1.CreateConversationRequest
import com.dbpprt.dieter.api.v1.EffortConfig
import com.dbpprt.dieter.api.v1.EffortOption
import com.dbpprt.dieter.api.v1.Harness
import com.dbpprt.dieter.api.v1.HarnessCapability
import com.dbpprt.dieter.api.v1.HarnessModel
import com.dbpprt.dieter.api.v1.HarnessSelection
import com.dbpprt.dieter.api.v1.Label
import com.dbpprt.dieter.api.v1.Lane
import com.dbpprt.dieter.api.v1.MessagePart
import com.dbpprt.dieter.api.v1.Project
import com.dbpprt.dieter.api.v1.ProviderOption
import com.dbpprt.dieter.api.v1.ProviderOptionChoice
import com.dbpprt.dieter.api.v1.QueuedMessage
import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.core.runtime.CoreException
import com.dbpprt.dieter.core.runtime.SilentLogger
import com.dbpprt.dieter.core.selection.Selections
import com.dbpprt.dieter.core.storage.CoreStorage
import com.dbpprt.dieter.core.testing.ManualClock
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import okio.ByteString
import okio.ByteString.Companion.toByteString
import okio.FileSystem
import okio.ForwardingFileSystem
import okio.Path
import okio.Path.Companion.toPath
import okio.fakefilesystem.FakeFileSystem

/** Counts file writes; [CoreStorage] completes each with an atomic move. */
private class CountingFileSystem(delegate: FileSystem) : ForwardingFileSystem(delegate) {
    var writes = 0

    override fun atomicMove(source: Path, target: Path) {
        writes++
        super.atomicMove(source, target)
    }
}

class CompositionTest {
    private val fileSystem = FakeFileSystem()
    private val clock = ManualClock()
    private fun storage(name: String) = CoreStorage(fileSystem, "/state/$name".toPath())
    private fun bytes(count: Int): ByteString = ByteArray(count).toByteString()
    private val key = DraftKey("d1", "card-1")

    @Test
    fun draftsClearOnlyTheSentRevision() {
        val drafts = ConversationDrafts(clock, SilentLogger).also { it.bind(storage("g")) }
        val sent = drafts.setText(key, "alpha")
        drafts.setText(key, "alpha and more")
        assertFalse(drafts.acceptSend(key, sent.revision), "a stale acceptance keeps new typing")
        assertEquals("alpha and more", drafts.draft(key).text)
        assertTrue(drafts.acceptSend(key, drafts.draft(key).revision))
        assertEquals("", drafts.draft(key).text)
        drafts.setText(DraftKey("d1", "other"), "beta")
        assertEquals("beta", drafts.draft(DraftKey("d1", "other")).text)
    }

    @Test
    fun editingAQueuedMessageRestoresItsContentAndSelection() {
        val drafts = ConversationDrafts(clock, SilentLogger).also { it.bind(storage("g")) }
        val existing = MessagePart(type = "file", filename = "existing.png", data_ = bytes(3))
        drafts.update(key) { it.copy(text = "current draft", attachments = listOf(existing)) }
        assertTrue(drafts.beginQueueEdit(key, "queue-1"))
        assertFalse(drafts.beginQueueEdit(key, "queue-1"), "the same edit cannot run twice")
        assertTrue(drafts.beginQueueEdit(key, "queue-2"))
        val queuedFile = MessagePart(type = "file", filename = "queued.pdf", data_ = bytes(4))
        val removed = QueuedMessage(
            id = "queue-1", parts = listOf(MessagePart(type = "text", text = "queued text"), queuedFile),
            selection = HarnessSelection("codex", "queued-model", "high", mapOf("fast_mode" to "true")),
        )
        val draft = drafts.finishQueueEdit(key, "queue-1", removed)
        assertEquals("queued text\n\ncurrent draft", draft.text)
        assertEquals(listOf(queuedFile, existing), draft.attachments)
        assertEquals("queued-model", draft.selection?.model)
        assertEquals(setOf("queue-2"), draft.pendingQueueIds)
        // A failed removal restores nothing.
        assertEquals(draft.text, drafts.finishQueueEdit(key, "queue-2", null).text)
        assertEquals("fallback", RestoredMessage.from(QueuedMessage(text = " fallback ")).text)
    }

    @Test
    fun draftsFollowRetargetingAndSurviveARelaunch() {
        val drafts = ConversationDrafts(clock, SilentLogger).also { it.bind(storage("g")) }
        drafts.setText(DraftKey("d1", "local_1"), "offline idea")
        drafts.setText(DraftKey("d1", "c_1"), "already here")
        drafts.retargetAll("local_1", "c_1")
        assertEquals("offline idea\n\nalready here", drafts.draft(DraftKey("d1", "c_1")).text)
        assertEquals("", drafts.draft(DraftKey("d1", "local_1")).text)

        val relaunched = ConversationDrafts(clock, SilentLogger).also { it.bind(storage("g")) }
        assertEquals("offline idea\n\nalready here", relaunched.draft(DraftKey("d1", "c_1")).text)
        relaunched.acceptSend(DraftKey("d1", "c_1"), relaunched.draft(DraftKey("d1", "c_1")).revision)
        assertTrue(ConversationDrafts(clock, SilentLogger).also { it.bind(storage("g")) }.state.value.isEmpty())
    }

    @Test
    fun anEditorTypesAtOnceAndABurstIsWrittenOnce() = runTest {
        val counting = CountingFileSystem(fileSystem)
        val drafts = ConversationDrafts(clock, SilentLogger, backgroundScope).also { it.bind(CoreStorage(counting, "/state/typing".toPath())) }
        val editor = drafts.editor(key)
        val text = "typing faster than the core can echo"
        for (end in 1..text.length) {
            editor.setText(text.take(end))
            assertEquals(text.take(end), editor.state.value.text, "each keystroke lands at once")
        }
        assertEquals(text, drafts.draft(key).text, "the core reads what the composer holds")
        runCurrent()
        assertEquals(text, drafts.state.value[key]?.text, "edits fold into the drafts")
        assertEquals(0, counting.writes, "nothing is written per keystroke")
        advanceTimeBy(ConversationDrafts.SAVE_INTERVAL)
        runCurrent()
        assertEquals(1, counting.writes, "a burst is written once")
        assertEquals(text, ConversationDrafts(clock, SilentLogger).also { it.bind(storage("typing")) }.draft(key).text)

        editor.setText("$text!")
        drafts.flush()
        assertEquals(2, counting.writes, "a flush writes pending text at once")
        drafts.flush()
        assertEquals(2, counting.writes, "and only when something changed")
    }

    @Test
    fun aSendThroughAnOpenEditorClearsOnlyWhatWasSent() = runTest {
        val drafts = ConversationDrafts(clock, SilentLogger, backgroundScope).also { it.bind(storage("g")) }
        val editor = drafts.editor(key)
        editor.setText("hello")
        assertTrue(drafts.acceptSend(key, drafts.draft(key).revision))
        assertEquals("", editor.state.value.text, "the composer clears at once")

        editor.setText("next")
        val sent = drafts.draft(key)
        editor.setText("next, typed while sending")
        assertFalse(drafts.acceptSend(key, sent.revision), "typing after the send is kept")
        assertEquals("next, typed while sending", editor.state.value.text)

        assertEquals(editor, drafts.editor(key), "holders share one editor")
        drafts.release(editor)
        editor.setText("still held")
        runCurrent()
        assertEquals("still held", drafts.draft(key).text, "the editor lives until its last holder lets go")
        drafts.release(editor)
        editor.setText("after release")
        runCurrent()
        assertEquals("still held", drafts.draft(key).text, "a released editor no longer writes")
        assertEquals("still held", drafts.editor(key).state.value.text)
    }

    @Test
    fun retargetingMovesAnOpenEditorsDraft() = runTest {
        val drafts = ConversationDrafts(clock, SilentLogger, backgroundScope).also { it.bind(storage("g")) }
        val local = drafts.editor(DraftKey("d1", "local_1"))
        local.setText("offline idea")
        drafts.retargetAll("local_1", "c_1")
        local.setText("typed into the detached editor")
        runCurrent()
        assertEquals("offline idea", drafts.editor(DraftKey("d1", "c_1")).state.value.text)
        assertEquals("", drafts.draft(DraftKey("d1", "local_1")).text)
    }

    @Test
    fun draftsAreBoundedByRecentUse() {
        val drafts = ConversationDrafts(clock, SilentLogger).also { it.bind(storage("g")) }
        repeat(70) { drafts.setText(DraftKey("d", "c$it"), "text $it") }
        drafts.draft(DraftKey("d", "c6"))
        drafts.setText(DraftKey("d", "new"), "x")
        assertEquals(ConversationDrafts.MAX_DRAFTS, drafts.state.value.size)
        assertEquals("text 6", drafts.draft(DraftKey("d", "c6")).text, "reading counts as use")
        assertEquals("", drafts.draft(DraftKey("d", "c7")).text)
    }

    @Test
    fun attachmentLimitsMatchTheDaemon() {
        val mb = 1024 * 1024
        assertNull(Attachments.limitError(List(4) { MessagePart(type = "file", data_ = bytes(mb)) }))
        assertEquals("You can attach up to 4 images or files.", Attachments.limitError(List(5) { MessagePart(type = "file", data_ = bytes(1)) }))
        assertEquals("Each attachment must be at most 5 MB.", Attachments.limitError(listOf(MessagePart(data_ = bytes(5 * mb + 1)))))
        assertEquals("Attachments must total at most 6 MB.", Attachments.limitError(listOf(MessagePart(data_ = bytes(3 * mb)), MessagePart(data_ = bytes(3 * mb + 1)))))
        assertTrue(Attachments.limitError(listOf(MessagePart(filename = "a.txt")))!!.contains("empty"))
        assertEquals(5, Attachments.size(MessagePart(url = "data:text/plain;base64,aGVsbG8=")))
        assertEquals("image/png", Attachments.mediaType("Image/PNG; charset=binary", "x"))
        assertEquals("application/pdf", Attachments.mediaType(null, "report.PDF"))
        assertEquals(Attachments.OCTET_STREAM, Attachments.mediaType("nonsense", "blob"))
        assertEquals("secret.txt", Attachments.filename("..\\..\\secret.txt", "text/plain"))
        assertEquals("attached-image", Attachments.filename(" ", "image/png"))
        assertEquals("file", Attachments.part("a.png", "image/png", bytes(1)).type)
        assertEquals(listOf("text", "file"), Attachments.messageParts("  hi  ", listOf(MessagePart(type = "file"))).map { it.type })
        assertEquals("hi", Attachments.messageParts("  hi  ", emptyList()).single().text)
        assertTrue(Attachments.messageParts(" ", emptyList()).isEmpty())
    }

    @Test
    fun titlesAreBoundedPlaceholders() {
        val long = "word ".repeat(30).trim()
        val title = Titles.task(long)!!
        assertTrue(title.length <= 80 && !title.endsWith(" "))
        assertEquals("First line", Titles.task("\n  First line \nsecond"))
        assertEquals("a".repeat(80), Titles.task("a".repeat(100)))
        assertEquals("New chat", Titles.chat(" "))
        assertEquals("screenshot.png", Titles.chat("", listOf(MessagePart(filename = "screenshot.png"))))
        assertEquals("b".repeat(69) + "…", Titles.chat("b".repeat(100)))
        assertEquals("screenshot.png", Titles.creation("", "", listOf(MessagePart(filename = "screenshot.png"))))
        assertEquals("New task", Titles.creation("", "", emptyList()))
    }

    private val sol = HarnessModel(id = "sol", default_effort = "low", efforts = listOf("low", "high", "xhigh"))
    private val spark = HarnessModel(id = "spark", efforts = listOf("low"))
    private val codex = Harness(
        id = "codex", default_model = "sol", models = listOf(sol, spark),
        effort = EffortConfig(options = listOf(EffortOption("low"), EffortOption("medium"), EffortOption("high"), EffortOption("xhigh"))),
        capabilities = listOf(HarnessCapability("model-selection", "between-turns")),
        options = listOf(
            ProviderOption(id = "fast_mode", type = "bool", default_value = "false", mutable = true, models = listOf("sol")),
            ProviderOption(id = "mode", type = "enum", default_value = "safe", choices = listOf(ProviderOptionChoice("safe"), ProviderOptionChoice("yolo"))),
            ProviderOption(id = "future", type = "text", default_value = "x"),
        ),
    )
    private val claude = Harness(id = "claude", default_model = "opus", models = listOf(HarnessModel(id = "opus")))

    @Test
    fun selectionsResolveAgainstTheCatalog() {
        assertEquals(HarnessSelection("codex", "sol", "xhigh", mapOf("fast_mode" to "true", "mode" to "safe", "future" to "x")),
            Selections.resolve(HarnessSelection("codex", "sol", "xhigh", mapOf("fast_mode" to "TRUE", "mode" to "bogus", "obsolete" to "1")), listOf(codex)))
        assertEquals(HarnessSelection("codex", "sol", "low", mapOf("fast_mode" to "false", "mode" to "safe", "future" to "x")),
            Selections.resolve(HarnessSelection("gone", "gone", "high"), listOf(codex)), "a stale choice falls back to the first harness and its defaults")
        assertEquals("low", Selections.resolve(HarnessSelection("codex", "spark", "medium"), listOf(codex))!!.effort, "an effort the model rejects is replaced")
        assertEquals(HarnessSelection(), Selections.resolve(HarnessSelection(), listOf(codex), allowServerDefault = true))
        assertNull(Selections.resolve(HarnessSelection("codex"), emptyList()))
        assertEquals(mapOf("mode" to "safe", "future" to "x"), Selections.normalizedOptions(codex, "spark", mapOf("fast_mode" to "true")))
        val switched = Selections.selectingModel(HarnessSelection("codex", "sol", "high", mapOf("fast_mode" to "true")), codex, "spark")
        assertEquals("default", switched.effort)
        assertFalse("fast_mode" in switched.provider_options)
        assertEquals(HarnessSelection("claude", "opus", "default"), Selections.selectingProvider(claude))
        assertTrue(Selections.supports(listOf(codex), HarnessSelection("codex", "sol")))
        assertFalse(Selections.supports(listOf(codex), HarnessSelection("codex", "retired")))
        assertFalse(Selections.supports(listOf(codex), HarnessSelection("claude", "sol")))
    }

    @Test
    fun startedConversationsLockTheirAgent() {
        val started = Card(initial_prompt_sent_at = "2026-01-01T00:00:00Z")
        assertTrue(Selections.locked(started))
        assertTrue(Selections.locked(Card(runtime = "running")))
        assertFalse(Selections.locked(Card()))
        assertTrue(Selections.canChange(codex, Selections.MODEL_SELECTION, locked = true))
        assertFalse(Selections.canChange(codex, Selections.EFFORT_SELECTION, locked = true))
        assertTrue(Selections.canChange(claude, Selections.EFFORT_SELECTION, locked = false))
        assertTrue(Selections.optionEnabled(codex.options[0], locked = true))
        assertFalse(Selections.optionEnabled(codex.options[1], locked = true))
        val card = Card(provider = "codex", model = "sol", effort = "high")
        assertEquals(HarnessSelection("codex", "sol", "high"), Selections.forSend(null, card))
        assertEquals(HarnessSelection("codex", "spark", "default"), Selections.forSend(HarnessSelection("codex", "spark"), card))
    }

    private val project = Project(id = "p", base_branch = "main", base_remote = "origin", checkouts = listOf(Checkout(id = "k1", daemon_id = "d1")))
    private val board = Board(id = "b", project_id = "p", lanes = listOf(Lane("todo", "Todo"), Lane("running", "Running")), labels = listOf(Label(id = "l1")))

    @Test
    fun creationRulesAndRequests() {
        assertTrue(Creation.defersStart(chat = false, lane = "todo"))
        assertFalse(Creation.defersStart(chat = false, lane = "Running"))
        assertFalse(Creation.defersStart(chat = true, lane = ""))
        assertFalse(Creation.opensAfterCreate(chat = false, lane = "todo"))
        assertTrue(Creation.opensAfterCreate(chat = false, lane = "running"))
        assertTrue(Creation.opensAfterCreate(chat = true, lane = ""))

        val two = project.copy(checkouts = project.checkouts + Checkout(id = "k2", daemon_id = "d2"))
        assertEquals("k1", Creation.checkout(project, null)?.id)
        assertNull(Creation.checkout(two, null), "several checkouts need a choice")
        assertNull(Creation.checkout(two, "stale"))
        assertEquals("k2", Creation.checkout(two, "k2")?.id)
        assertNull(Creation.checkout(project.copy(checkouts = listOf(Checkout(id = "k", detached = true))), null))
        assertEquals("k2", Creation.preferredCheckout(two, null, catalogDaemonId = "d2", replicaDaemonId = "d1")?.id)
        assertEquals("k1", Creation.preferredCheckout(two, null, catalogDaemonId = null, replicaDaemonId = "d1")?.id)

        val input = CreationInput(project, board, lane = "todo", prompt = "Fix it", selection = HarnessSelection("codex", "sol", "low"), labelIds = listOf("l1"))
        assertNull(Creation.problem(input, listOf(codex)))
        assertEquals("Loading agent models…", Creation.problem(input, null))
        assertEquals("Remove labels unavailable on this board", Creation.problem(input.copy(labelIds = listOf("gone")), listOf(codex)))
        assertEquals("Choose where this task will run", Creation.problem(input.copy(project = two), listOf(codex)))
        assertEquals("Describe the task.", Creation.problem(input.copy(prompt = " "), listOf(codex)))
        assertNull(Creation.problem(input.copy(prompt = " ", title = "Title only"), listOf(codex)))

        val request = Creation.request(input)
        assertEquals(CreateConversationRequest(
            checkout_id = "k1", project_id = "p", board_id = "b", lane = "todo", title = "Fix it", prompt = "Fix it", provider = "codex", model = "sol", effort = "low",
            label_ids = listOf("l1"), defer_start = true, workspace_mode = "worktree", workspace_base_branch = "main", workspace_base_remote = "origin",
            remote_publish_mode = "manual", auto_generate_title = true,
        ), request)
        val chat = Creation.request(input.copy(chat = true, workspaceMode = WorkspaceMode.PROJECT, title = "Named"))
        assertEquals("", chat.board_id)
        assertEquals("", chat.lane)
        assertFalse(chat.defer_start)
        assertEquals("", chat.workspace_base_branch)
        assertFalse(chat.auto_generate_title)
        assertEquals("Fix it", Creation.request(input.copy(chat = true)).title)
        assertTrue(Creation.request(input.copy(chat = true)).auto_generate_title)
        assertEquals(WorkspaceMode.PROJECT, WorkspaceMode.parse("anything"))
    }

    @Test
    fun creationMemoryRestoresTheLastValidChoice() {
        val memory = CreationMemory(storage("install"), SilentLogger)
        assertEquals(WorkspaceMode.WORKTREE, memory.workspaceMode)
        memory.remember(HarnessSelection("codex", "sol", "xhigh"), WorkspaceMode.PROJECT, projectId = "p", boardId = "b")
        val restored = CreationMemory(storage("install"), SilentLogger)
        assertEquals(HarnessSelection("codex", "sol", "xhigh", mapOf("fast_mode" to "false", "mode" to "safe", "future" to "x")), restored.selection(listOf(codex)))
        assertEquals(WorkspaceMode.PROJECT, restored.workspaceMode)
        assertEquals("b", restored.rememberedBoard(project, listOf(Board(id = "a"), Board(id = "b")))?.id)
        assertEquals("a", restored.rememberedBoard(project, listOf(Board(id = "a")))?.id)
        restored.setBoardNotifications("b", true)
        assertTrue(CreationMemory(storage("install"), SilentLogger).notifiesBoard("b"))
    }

    @Test
    fun capturesFreezeTheirSubmissionAndSurviveRestarts() {
        val unbound = TaskCaptures(clock, SilentLogger)
        assertFalse(unbound.view.value.bound, "hosts wait for the journal before capturing")
        val captures = TaskCaptures(clock, SilentLogger).also { it.bind(storage("g")) }
        assertTrue(captures.view.value.bound)
        val draft = captures.begin(projectId = "p", boardId = "b")
        captures.update(draft.id) { it.copy(request = it.request!!.copy(prompt = "Ship it"), importing = true) }
        // Process death during an import.
        val restarted = TaskCaptures(clock, SilentLogger).also { it.bind(storage("g")) }
        val restored = restarted.draft(draft.id)!!
        assertEquals("Ship it", restored.request!!.prompt)
        assertEquals("Import was interrupted. Choose the file again.", restored.failures.single().message)
        assertFailsWith<CoreException> { restarted.freeze(draft.id, restored.request!!) }
        restarted.update(draft.id) { it.copy(failures = emptyList()) }

        val frozen = restarted.freeze(draft.id, CreateConversationRequest(project_id = "p", prompt = "Ship it"))
        assertTrue(frozen.submission_id.isNotEmpty())
        assertEquals(frozen.submission_id, restarted.freeze(draft.id, CreateConversationRequest(prompt = "changed")).submission_id)
        assertFailsWith<CoreException> { restarted.update(draft.id) { it.copy(request = CreateConversationRequest(prompt = "late edit")) } }
        val again = TaskCaptures(clock, SilentLogger).also { it.bind(storage("g")) }.draft(draft.id)!!
        assertEquals(frozen.submission_id, again.submission_id)
        assertEquals("Ship it", again.request!!.prompt)
        restarted.accepted(draft.id)
        assertNull(TaskCaptures(clock, SilentLogger).also { it.bind(storage("g")) }.draft(draft.id))
    }

    @Test
    fun theCaptureJournalIsBounded() {
        val captures = TaskCaptures(clock, SilentLogger).also { it.bind(storage("g")) }
        val first = captures.begin()
        assertEquals(first.id, captures.begin().id, "an empty draft is reused")
        captures.update(first.id) { it.copy(request = CreateConversationRequest(prompt = "first")) }
        repeat(TaskCaptures.MAX_DRAFTS - 1) { index ->
            val draft = captures.create(id = "draft-$index")
            captures.update(draft.id) { it.copy(request = CreateConversationRequest(prompt = "task $index")) }
        }
        assertEquals(TaskCaptures.MAX_DRAFTS, captures.view.value.drafts.size)
        assertFailsWith<CoreException> { captures.create(id = "overflow") }
        assertEquals(captures.view.value.drafts.last().id, captures.begin().id, "a full journal resumes the latest draft")
    }
}
