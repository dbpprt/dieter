package com.dbpprt.dieter.core.files

import com.dbpprt.dieter.api.v1.ConversationRef
import com.dbpprt.dieter.api.v1.CreateFileRequest
import com.dbpprt.dieter.api.v1.DeleteFileRequest
import com.dbpprt.dieter.api.v1.DieterServiceClient
import com.dbpprt.dieter.api.v1.FileDocument
import com.dbpprt.dieter.api.v1.FileEntry
import com.dbpprt.dieter.api.v1.ListFilesRequest
import com.dbpprt.dieter.api.v1.MoveFileRequest
import com.dbpprt.dieter.api.v1.ReadFileRequest
import com.dbpprt.dieter.api.v1.SaveFileRequest
import com.dbpprt.dieter.core.presentation.WorkspaceImages
import com.dbpprt.dieter.core.runtime.CoreException
import com.dbpprt.dieter.core.runtime.Deadlines
import com.dbpprt.dieter.core.runtime.FailureKind
import com.dbpprt.dieter.core.runtime.Failures
import com.dbpprt.dieter.core.session.MachineSessions
import com.squareup.wire.GrpcException
import com.squareup.wire.GrpcStatus
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import okio.ByteString
import okio.ByteString.Companion.encodeUtf8

/** Where files live: a project checkout, or a conversation's workspace when [cardId] is set. */
data class FilesTarget(val daemonId: String, val projectId: String, val checkoutId: String = "", val cardId: String = "") {
    /** Identifies a native editor buffer; components are length-prefixed so no two targets collide. */
    fun documentKey(path: String): String =
        listOf(daemonId, projectId, checkoutId, cardId, path).joinToString("") { "${it.encodeUtf8().size}:$it" }
}

/** A save conflict: the file changed on disk after it was read. */
class FileConflictException(val path: String, cause: Throwable) :
    CoreException(FailureKind.CONFLICT, "“${path.substringAfterLast('/')}” changed on disk. Reload it to see the new version, or keep editing your copy.", cause)

data class FilesView(
    val target: FilesTarget? = null,
    val directory: String = "",
    val entries: List<FileEntry> = emptyList(),
    val showHidden: Boolean = false,
    val listingLoading: Boolean = false,
    val listingError: String? = null,
    val selectedPath: String = "",
    val document: FileDocument? = null,
    /** The open document's text as edited; kept through a save conflict. */
    val draft: String = "",
    val documentLoading: Boolean = false,
    val documentError: String? = null,
    /** The last save hit a newer version on disk. */
    val conflict: Boolean = false,
    val saving: Boolean = false,
    val canGoBack: Boolean = false,
    val canGoForward: Boolean = false,
) {
    /** The draft differs from the version last read or saved. */
    val dirty: Boolean get() = document != null && !document.binary && draft != document.content

    /** Identifies the selected file's native editor buffer; "" without a target. */
    val documentKey: String get() = target?.documentKey(selectedPath).orEmpty()

    /** How to show the open document; null without one. */
    val renderer: FilePaths.Renderer? get() = document?.let { FilePaths.renderer(it) }

    /** The open document's language, e.g. "Swift" or "Plain text"; "" without one. */
    val languageName: String get() = document?.let { codeLanguageForPath(it.name).displayName }.orEmpty()

    /** "Markdown", the open document's media type, or "Unknown type"; "" without one. */
    val typeLabel: String get() = document?.let { FilePaths.typeLabel(it.name, it.mime_type) }.orEmpty()
}

/** Back and forward folder history, each bounded to 100 entries. */
class FileNavigation {
    private val back = ArrayDeque<String>()
    private val forward = ArrayDeque<String>()
    val canGoBack: Boolean get() = back.isNotEmpty()
    val canGoForward: Boolean get() = forward.isNotEmpty()

    fun record(from: String, to: String) {
        if (from == to) return
        push(back, from)
        forward.clear()
    }

    fun goBack(from: String): String? = back.removeLastOrNull()?.also { push(forward, from) }

    fun goForward(from: String): String? = forward.removeLastOrNull()?.also { push(back, from) }

    fun reset() {
        back.clear()
        forward.clear()
    }

    fun snapshot(): Pair<List<String>, List<String>> = back.toList() to forward.toList()

    fun restore(snapshot: Pair<List<String>, List<String>>) {
        back.clear(); back.addAll(snapshot.first)
        forward.clear(); forward.addAll(snapshot.second)
    }

    private fun push(stack: ArrayDeque<String>, value: String) {
        stack.addLast(value)
        while (stack.size > LIMIT) stack.removeFirst()
    }

    companion object {
        const val LIMIT = 100
    }
}

object FilePaths {
    /** The parent folder; the project root is "". */
    fun parent(path: String): String = path.trimEnd('/').substringBeforeLast('/', "").let { if (it == ".") "" else it }

    /** The daemon's path rules, checked before sending: relative, inside the project, never `.git`. */
    fun normalize(input: String, allowRoot: Boolean = false): Result<String> {
        if ('\u0000' in input || '\\' in input || input.startsWith("/")) return Result.failure(IllegalArgumentException("project file path must be relative"))
        val parts = mutableListOf<String>()
        for (part in input.split('/')) {
            when (part) {
                "", "." -> Unit
                ".." -> if (parts.isEmpty()) return Result.failure(IllegalArgumentException("project file path cannot leave the project")) else parts.removeAt(parts.lastIndex)
                else -> parts += part
            }
        }
        if (parts.any { it == ".git" }) return Result.failure(IllegalArgumentException(".git is protected"))
        val cleaned = parts.joinToString("/")
        if (cleaned.isEmpty() && !allowRoot) return Result.failure(IllegalArgumentException("project file path is required"))
        return Result.success(cleaned)
    }

    fun join(directory: String, name: String): String = listOf(directory.trim('/'), name.trim('/')).filter { it.isNotBlank() }.joinToString("/")

    /** One more than the number of line feeds: "" is one line, "a\nb\n" three. */
    fun countLines(text: String): Int = 1 + text.count { it == '\n' }

    /**
     * The UTF-16 range of 1-based [line] without its terminator; `\n`, `\r`,
     * and `\r\n` end a line, and out-of-range lines clamp to the first or last.
     */
    fun lineRange(line: Int, text: String): IntRange {
        val starts = mutableListOf(0)
        var index = 0
        while (index < text.length) {
            when (text[index]) {
                '\r' -> {
                    if (index + 1 < text.length && text[index + 1] == '\n') index++
                    starts += index + 1
                }
                '\n' -> starts += index + 1
            }
            index++
        }
        val target = line.coerceIn(1, starts.size) - 1
        val start = starts[target]
        var end = start
        while (end < text.length && text[end] != '\n' && text[end] != '\r') end++
        return start until end
    }

    private val imageExtensions = setOf("png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp", "ico", "svg")

    fun isImage(name: String, mimeType: String): Boolean =
        mimeType.lowercase().startsWith("image/") || name.substringAfterLast('.', "").lowercase() in imageExtensions

    fun bytes(document: FileDocument): ByteString = if (document.binary) document.data_ else document.content.encodeUtf8()

    enum class Renderer { PDF, IMAGE, UNSUPPORTED, MARKDOWN, HTML, TEXT }

    fun renderer(document: FileDocument): Renderer = renderer(document.name, document.mime_type, document.binary)

    /** Text, Markdown, and HTML open in the editor; images, PDFs, and other binaries are view-only. */
    fun editable(document: FileDocument): Boolean = editable(document.name, document.mime_type, document.binary)

    fun editable(path: String, mimeType: String, binary: Boolean): Boolean =
        renderer(path, mimeType, binary).let { it == Renderer.TEXT || it == Renderer.MARKDOWN || it == Renderer.HTML }

    /**
     * How a file is shown, from its name or path and media type: a PDF, then
     * an image, then any other binary file is unsupported, then Markdown, then
     * HTML ([HtmlPreview]), else text.
     */
    fun renderer(path: String, mimeType: String, binary: Boolean): Renderer {
        val name = path.substringAfterLast('/')
        val extension = name.substringAfterLast('.', "").lowercase()
        val mime = mimeType.substringBefore(';').trim().lowercase()
        return when {
            extension == "pdf" || mime == "application/pdf" -> Renderer.PDF
            isImage(name, mime) -> Renderer.IMAGE
            binary -> Renderer.UNSUPPORTED
            codeLanguageForPath(name) == CodeLanguage.MARKDOWN -> Renderer.MARKDOWN
            extension == "html" || extension == "htm" || mime == "text/html" -> Renderer.HTML
            else -> Renderer.TEXT
        }
    }

    /** A listing entry that is a folder. */
    fun isDirectory(entry: FileEntry): Boolean = entry.kind == "directory"

    enum class Icon { DIRECTORY, IMAGE, MARKDOWN, CODE, TEXT }

    /** [entry]'s listing icon ([icon]). */
    fun icon(entry: FileEntry): Icon = icon(entry.name, isDirectory(entry))

    /** A listing row's icon: a folder, an image, Markdown, a file in a known language, else text. */
    fun icon(name: String, directory: Boolean): Icon = when {
        directory -> Icon.DIRECTORY
        isImage(name, "") -> Icon.IMAGE
        else -> when (codeLanguageForPath(name)) {
            CodeLanguage.MARKDOWN -> Icon.MARKDOWN
            CodeLanguage.PLAIN_TEXT -> Icon.TEXT
            else -> Icon.CODE
        }
    }

    /** "Markdown" for Markdown files, else the media type, or "Unknown type" without one. */
    fun typeLabel(name: String, mimeType: String): String = when {
        codeLanguageForPath(name) == CodeLanguage.MARKDOWN -> "Markdown"
        mimeType.isEmpty() -> "Unknown type"
        else -> mimeType
    }

    /** Finder-like order: directories first, then names with digit runs compared numerically. */
    val naturalOrder: Comparator<FileEntry> = Comparator { a, b ->
        val directories = isDirectory(b).compareTo(isDirectory(a))
        if (directories != 0) directories else natural(a.name, b.name)
    }

    fun natural(a: String, b: String): Int {
        var i = 0
        var j = 0
        while (i < a.length && j < b.length) {
            if (a[i].isDigit() && b[j].isDigit()) {
                val startA = i
                val startB = j
                while (i < a.length && a[i].isDigit()) i++
                while (j < b.length && b[j].isDigit()) j++
                val left = a.substring(startA, i).trimStart('0')
                val right = b.substring(startB, j).trimStart('0')
                if (left.length != right.length) return left.length.compareTo(right.length)
                val compared = left.compareTo(right)
                if (compared != 0) return compared
            } else {
                val compared = a[i].lowercaseChar().compareTo(b[j].lowercaseChar())
                if (compared != 0) return compared
                i++
                j++
            }
        }
        return (a.length - i).compareTo(b.length - j)
    }
}

/**
 * Files of a checkout or conversation workspace. A listing reload never
 * discards an open document; a save only succeeds against the revision that
 * was read, and a conflict keeps the user's edits. Saves are never retried.
 * Confined to the core dispatcher.
 */
class Files(private val sessions: MachineSessions) {
    private val mutableView = MutableStateFlow(FilesView())
    val view: StateFlow<FilesView> = mutableView.asStateFlow()
    private val navigation = FileNavigation()
    private var scope = 0L
    private var reads = 0L

    fun bind(target: FilesTarget?) {
        if (target == view.value.target) return
        scope++
        reads++
        navigation.reset()
        mutableView.value = FilesView(target = target)
    }

    private fun target(): FilesTarget = view.value.target ?: throw CoreException(FailureKind.PERMANENT, "Choose a project first.")

    private suspend fun <T> call(block: suspend (DieterServiceClient) -> T): T = sessions.call(target().daemonId, Deadlines.READ, block)

    /** Lists [path] (the current folder by default). */
    suspend fun load(path: String = view.value.directory): Boolean {
        val target = target()
        val bound = scope
        val cleaned = FilePaths.normalize(path, allowRoot = true).getOrElse { error ->
            mutableView.update { it.copy(listingError = error.message) }
            return false
        }
        mutableView.update { it.copy(listingLoading = true) }
        return try {
            val listing = call {
                it.ListFiles().execute(ListFilesRequest(project_id = target.projectId, checkout_id = if (target.cardId.isEmpty()) target.checkoutId else "", card_id = target.cardId, path = cleaned, show_hidden = view.value.showHidden))
            }
            if (bound != scope) return false
            mutableView.update { it.copy(entries = listing.entries, directory = listing.path, listingLoading = false, listingError = null) }
            true
        } catch (error: Throwable) {
            if (error is CancellationException) throw error
            if (bound == scope) mutableView.update { it.copy(listingLoading = false, listingError = Failures.message(error)) }
            false
        }
    }

    /** Opens a folder, recording history; a failed load restores the history. */
    suspend fun navigate(to: String): Boolean {
        val state = view.value
        if (to == state.directory || state.listingLoading) return false
        val snapshot = navigation.snapshot()
        navigation.record(state.directory, to)
        publishHistory()
        if (load(to)) return true
        navigation.restore(snapshot)
        publishHistory()
        return false
    }

    suspend fun goBack(): Boolean = step(navigation::goBack)

    suspend fun goForward(): Boolean = step(navigation::goForward)

    private suspend fun step(move: (String) -> String?): Boolean {
        val snapshot = navigation.snapshot()
        val destination = move(view.value.directory) ?: return false
        publishHistory()
        if (load(destination)) return true
        navigation.restore(snapshot)
        publishHistory()
        return false
    }

    suspend fun parent(): Boolean = navigate(FilePaths.parent(view.value.directory))

    suspend fun setShowHidden(show: Boolean) {
        mutableView.update { it.copy(showHidden = show) }
        load()
    }

    private fun publishHistory() = mutableView.update { it.copy(canGoBack = navigation.canGoBack, canGoForward = navigation.canGoForward) }

    suspend fun open(path: String) {
        val target = target()
        val bound = scope
        val resolved = resolveWorkspaceImage(path, target)
        if (bound != scope) return
        val read = ++reads
        mutableView.update { it.copy(selectedPath = resolved, document = if (it.selectedPath == resolved) it.document else null, documentLoading = true, documentError = null, conflict = false) }
        try {
            val document = call { it.ReadFile().execute(ReadFileRequest(project_id = target.projectId, checkout_id = if (target.cardId.isEmpty()) target.checkoutId else "", card_id = target.cardId, path = resolved)) }
            if (bound != scope || read != reads) return
            mutableView.update { it.copy(document = document, draft = document.content, documentLoading = false) }
        } catch (error: Throwable) {
            if (error is CancellationException) throw error
            if (bound != scope || read != reads) return
            val message = if (error is GrpcException && error.grpcStatus == GrpcStatus.NOT_FOUND) {
                "“${resolved.substringAfterLast('/')}” could not be found. Refresh the folder or select another file."
            } else {
                Failures.message(error)
            }
            mutableView.update { it.copy(documentLoading = false, documentError = message) }
        }
    }

    /**
     * A conversation's image link as a workspace-relative path. Absolute and
     * `file://` links name files on the card's machine, so they resolve
     * against its workspace (GetWorkspace), never the client's filesystem.
     * Any other path is returned unchanged.
     */
    private suspend fun resolveWorkspaceImage(path: String, target: FilesTarget): String {
        WorkspaceImages.path(path)?.let { return it }
        if (!WorkspaceImages.isWorkspaceImage(path)) return path
        val destination = path.trim().removeSurrounding("<", ">")
        if (target.cardId.isEmpty() || (!destination.startsWith("/") && !destination.startsWith("file://"))) {
            throw CoreException(FailureKind.PERMANENT, OUTSIDE_WORKSPACE)
        }
        val workspace = call { it.GetWorkspace().execute(ConversationRef(card_id = target.cardId)) }
        return WorkspaceImages.path(path, workspace.path) ?: throw CoreException(FailureKind.PERMANENT, OUTSIDE_WORKSPACE)
    }

    /** Replaces the draft of the open document. Safe from any thread, so text fields stay synchronous. */
    fun edit(text: String) {
        if (view.value.document == null) return
        mutableView.update { it.copy(draft = text) }
    }

    /**
     * Saves [text] (the draft) over the revision that was read. On a conflict
     * the draft stays; [reload] fetches the disk version when the user
     * chooses it. A second save while one runs is ignored.
     */
    suspend fun save(text: String = view.value.draft): FileDocument? {
        val target = target()
        val state = view.value
        val document = state.document ?: return null
        if (state.saving || document.binary) return null
        val bound = scope
        val read = reads
        mutableView.update { it.copy(saving = true, documentError = null, conflict = false) }
        try {
            val saved = call {
                it.SaveFile().execute(SaveFileRequest(project_id = target.projectId, checkout_id = if (target.cardId.isEmpty()) target.checkoutId else "", card_id = target.cardId, path = document.path, content = text, revision = document.revision))
            }.let { if (it.mime_type.isEmpty()) it.copy(mime_type = document.mime_type) else it }
            if (bound == scope && read == reads) mutableView.update { it.copy(document = saved) }
            return saved
        } catch (error: Throwable) {
            if (error is CancellationException) throw error
            if (bound != scope || read != reads) return null
            if (error is GrpcException && error.grpcStatus == GrpcStatus.ABORTED) {
                mutableView.update { it.copy(conflict = true, documentError = FileConflictException(document.path, error).message) }
                throw FileConflictException(document.path, error)
            }
            mutableView.update { it.copy(documentError = Failures.message(error)) }
            throw error
        } finally {
            if (bound == scope) mutableView.update { it.copy(saving = false) }
        }
    }

    /** Replaces the open document with the version on disk, discarding the conflicting edits. */
    suspend fun reload() {
        val path = view.value.document?.path ?: view.value.selectedPath.ifEmpty { return }
        open(path)
    }

    suspend fun create(name: String, directory: Boolean) {
        val target = target()
        val path = FilePaths.normalize(FilePaths.join(view.value.directory, name)).getOrElse { throw CoreException(FailureKind.PERMANENT, it.message.orEmpty()) }
        mutate { call { it.CreateFile().execute(CreateFileRequest(project_id = target.projectId, checkout_id = if (target.cardId.isEmpty()) target.checkoutId else "", card_id = target.cardId, path = path, kind = if (directory) "directory" else "file")) } }
    }

    suspend fun move(source: String, destination: String) {
        val target = target()
        val to = FilePaths.normalize(destination.trim()).getOrElse { throw CoreException(FailureKind.PERMANENT, it.message.orEmpty()) }
        if (to == source) return
        mutate {
            call { it.MoveFile().execute(MoveFileRequest(project_id = target.projectId, checkout_id = if (target.cardId.isEmpty()) target.checkoutId else "", card_id = target.cardId, source = source, destination = to)) }
            invalidate(under = source)
        }
    }

    suspend fun delete(path: String, recursive: Boolean) {
        val target = target()
        mutate {
            call { it.DeleteFile().execute(DeleteFileRequest(project_id = target.projectId, checkout_id = if (target.cardId.isEmpty()) target.checkoutId else "", card_id = target.cardId, path = path, recursive = recursive)) }
            invalidate(under = path)
        }
    }

    private suspend fun mutate(block: suspend () -> Unit) {
        val bound = scope
        try {
            block()
        } catch (error: Throwable) {
            if (error is CancellationException) throw error
            if (bound == scope) mutableView.update { it.copy(listingError = Failures.message(error)) }
            throw error
        }
        if (bound == scope) load()
    }

    private fun invalidate(under: String) {
        val selected = view.value.selectedPath
        if (selected != under && !selected.startsWith("$under/")) return
        close()
    }

    /** Closes the open document, dropping its draft; the folder stays. */
    fun close() {
        reads++
        mutableView.update { it.copy(selectedPath = "", document = null, draft = "", documentLoading = false, documentError = null, conflict = false) }
    }

    private companion object {
        const val OUTSIDE_WORKSPACE = "The image is outside this workspace."
    }
}

/** A lazily expanded folder tree for a conversation's workspace. */
class FileTree(private val sessions: MachineSessions) {
    data class Row(val entry: FileEntry, val depth: Int)

    data class TreeView(
        val folders: Map<String, List<FileEntry>> = emptyMap(),
        val expanded: Set<String> = setOf(""),
        val loading: Set<String> = emptySet(),
        val error: String? = null,
        val showHidden: Boolean = false,
    ) {
        fun rows(filter: String = ""): List<Row> {
            val rows = mutableListOf<Row>()
            fun walk(path: String, depth: Int) {
                if (depth >= MAX_DEPTH) return
                for (entry in folders[path].orEmpty()) {
                    if (rows.size >= MAX_ROWS) return
                    rows += Row(entry, depth)
                    if (FilePaths.isDirectory(entry) && entry.path in expanded) walk(entry.path, depth + 1)
                }
            }
            walk("", 0)
            return if (filter.isBlank()) rows else rows.filter { it.entry.name.contains(filter.trim(), ignoreCase = true) }
        }
    }

    private val mutableView = MutableStateFlow(TreeView())
    val view: StateFlow<TreeView> = mutableView.asStateFlow()
    private var target: FilesTarget? = null
    private var generation = 0L

    fun bind(target: FilesTarget?) {
        if (target == this.target) return
        this.target = target
        generation++
        mutableView.value = TreeView(showHidden = view.value.showHidden)
    }

    suspend fun load(path: String = "", force: Boolean = false) {
        val target = target ?: return
        val state = view.value
        if (path in state.loading || (!force && path in state.folders)) return
        val bound = generation
        mutableView.update { it.copy(loading = it.loading + path) }
        try {
            val listing = sessions.call(target.daemonId, Deadlines.READ) { it.ListFiles().execute(ListFilesRequest(project_id = target.projectId, card_id = target.cardId, path = path, show_hidden = view.value.showHidden)) }
            if (bound != generation) return
            mutableView.update { it.copy(folders = it.folders + (path to listing.entries.sortedWith(FilePaths.naturalOrder)), loading = it.loading - path, error = null) }
        } catch (error: Throwable) {
            if (error is CancellationException) throw error
            if (bound == generation) mutableView.update { it.copy(loading = it.loading - path, error = Failures.message(error)) }
        }
    }

    suspend fun toggle(path: String) {
        if (path in view.value.expanded) {
            mutableView.update { it.copy(expanded = it.expanded - path) }
        } else {
            mutableView.update { it.copy(expanded = it.expanded + path) }
            load(path)
        }
    }

    /** Expands and loads every folder above [filePath]. */
    suspend fun reveal(filePath: String) {
        load("")
        val parts = filePath.split('/').dropLast(1)
        var current = ""
        for (part in parts) {
            current = if (current.isEmpty()) part else "$current/$part"
            mutableView.update { it.copy(expanded = it.expanded + current) }
            load(current)
        }
    }

    suspend fun refresh() {
        generation++
        val expanded = view.value.expanded.sorted()
        mutableView.update { it.copy(folders = emptyMap(), loading = emptySet()) }
        for (path in expanded) load(path, force = true)
    }

    suspend fun setShowHidden(show: Boolean) {
        mutableView.update { it.copy(showHidden = show) }
        refresh()
    }

    companion object {
        const val MAX_DEPTH = 40
        const val MAX_ROWS = 10_000
    }
}
