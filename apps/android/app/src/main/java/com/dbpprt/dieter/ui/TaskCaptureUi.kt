@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.dbpprt.dieter.ui

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.dbpprt.dieter.core.composition.Attachments
import com.dbpprt.dieter.core.composition.TaskCaptures
import com.dbpprt.dieter.core.composition.TaskDraftEditor
import com.dbpprt.dieter.core.composition.TaskDrafts
import com.dbpprt.dieter.core.composition.frozen
import com.dbpprt.dieter.core.composition.hasContent
import com.dbpprt.dieter.core.composition.task
import com.dbpprt.dieter.core.state.CaptureDraft
import com.dbpprt.dieter.core.state.CaptureFailure
import kotlinx.coroutines.launch

@Composable
internal fun TaskAttachmentControls(editor: TaskDraftEditor, store: TaskCaptureStore?, onDiscard: () -> Unit = {}) {
    val draft by editor.state.collectAsState()
    val saveError by editor.error.collectAsState()
    var replacing by remember { mutableStateOf<CaptureFailure?>(null) }
    var picker by remember { mutableStateOf(false) }
    var discard by remember { mutableStateOf(false) }
    var preview by remember { mutableStateOf<com.dbpprt.dieter.api.v1.MessagePart?>(null) }
    val scope = rememberCoroutineScope()
    val editable = !draft.importing && !draft.frozen
    fun chosen(uris: List<android.net.Uri>, imagesOnly: Boolean) {
        if (uris.isNotEmpty()) {
            replacing?.let { failure -> editor.edit { TaskDrafts.removeFailure(it, failure) } }
            store?.import(editor, uris, imagesOnly)
        }
        replacing = null
    }
    val photos = rememberLauncherForActivityResult(ActivityResultContracts.PickMultipleVisualMedia(Attachments.MAX_COUNT)) { chosen(it, imagesOnly = true) }
    val files = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { chosen(it, imagesOnly = false) }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        TextButton(onClick = { replacing = null; picker = true }, enabled = editable, modifier = Modifier.testTag("create-attach")) {
            Text("Add images or files")
        }
        if (draft.importing) {
            LinearProgressIndicator(Modifier.fillMaxWidth())
            Text("Importing attachments…")
            TextButton(onClick = { store?.cancelImport(editor) }) { Text("Cancel import") }
        }
        Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            draft.task.attachments.forEachIndexed { index, part ->
                Column {
                    ComposerAttachmentPreview(part, index, editable) { editor.edit { TaskDrafts.removeAttachment(it, index) } }
                    TextButton(onClick = { preview = part }) { Text("Preview ${part.filename}") }
                }
            }
        }
        draft.failures.forEach { failure ->
            Text(failure.message, color = MaterialTheme.colorScheme.error)
            FlowRow {
                TextButton(onClick = { store?.retry(editor, failure) }, enabled = !draft.importing && failure.source.isNotBlank()) { Text("Retry import") }
                TextButton(onClick = { replacing = failure; picker = true }, enabled = !draft.importing) { Text("Choose again") }
                TextButton(onClick = { editor.edit { TaskDrafts.removeFailure(it, failure) } }, enabled = !draft.importing) { Text("Remove failed attachment") }
            }
        }
        saveError?.let {
            Text(it, color = MaterialTheme.colorScheme.error)
            TextButton(onClick = { scope.launch { runCatching { store?.flush(editor) } } }) { Text("Retry saving draft") }
        }
        Text(Attachments.LIMITS, style = MaterialTheme.typography.bodySmall)
        if (draft.frozen) Text(TaskCaptures.SUBMISSION_PENDING)
        if (draft.hasContent && !draft.frozen) TextButton(onClick = { discard = true }) { Text("Discard draft") }
    }
    if (picker) AttachmentPickerSheet(
        onDismiss = { picker = false; replacing = null },
        onImages = { picker = false; photos.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) },
        onFiles = { picker = false; files.launch(arrayOf("*/*")) },
    )
    if (discard) AlertDialog(
        onDismissRequest = { discard = false }, title = { Text("Discard this draft?") },
        text = { Text("Its text and attachments will be removed from this device.") },
        confirmButton = { TextButton(onClick = {
            discard = false
            onDiscard()
        }) { Text("Discard") } },
        dismissButton = { TextButton(onClick = { discard = false }) { Text("Keep draft") } },
    )
    preview?.let { part ->
        val bitmap = rememberAttachmentBitmap(part, maxDimension = 1200)
        AlertDialog(onDismissRequest = { preview = null }, title = { Text(part.filename) },
            text = { Column { if (bitmap != null) Image(bitmap, part.filename, Modifier.fillMaxWidth().heightIn(max = 450.dp)); Text(Attachments.details(part)) } },
            confirmButton = { TextButton(onClick = { preview = null }) { Text("Close preview") } })
    }
}

@Composable
internal fun TaskCaptureHost(state: DieterUiState, model: DieterViewModel, store: TaskCaptureStore) {
    val captures by store.view.collectAsState()
    var pendingShare by remember { mutableStateOf<TaskDraftEditor?>(null) }
    var discardSaved by remember { mutableStateOf<CaptureDraft?>(null) }
    var restoredAccount by remember { mutableStateOf<String?>(null) }
    store.error?.let { message ->
        AlertDialog(onDismissRequest = store::clearError, title = { Text("Could not capture task") },
            text = { Text(message) }, confirmButton = { TextButton(onClick = store::clearError) { Text("Close") } })
    }
    val incoming = store.incoming
    LaunchedEffect(state.activeGatewayId, state.projects.isNotEmpty(), captures.bound) {
        if (restoredAccount != state.activeGatewayId && state.projects.isNotEmpty() && captures.bound) {
            restoredAccount = state.activeGatewayId
            if (incoming == null && model.activeCapture == null) store.latest()?.let(model::beginCapture)
        }
    }
    LaunchedEffect(incoming?.id) {
        incoming ?: return@LaunchedEffect
        if (TaskDrafts.asksToMerge(model.activeCapture?.state?.value, incoming.state.value)) pendingShare = incoming
        else model.beginCapture(incoming)
        store.consumeIncoming()
    }
    pendingShare?.let { share ->
        val shareDraft by share.state.collectAsState()
        val openDraft = model.activeCapture?.state?.collectAsState()?.value
        AlertDialog(onDismissRequest = { pendingShare = null }, title = { Text("Shared content received") },
            text = { Text("Keep your existing draft or add this content to it.") },
            confirmButton = { TextButton(enabled = !shareDraft.importing && openDraft?.frozen == false, onClick = {
                val current = model.activeCapture ?: return@TextButton
                val problem = TaskDrafts.mergeProblem(current.state.value, shareDraft)
                current.edit { TaskDrafts.merge(it, shareDraft) }
                // The share is dropped only once its content is part of the open draft.
                if (problem == null) store.discard(share.id)
                pendingShare = null
            }) { Text("Add to current draft") } },
            dismissButton = { TextButton(onClick = { model.beginCapture(share); pendingShare = null }) { Text("Keep draft and start new") } })
    }
    discardSaved?.let { saved ->
        AlertDialog(onDismissRequest = { discardSaved = null }, title = { Text("Discard saved draft?") },
            text = { Text("Its text and attachments will be removed from this device.") },
            confirmButton = { TextButton(onClick = { store.discard(saved.id); discardSaved = null }) { Text("Discard") } },
            dismissButton = { TextButton(onClick = { discardSaved = null }) { Text("Keep draft") } })
    }
    if (!model.captureChooserVisible) return
    val editor = model.activeCapture ?: return
    val draft by editor.state.collectAsState()
    val scope = rememberCoroutineScope()
    CaptureDestinationSheet(
        state = state,
        draft = draft,
        savedDrafts = captures.drafts.filter { it.id != draft.id && it.hasContent },
        onDismiss = { model.captureChooserVisible = false },
        onProject = model::captureProject,
        onBoard = model::openCaptureBoard,
        onResumeDraft = { saved ->
            scope.launch {
                model.beginCapture(store.editor(saved.id))
                if (saved.project_id.isNotBlank()) model.selectProject(saved.project_id)
            }
        },
        onDiscardDraft = { discardSaved = it },
    )
}
