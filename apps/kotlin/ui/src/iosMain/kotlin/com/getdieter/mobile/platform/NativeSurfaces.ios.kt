@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package com.getdieter.mobile.platform

import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.viewinterop.UIKitView
import com.getdieter.client.v1.*
import com.getdieter.core.terminals.*
import com.getdieter.mobile.app.*
import com.getdieter.mobile.store.*
import platform.Foundation.NSData
import platform.UIKit.UIView
import platform.UIKit.UIViewController

interface MobileTerminalInput {
    fun send(data: NSData)

    fun resize(columns: Int, rows: Int)
}

interface MobileTerminalSurface {
    val view: UIView

    fun key(value: Int)

    fun reset()

    fun feed(data: NSData)

    fun setInputEnabled(enabled: Boolean)

    fun close()
}

interface MobileScreenInput {
    fun send(command: NSData)
}

interface MobileScreenSurface {
    val view: UIView

    fun control(action: String)

    fun update(slice: NSData)

    fun close()
}

interface MobileNativeViews {
    fun pickAttachments(receiver: MobileAttachmentReceiver)

    fun previewAttachment(part: NSData)

    fun terminal(input: MobileTerminalInput): MobileTerminalSurface

    fun screen(scope: String, input: MobileScreenInput): MobileScreenSurface

    /** Shows native choices anchored to a rectangle in [view]'s window (points). */
    fun showMenu(
        sections: List<NativeMenuSection>,
        view: UIView,
        x: Double,
        y: Double,
        width: Double,
        height: Double,
    )

    fun confirm(
        title: String,
        message: String,
        confirm: String,
        destructive: Boolean,
        view: UIView,
        result: NativeChoice,
    )

    fun prompt(
        title: String,
        message: String,
        value: String,
        placeholder: String,
        confirm: String,
        view: UIView,
        result: NativeText,
    )

    /** Presents [content] in a sheet; the returned handle owns its navigation item. */
    fun presentSheet(
        content: UIViewController,
        medium: Boolean,
        from: UIView,
        dismissed: NativeChoice,
    ): NativeSheet

    fun showToast(message: String)

    /** Presents the share sheet with [text] (Markdown), titled [subject]. */
    fun shareText(subject: String, text: String)
}

interface NativeChoice {
    fun chose(confirmed: Boolean)
}

interface NativeText {
    /** Null when cancelled. */
    fun entered(text: String?)
}

interface NativeSheet {
    val chrome: NativeChromeSink

    fun close()
}

internal object AppleNativeViews {
    var factory: MobileNativeViews? = null
}

@Composable
internal actual fun NativeTerminal(store: MobileStore, modifier: Modifier) {
    val selected by store.terminals.visible.collectAsState()
    val inputEnabled by store.terminals.acceptsInput.collectAsState()
    val screens by store.terminals.screens.collectAsState()
    key(selected) {
        val surface = remember {
            checkNotNull(AppleNativeViews.factory)
                .terminal(
                    object : MobileTerminalInput {
                        override fun send(data: NSData) {
                            store.terminals.input(data.bytesArray())
                        }

                        override fun resize(columns: Int, rows: Int) {
                            store.terminals.grid(columns, rows)
                        }
                    }
                )
        }
        LaunchedEffect(surface) { store.terminals.keys.collect { surface.key(it.value) } }
        val cursor = remember { TerminalReplayCursor() }
        val sink = remember {
            object : TerminalRendererSink {
                override fun reset() = surface.reset()

                override fun feed(bytes: ByteArray) = surface.feed(bytes.data())

                override fun redraw() = Unit
            }
        }
        UIKitView(
            factory = { surface.view },
            modifier = modifier,
            update = {
                surface.setInputEnabled(inputEnabled)
                cursor.apply(screens[selected] ?: TerminalScreen.EMPTY, sink)
            },
        )
        DisposableEffect(surface) { onDispose { surface.close() } }
    }
}

@Composable
internal actual fun NativeScreenCanvas(store: MobileStore, modifier: Modifier) {
    val slice by store.screens.slice.collectAsState()
    val surface = remember {
        checkNotNull(AppleNativeViews.factory)
            .screen(
                MobileStore.SCREEN_SCOPE,
                object : MobileScreenInput {
                    override fun send(command: NSData) {
                        store.screens.input(ScreenCommand.ADAPTER.decode(command.bytesArray()))
                    }
                },
            )
    }
    UIKitView(
        factory = { surface.view },
        modifier = modifier,
        update = { surface.update(slice.encode().data()) },
    )
    LaunchedEffect(surface) { store.screens.canvasActions.collect { surface.control(it) } }
    DisposableEffect(surface) { onDispose { surface.close() } }
}

interface MobileAttachmentReceiver {
    fun picked(message: NSData)

    fun failed(message: String)
}

@Composable
internal actual fun rememberAttachmentPicker(
    onPicked: (List<com.getdieter.api.v1.MessagePart>) -> Unit,
    onError: (String) -> Unit,
): () -> Unit {
    val receive by rememberUpdatedState(onPicked)
    val failure by rememberUpdatedState(onError)
    return {
        checkNotNull(AppleNativeViews.factory)
            .pickAttachments(
                object : MobileAttachmentReceiver {
                    override fun picked(message: NSData) {
                        receive(
                            com.getdieter.api.v1.UiMessage.ADAPTER.decode(message.bytesArray())
                                .parts
                        )
                    }

                    override fun failed(message: String) {
                        failure(message)
                    }
                }
            )
    }
}

@Composable
internal actual fun rememberAttachmentViewer(
    onError: (String) -> Unit
): (com.getdieter.api.v1.MessagePart) -> Unit = { part ->
    checkNotNull(AppleNativeViews.factory).previewAttachment(part.encode().data())
}

@Composable
internal actual fun rememberTextSharer(): (subject: String, text: String) -> Unit =
    { subject, text ->
        checkNotNull(AppleNativeViews.factory).shareText(subject, text)
    }
