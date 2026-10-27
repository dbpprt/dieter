package com.getdieter.mobile.platform

import androidx.compose.foundation.layout.*
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.getdieter.mobile.design.*
import com.getdieter.mobile.resources.Res
import kotlinx.coroutines.delay
import kotlinx.serialization.json.JsonPrimitive

/** Loaded once from the app, never from the sender's checkout or the network. */
internal object DiagramAssets {
    private var cached: Map<String, ByteArray>? = null

    suspend fun load(): Map<String, ByteArray> =
        cached
            ?: listOf("index.html", "app.js", "app.css")
                .associateWith { Res.readBytes("files/markdown-preview/$it") }
                .also { cached = it }
}

internal fun diagramScript(kind: String, source: String, dark: Boolean): String =
    "window.dieterMarkdown.renderDiagram(${JsonPrimitive(kind)},${JsonPrimitive(source)},${JsonPrimitive(if (dark) "dark" else "light")},'mail',true).then(r => JSON.stringify({height:r.height,error:r.error,stale:r.stale,rendered:r.renderedBlocks}))"

/** Native views are keyed by source/theme: old completion callbacks cannot update another block. */
@Composable
internal fun MarkdownDiagram(
    kind: String,
    source: String,
    dark: Boolean,
    fenceLanguage: String,
    fallback: @Composable () -> Unit,
) {
    key(kind, source, dark) {
        var assets by remember { mutableStateOf<Map<String, ByteArray>?>(null) }
        var error by remember { mutableStateOf<String?>(null) }
        var height by remember { mutableStateOf(180.dp) }
        var ready by remember { mutableStateOf(false) }
        LaunchedEffect(Unit) {
            try {
                assets = DiagramAssets.load()
            } catch (_: Exception) {
                error = "The offline diagram renderer is unavailable."
            }
        }
        LaunchedEffect(Unit) {
            delay(15000)
            if (!ready && error == null) error = "The diagram renderer timed out."
        }
        val loaded = assets
        Column(Modifier.fillMaxWidth()) {
            if (error == null && loaded != null) {
                Box(
                    Modifier.fillMaxWidth()
                        .height(height)
                        .testTag(
                            if (ready) "mail-diagram-${fenceLanguage.lowercase()}-rendered"
                            else "mail-diagram-loading"
                        )
                ) {
                    NativeMarkdownDiagram(
                        loaded,
                        diagramScript(kind, source, dark),
                        Modifier.fillMaxSize(),
                        onResult = { measured, failure ->
                            if (failure != null) error = failure
                            else if (measured.isFinite() && measured > 0 && measured <= 16000) {
                                height = measured.dp
                                ready = true
                            } else error = "The diagram has unsupported dimensions."
                        },
                    )
                }
            }
            if (error != null) {
                Text(
                    error.orEmpty(),
                    Modifier.testTag("mail-diagram-error"),
                    style = type.footnote,
                    color = palette.secondaryLabel,
                )
                fallback()
            }
        }
    }
}

@Composable
internal expect fun NativeMarkdownDiagram(
    assets: Map<String, ByteArray>,
    script: String,
    modifier: Modifier,
    onResult: (Double, String?) -> Unit,
)
