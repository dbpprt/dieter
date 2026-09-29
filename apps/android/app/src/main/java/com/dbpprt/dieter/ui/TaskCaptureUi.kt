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
import kotlinx.coroutines.launch

@Composable
internal fun TaskAttachmentControls(draft: CardCreationDraft, store: TaskCaptureStore?, onDiscard: () -> Unit = {}) {
    var replacing by remember { mutableStateOf<TaskImportFailure?>(null) }
    var picker by remember { mutableStateOf(false) }
    var discard by remember { mutableStateOf(false) }
    var preview by remember { mutableStateOf<com.dbpprt.dieter.v1.MessagePart?>(null) }
    val scope = rememberCoroutineScope()
    val photos = rememberLauncherForActivityResult(ActivityResultContracts.PickMultipleVisualMedia(MAX_COMPOSER_ATTACHMENTS)) {
        if (it.isNotEmpty()) { replacing?.let(draft.importFailures::remove); store?.import(draft, it, imagesOnly = true) }
        replacing = null
    }
    val files = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) {
        if (it.isNotEmpty()) { replacing?.let(draft.importFailures::remove); store?.import(draft, it) }
        replacing = null
    }
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        TextButton(onClick = { replacing = null; picker = true }, enabled = !draft.importing && draft.submissionId.isBlank(), modifier = Modifier.testTag("create-attach")) {
            Text("Add images or files")
        }
        if (draft.importing) {
            LinearProgressIndicator(Modifier.fillMaxWidth())
            Text("Importing attachments…")
            TextButton(onClick = { store?.cancelImport(draft) }) { Text("Cancel import") }
        }
        Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            draft.attachments.forEachIndexed { index, part ->
                Column {
                    ComposerAttachmentPreview(part, index, !draft.importing && draft.submissionId.isBlank()) { draft.attachments.removeAt(index) }
                    TextButton(onClick = { preview = part }) { Text("Preview ${part.filename}") }
                }
            }
        }
        draft.importFailures.toList().forEach { failure ->
            Text(failure.message, color = MaterialTheme.colorScheme.error)
            FlowRow {
                TextButton(onClick = { store?.retry(draft, failure) }, enabled = !draft.importing && failure.uri.isNotBlank()) { Text("Retry import") }
                TextButton(onClick = { replacing = failure; picker = true }, enabled = !draft.importing) { Text("Choose again") }
                TextButton(onClick = { draft.importFailures.remove(failure) }, enabled = !draft.importing) { Text("Remove failed attachment") }
            }
        }
        draft.persistenceError?.let {
            Text(it, color = MaterialTheme.colorScheme.error)
            TextButton(onClick = { scope.launch { runCatching { store?.flush(draft) } } }) { Text("Retry saving draft") }
        }
        Text("Up to 4 attachments · 5 MiB each · 6 MiB total", style = MaterialTheme.typography.bodySmall)
        if (draft.submissionId.isNotBlank()) Text("Submission pending. Retry Save with the same task; attachments are retained.")
        if (draft.hasContent && draft.submissionId.isBlank()) TextButton(onClick = { discard = true }) { Text("Discard draft") }
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
            text = { Column { if (bitmap != null) Image(bitmap, part.filename, Modifier.fillMaxWidth().heightIn(max = 450.dp)); Text(attachmentDetails(part)) } },
            confirmButton = { TextButton(onClick = { preview = null }) { Text("Close preview") } })
    }
}

@Composable
internal fun TaskCaptureHost(state: DieterUiState, model: DieterViewModel, store: TaskCaptureStore) {
    val scope = rememberCoroutineScope()
    var pendingShare by remember { mutableStateOf<CardCreationDraft?>(null) }
    var discardSaved by remember { mutableStateOf<CardCreationDraft?>(null) }
    var restoredAccount by remember { mutableStateOf<String?>(null) }
    store.error?.let { message ->
        AlertDialog(onDismissRequest = store::clearError, title = { Text("Could not capture task") },
            text = { Text(message) }, confirmButton = { TextButton(onClick = store::clearError) { Text("Close") } })
    }
    val incoming = store.incoming
    LaunchedEffect(state.activeGatewayId, state.projects.isNotEmpty()) {
        if (restoredAccount != state.activeGatewayId && state.projects.isNotEmpty()) {
            restoredAccount = state.activeGatewayId
            if (incoming == null && model.activeCapture == null) {
                store.drafts.lastOrNull { it.accountId == state.activeGatewayId && it.hasContent }?.let(model::beginCapture)
            }
        }
    }
    LaunchedEffect(incoming?.id) {
        incoming ?: return@LaunchedEffect
        val current = model.activeCapture
        if (current != null && current !== incoming && current.hasContent) pendingShare = incoming
        else model.beginCapture(incoming)
        store.consumeIncoming()
    }
    pendingShare?.let { share ->
        AlertDialog(onDismissRequest = { pendingShare = null }, title = { Text("Shared content received") },
            text = { Text("Keep your existing draft or add this content to it.") },
            confirmButton = { TextButton(enabled = !share.importing && model.activeCapture?.submissionId.isNullOrBlank(), onClick = {
                val current = model.activeCapture ?: return@TextButton
                val limit = attachmentLimitError(current.attachments, share.attachments)
                if (limit != null) current.importFailures += TaskImportFailure("", limit)
                else {
                    current.prompt = listOf(current.prompt, share.prompt).filter(String::isNotBlank).joinToString("\n")
                    current.attachments.addAll(share.attachments); current.importFailures.addAll(share.importFailures)
                    scope.launch { runCatching { store.flush(current) }.onSuccess { store.discard(share) }.onFailure { current.persistenceError = it.message } }
                }
                pendingShare = null
            }) { Text("Add to current draft") } },
            dismissButton = { TextButton(onClick = { model.beginCapture(share); pendingShare = null }) { Text("Keep draft and start new") } })
    }
    discardSaved?.let { saved ->
        AlertDialog(onDismissRequest = { discardSaved = null }, title = { Text("Discard saved draft?") },
            text = { Text("Its text and attachments will be removed from this device.") },
            confirmButton = { TextButton(onClick = { store.discard(saved); discardSaved = null }) { Text("Discard") } },
            dismissButton = { TextButton(onClick = { discardSaved = null }) { Text("Keep draft") } })
    }
    if (!model.captureChooserVisible) return
    val draft = model.activeCapture ?: return
    CaptureDestinationSheet(
        state = state,
        draft = draft,
        savedDrafts = store.drafts.filter { it !== draft && it.accountId == state.activeGatewayId && it.hasContent },
        onDismiss = { model.captureChooserVisible = false },
        onProject = model::captureProject,
        onBoard = model::openCaptureBoard,
        onResumeDraft = { saved -> model.beginCapture(saved); if (saved.projectId.isNotBlank()) model.selectProject(saved.projectId) },
        onDiscardDraft = { discardSaved = it },
    )
}
