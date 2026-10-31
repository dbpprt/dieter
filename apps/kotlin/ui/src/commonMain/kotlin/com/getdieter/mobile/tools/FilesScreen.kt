@file:OptIn(androidx.compose.foundation.layout.ExperimentalLayoutApi::class)

package com.getdieter.mobile.tools

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.getdieter.client.v1.*
import com.getdieter.core.files.FilePaths
import com.getdieter.mobile.app.*
import com.getdieter.mobile.design.*
import com.getdieter.mobile.design.Tone
import com.getdieter.mobile.navigation.*
import com.getdieter.mobile.platform.*
import com.getdieter.mobile.store.*

private fun String.trimSlashes() = trim('/').trim()

@Composable
internal fun FilesScreen(
    store: MobileStore,
    inConversation: Boolean = false,
    route: MobileRoute.FilePath? = null,
    /** The project tool route when this is a project's Files page. */
    tool: MobileRoute.Tool? = null,
) {
    if (route?.file == true) {
        DocumentScreen(store, route)
        return
    }
    val view by store.files.slice.collectAsState()
    val conversation by store.conversation.slice.collectAsState()
    var create by remember { mutableStateOf<Boolean?>(null) }
    var moving by remember { mutableStateOf<com.getdieter.api.v1.FileEntry?>(null) }
    var deleting by remember { mutableStateOf<com.getdieter.api.v1.FileEntry?>(null) }
    val buffers by store.files.buffers.collectAsState()
    val path = route?.path.orEmpty()
    // A project's page waits until Files shows its checkout, never the previous binding.
    val checkout = tool?.let { store.toolCheckout(it) }
    val ready =
        (route == null || view.directory.trimSlashes() == path.trimSlashes()) &&
            (tool == null || view.target?.checkout_id == checkout?.id)
    val cardId = if (inConversation) store.conversation.selectedCard.value else ""
    val title = path.trimSlashes().substringAfterLast('/').ifEmpty { "Files" }
    val subtitle =
        if (inConversation) conversation.card?.title.orEmpty()
        else view.target?.let { scopeSubtitle(store, it.project_id, it.daemon_id) }.orEmpty()
    val chrome =
        ScreenChrome(
            title,
            subtitle = subtitle,
            actions =
                listOf(
                    ChromeAction(
                        "files-menu",
                        "File actions",
                        Glyph.MORE_HORIZONTAL,
                        menu =
                            listOfNotNull(
                                MenuSection(
                                    listOf(
                                        ChromeAction("new-file", "New file", Glyph.FILE) {
                                            create = false
                                        },
                                        ChromeAction("new-folder", "New folder", Glyph.FOLDER_ADD) {
                                            create = true
                                        },
                                    )
                                ),
                                MenuSection(
                                    listOf(
                                        ChromeAction(
                                            "hidden",
                                            "Show hidden files",
                                            Glyph.EYE,
                                            checked = view.show_hidden,
                                        ) {
                                            store.files.command(
                                                FilesCommand(
                                                    show_hidden = Toggle(!view.show_hidden)
                                                )
                                            )
                                        },
                                        ChromeAction("refresh-files", "Refresh", Glyph.REFRESH) {
                                            store.files.command(
                                                FilesCommand(load = FilesPath(path))
                                            )
                                        },
                                    )
                                ),
                                tool
                                    ?.let { checkoutMenu(store, it) }
                                    ?.let { MenuSection(listOf(it)) },
                            ),
                    )
                ),
        )
    if (tool != null && checkout == null) {
        Screen(chrome) { NoCheckout(store, tool.projectId) }
        return
    }
    Screen(chrome) {
        LazyColumn(
            Modifier.fillMaxSize().testTag("files-list"),
            state = listState,
            contentPadding = padding,
        ) {
            if (view.listing_error.isNotEmpty() && ready)
                item("error") {
                    Banner(
                        "Files unavailable",
                        view.listing_error,
                        Modifier.padding(horizontal = ScreenMargin, vertical = 8.dp),
                        tone = Tone.DANGER,
                        actionLabel = "Retry",
                        onAction = { store.files.command(FilesCommand(load = FilesPath(path))) },
                    )
                }
            if (!ready || (view.listing_loading && view.entries.isEmpty()))
                item("loading") {
                    Box(
                        Modifier.fillMaxWidth().padding(48.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        Spinner(Modifier.size(26.dp))
                    }
                }
            else {
                item("top") { Spacer(Modifier.height(8.dp)) }
                val entries = view.entries
                if (entries.isEmpty() && view.listing_error.isEmpty())
                    item("empty") {
                        EmptyState(
                            Glyph.FOLDER,
                            "Empty folder",
                            "Create a file or folder from the menu.",
                            Modifier.padding(top = 40.dp),
                        )
                    }
                itemsIndexed(entries, key = { _, entry -> entry.path }) { index, entry ->
                    val folder = entry.kind == "directory"
                    val menu = rememberMenuState()
                    val edited =
                        buffers.entries.any {
                            it.key.endsWith(entry.path) && it.value.text != it.value.original
                        }
                    val sections =
                        listOf(
                            MenuSection(
                                listOf(
                                    ChromeAction(
                                        "move-${entry.path}",
                                        "Rename or move…",
                                        Glyph.RENAME,
                                    ) {
                                        moving = entry
                                    },
                                    ChromeAction(
                                        "delete-${entry.path}",
                                        "Delete",
                                        Glyph.TRASH,
                                        destructive = true,
                                    ) {
                                        deleting = entry
                                    },
                                )
                            )
                        )
                    MenuAnchor(menu) {
                        ListRow(
                            entry.name,
                            Modifier.testTag("file-${entry.name}"),
                            position = Position.of(index, entries.size),
                            subtitle =
                                if (folder) null
                                else formatBytes(entry.size) + if (edited) " · Edited" else "",
                            glyph = if (folder) Glyph.FOLDER else Glyph.FILE,
                            glyphTint = if (folder) Color(0xFF1E9BF0) else palette.secondaryLabel,
                            accessory = if (folder) Accessory.CHEVRON else Accessory.NONE,
                            onClick = {
                                store.push(MobileRoute.FilePath(entry.path, !folder, cardId))
                            },
                            onLongClick = { menu.show(sections) },
                        )
                    }
                }
            }
        }
    }
    create?.let { directory ->
        PromptDialog(
            if (directory) "New folder" else "New file",
            "",
            "Create",
            { name ->
                store.files.command(
                    FilesCommand(
                        create =
                            FilesCreate(
                                if (path.isEmpty()) name else "${path.trimSlashes()}/$name",
                                directory,
                            )
                    )
                )
                create = null
            },
            { create = null },
            placeholder = if (directory) "Folder name" else "File name",
        )
    }
    moving?.let { entry ->
        PromptDialog(
            "Rename or move",
            entry.path,
            "Move",
            { destination ->
                if (FilePaths.normalize(destination).isSuccess)
                    store.files.command(FilesCommand(move = FilesMove(entry.path, destination)))
                moving = null
            },
            { moving = null },
            message = "Path relative to the workspace.",
        )
    }
    deleting?.let { entry ->
        ConfirmDialog(
            "Delete ${entry.name}?",
            if (entry.kind == "directory") "This deletes the folder and its contents."
            else "This deletes the file from the workspace.",
            "Delete",
            {
                store.files.command(
                    FilesCommand(delete = FilesDelete(entry.path, entry.kind == "directory"))
                )
                deleting = null
            },
            { deleting = null },
            destructive = true,
        )
    }
}

internal fun formatBytes(size: Long): String =
    when {
        size < 1024 -> "$size bytes"
        size < 1024 * 1024 -> "${(size / 102.4).toInt() / 10.0} KB"
        else -> "${(size / 104857.6).toInt() / 10.0} MB"
    }

@Composable
private fun DocumentScreen(store: MobileStore, route: MobileRoute.FilePath) {
    val view by store.files.slice.collectAsState()
    val buffers by store.files.buffers.collectAsState()
    val previewAttachment = rememberAttachmentViewer { store.error.value = it }
    var markdown by remember(route.path) { mutableStateOf(route.path.endsWith(".md", true)) }
    var deleting by remember { mutableStateOf(false) }
    var moving by remember { mutableStateOf(false) }
    val document =
        view.document.takeIf { view.selected_path.trimSlashes() == route.path.trimSlashes() }
    val buffer = buffers[view.document_key]
    val text = buffer?.text ?: document?.content.orEmpty()
    val dirty = buffer != null && buffer.text != buffer.original
    val isMarkdown = document != null && FilePaths.renderer(document) == FilePaths.Renderer.MARKDOWN
    LaunchedEffect(view.document_key, document?.revision) {
        document?.let { store.files.syncBuffer(view.document_key, it.content) }
    }
    fun save() {
        val key = view.document_key
        val saved = text
        store.action {
            store.core
                .dispatch(
                    Command(
                        files =
                            FilesCommand(scope = MobileStore.FILES_SCOPE, save = FilesText(saved))
                    )
                )
                .file_document
                ?.let {
                    store.files.savedBuffer(key, it.content)
                }
        }
    }
    val chrome =
        ScreenChrome(
            route.path.substringAfterLast('/'),
            subtitle = if (dirty) "Edited" else route.path.substringBeforeLast('/', ""),
            confirm =
                if (document != null && !document.binary && (dirty || view.saving))
                    ChromeAction(
                        "save-file",
                        if (view.saving) "Saving…" else "Save",
                        null,
                        enabled = dirty && !view.saving,
                    ) {
                        save()
                    }
                else null,
            actions =
                listOf(
                    ChromeAction(
                        "document-menu",
                        "Document actions",
                        Glyph.MORE_HORIZONTAL,
                        menu =
                            listOfNotNull(
                                if (isMarkdown)
                                    MenuSection(
                                        listOf(
                                            ChromeAction(
                                                "preview-markdown",
                                                "Preview",
                                                Glyph.EYE,
                                                checked = markdown,
                                            ) {
                                                markdown = true
                                            },
                                            ChromeAction(
                                                "edit-markdown",
                                                "Edit",
                                                Glyph.EDIT,
                                                checked = !markdown,
                                            ) {
                                                markdown = false
                                            },
                                        )
                                    )
                                else null,
                                MenuSection(
                                    listOfNotNull(
                                        if (dirty)
                                            ChromeAction("discard", "Discard edits", Glyph.UNDO) {
                                                store.files.discardBuffer(view.document_key)
                                            }
                                        else null,
                                        if (view.conflict)
                                            ChromeAction(
                                                "reload",
                                                "Reload from disk",
                                                Glyph.REFRESH,
                                            ) {
                                                store.files.command(FilesCommand(reload = Step()))
                                            }
                                        else null,
                                        ChromeAction(
                                            "rename-file",
                                            "Rename or move…",
                                            Glyph.RENAME,
                                        ) {
                                            moving = true
                                        },
                                        ChromeAction(
                                            "delete-file",
                                            "Delete",
                                            Glyph.TRASH,
                                            destructive = true,
                                        ) {
                                            deleting = true
                                        },
                                    )
                                ),
                            ),
                    )
                ),
        )
    Screen(chrome) {
        Column(Modifier.fillMaxSize().imePadding().padding(top = padding.calculateTopPadding())) {
            if (view.conflict)
                Banner(
                    "File changed on disk",
                    "Your edits are kept. Reload the current version before saving again.",
                    Modifier.padding(horizontal = ScreenMargin, vertical = 6.dp),
                    tone = Tone.WARNING,
                    actionLabel = "Reload",
                    onAction = { store.files.command(FilesCommand(reload = Step())) },
                )
            if (view.document_error.isNotEmpty())
                Banner(
                    "Unable to open file",
                    view.document_error,
                    Modifier.padding(horizontal = ScreenMargin, vertical = 6.dp),
                    tone = Tone.DANGER,
                )
            when {
                document == null ->
                    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                        Spinner(Modifier.size(26.dp))
                    }
                document.binary ->
                    EmptyState(
                        Glyph.FILE_PLAIN,
                        document.name,
                        "${document.mime_type.ifEmpty { "Binary file" }} · ${formatBytes(document.size)}",
                        Modifier.padding(top = 60.dp),
                    ) {
                        DButton(
                            "Open preview",
                            {
                                previewAttachment(
                                    com.getdieter.core.composition.Attachments.part(
                                        document.name,
                                        document.mime_type,
                                        FilePaths.bytes(document),
                                    )
                                )
                            },
                            glyph = Glyph.EYE,
                        )
                    }
                markdown && isMarkdown ->
                    Column(
                        Modifier.fillMaxSize()
                            .verticalScroll(rememberScrollState())
                            .padding(horizontal = 20.dp, vertical = 12.dp)
                            .padding(bottom = padding.calculateBottomPadding())
                    ) {
                        RichText(text)
                    }
                else ->
                    BasicTextField(
                        text,
                        { store.files.editBuffer(view.document_key, document.content, it) },
                        Modifier.fillMaxSize()
                            .verticalScroll(rememberScrollState())
                            .padding(horizontal = 16.dp, vertical = 12.dp)
                            .padding(bottom = padding.calculateBottomPadding())
                            .testTag("file-editor")
                            .semantics { contentDescription = "File contents" },
                        textStyle = type.mono.copy(color = palette.label),
                        cursorBrush = SolidColor(if (apple) palette.info else colors.primary),
                    )
            }
        }
    }
    if (deleting)
        ConfirmDialog(
            "Delete ${route.path.substringAfterLast('/')}?",
            "This deletes the file from the workspace.",
            "Delete",
            {
                store.files.command(FilesCommand(delete = FilesDelete(route.path, false)))
                deleting = false
                store.pop()
            },
            { deleting = false },
            destructive = true,
        )
    if (moving)
        PromptDialog(
            "Rename or move",
            route.path,
            "Move",
            { destination ->
                if (FilePaths.normalize(destination).isSuccess) {
                    store.files.command(FilesCommand(move = FilesMove(route.path, destination)))
                    store.pop()
                }
                moving = false
            },
            { moving = false },
        )
}

/** A project tool's page when the project has no checkout on any machine. */
@Composable
internal fun NoCheckout(store: MobileStore, projectId: String) {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        EmptyState(
            Glyph.MACHINE,
            "No checkout",
            "Attach this project to a folder on one of your machines to browse it here.",
        ) {
            DButton(
                "Open project",
                {
                    store.showFrom(
                        MobileRoute.Root(MobileTab.PROJECTS),
                        MobileRoute.Project(projectId),
                    )
                },
            )
        }
    }
}
