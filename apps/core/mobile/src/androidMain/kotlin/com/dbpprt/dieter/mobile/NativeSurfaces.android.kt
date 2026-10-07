package com.dbpprt.dieter.mobile

import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import com.dbpprt.dieter.core.terminals.TerminalScreen
import com.dbpprt.dieter.ui.RemoteTerminalView
import kotlinx.coroutines.launch

@Composable
internal actual fun NativeTerminal(store: MobileStore, modifier: Modifier) {
    val selected by store.visibleTerminal.collectAsState()
    val inputEnabled by store.terminalAcceptsInput.collectAsState()
    val screens by store.terminalScreens.collectAsState()
    val palette by store.palette.collectAsState()
    key(selected, palette) {
        var terminal by remember { mutableStateOf<RemoteTerminalView?>(null) }
        LaunchedEffect(selected, palette) { store.terminalKeys.collect { terminal?.sendKey(it) } }
        AndroidView(
            modifier = modifier,
            factory = { context ->
                RemoteTerminalView(context, palette).apply {
                    onResize = store::terminalGrid
                    terminal = this
                }
            },
            update = {
                it.onInput = { bytes -> if (inputEnabled) store.terminalInput(bytes) }
                it.applyScreen(screens[selected] ?: TerminalScreen.EMPTY)
            },
        )
    }
}

interface AndroidScreenSurface {
    val view: android.view.View

    fun control(action: String)

    fun update(value: com.dbpprt.dieter.client.v1.ScreenSlice)

    fun close()
}

object AndroidNativeViews {
    var screen: ((android.content.Context, MobileStore) -> AndroidScreenSurface)? = null
}

@Composable
internal actual fun NativeScreenCanvas(store: MobileStore, modifier: Modifier) {
    val slice by store.screen.collectAsState()
    val context = androidx.compose.ui.platform.LocalContext.current
    val surface =
        remember(store) {
            checkNotNull(AndroidNativeViews.screen) { "Screen renderer is not installed" }(
                context,
                store,
            )
        }
    AndroidView(factory = { surface.view }, modifier = modifier, update = { surface.update(slice) })
    LaunchedEffect(surface) { store.canvasActions.collect { surface.control(it) } }
    DisposableEffect(surface) { onDispose { surface.close() } }
}

@Composable
internal actual fun rememberAttachmentPicker(
    onPicked: (List<com.dbpprt.dieter.api.v1.MessagePart>) -> Unit,
    onError: (String) -> Unit,
): () -> Unit {
    val context = androidx.compose.ui.platform.LocalContext.current
    val scope = rememberCoroutineScope()
    val receiver by rememberUpdatedState(onPicked)
    val failure by rememberUpdatedState(onError)
    var choosing by remember { mutableStateOf(false) }
    fun picked(uris: List<android.net.Uri>, images: Boolean) {
        scope.launch {
            try {
                require(uris.size <= com.dbpprt.dieter.core.composition.Attachments.MAX_COUNT) {
                    com.dbpprt.dieter.core.composition.Attachments.TOO_MANY
                }
                val parts =
                    kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
                        uris.map { com.dbpprt.dieter.ui.readAttachmentPart(context, it, images) }
                    }
                receiver(parts)
            } catch (cancelled: kotlinx.coroutines.CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                failure(error.message ?: "Could not read the attachment")
            }
        }
    }
    val launcher =
        androidx.activity.compose.rememberLauncherForActivityResult(
            androidx.activity.result.contract.ActivityResultContracts.OpenMultipleDocuments()
        ) { uris ->
            picked(uris, false)
        }
    val photos =
        androidx.activity.compose.rememberLauncherForActivityResult(
            androidx.activity.result.contract.ActivityResultContracts.PickMultipleVisualMedia(4)
        ) { uris ->
            picked(uris, true)
        }
    if (choosing)
        AlertDialog(
            onDismissRequest = { choosing = false },
            title = { Text("Attach images or files") },
            text = {
                Column {
                    TextButton(
                        onClick = {
                            choosing = false
                            photos.launch(
                                androidx.activity.result.PickVisualMediaRequest(
                                    androidx.activity.result.contract.ActivityResultContracts
                                        .PickVisualMedia
                                        .ImageOnly
                                )
                            )
                        }
                    ) {
                        Text("Photo library")
                    }
                    TextButton(
                        onClick = {
                            choosing = false
                            launcher.launch(arrayOf("*/*"))
                        }
                    ) {
                        Text("Choose files")
                    }
                }
            },
            confirmButton = { TextButton(onClick = { choosing = false }) { Text("Cancel") } },
        )
    return { choosing = true }
}

@Composable
internal actual fun rememberAttachmentViewer(
    onError: (String) -> Unit
): (com.dbpprt.dieter.api.v1.MessagePart) -> Unit {
    val context = androidx.compose.ui.platform.LocalContext.current
    val scope = rememberCoroutineScope()
    var preview by remember { mutableStateOf<com.dbpprt.dieter.api.v1.MessagePart?>(null) }
    var bitmap by remember { mutableStateOf<android.graphics.Bitmap?>(null) }
    LaunchedEffect(preview) {
        bitmap = null
        preview?.let { part ->
            bitmap =
                kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
                    com.dbpprt.dieter.ui.decodeAttachmentBitmap(part, 1600)
                }
            if (bitmap == null) onError("Could not decode this image.")
        }
    }
    preview?.let { part ->
        AlertDialog(
            onDismissRequest = { preview = null },
            title = { Text(part.filename.ifEmpty { "Image" }) },
            text = {
                Column {
                    bitmap?.let {
                        Image(
                            it.asImageBitmap(),
                            part.filename,
                            Modifier.fillMaxWidth().heightIn(max = 450.dp),
                        )
                    }
                    Text(com.dbpprt.dieter.core.composition.Attachments.details(part))
                }
            },
            confirmButton = { TextButton(onClick = { preview = null }) { Text("Close preview") } },
        )
    }
    return { part ->
        if (com.dbpprt.dieter.core.files.FilePaths.isImage(part.filename, part.media_type))
            preview = part
        else
            scope.launch {
                try {
                    val file =
                        kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
                            val bytes =
                                if (part.data_.size > 0) part.data_.toByteArray()
                                else
                                    java.util.Base64.getDecoder()
                                        .decode(part.url.substringAfter(";base64,"))
                            require(
                                bytes.size <=
                                    com.dbpprt.dieter.core.composition.Attachments.MAX_TOTAL_BYTES
                            ) {
                                "Attachment is too large to preview"
                            }
                            val directory =
                                java.io.File(context.filesDir, "clipboard/preview").apply {
                                    mkdirs()
                                }
                            directory.listFiles()?.forEach { it.delete() }
                            java.io
                                .File(
                                    directory,
                                    com.dbpprt.dieter.core.composition.Attachments.filename(
                                        part.filename,
                                        part.media_type,
                                    ),
                                )
                                .apply { writeBytes(bytes) }
                        }
                    val uri =
                        androidx.core.content.FileProvider.getUriForFile(
                            context,
                            "${context.packageName}.clipboard",
                            file,
                        )
                    context.startActivity(
                        android.content
                            .Intent(android.content.Intent.ACTION_VIEW)
                            .setDataAndType(uri, part.media_type)
                            .addFlags(android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    )
                } catch (cancelled: kotlinx.coroutines.CancellationException) {
                    throw cancelled
                } catch (error: Throwable) {
                    onError(error.message ?: "No viewer is available for this file")
                }
            }
    }
}
