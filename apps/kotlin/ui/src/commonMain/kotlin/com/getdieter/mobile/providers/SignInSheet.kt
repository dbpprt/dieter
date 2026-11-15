package com.getdieter.mobile.providers

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.getdieter.client.v1.*
import com.getdieter.core.client.rules.ProviderExports
import com.getdieter.mobile.design.*
import com.getdieter.mobile.store.*
import kotlin.time.Clock
import kotlinx.coroutines.delay

private val finished = setOf("succeeded", "failed", "canceled")

/**
 * A provider sign-in this device follows, as a sheet. Closing it drops the session from the core; a
 * live one is canceled.
 */
@Composable
internal fun SignInSheet(
    store: MobileStore,
    sessionId: String,
    openUrl: (String) -> Unit,
    onClose: () -> Unit,
) {
    val slice = rememberProviders(store)
    var shown by remember { mutableStateOf(sessionId) }
    val session = slice.sessions.firstOrNull { it.id == shown }
    fun close() {
        store.providers.dismiss(shown)
        onClose()
    }
    Sheet(session?.title?.ifEmpty { null } ?: "Sign In", ::close) {
        SignInSteps(store, session, openUrl, onDone = ::close) { next ->
            store.providers.dismiss(shown)
            shown = next
        }
    }
}

/**
 * The steps of a sign-in [session] (null while it starts): open the provider's page, then the code
 * the page shows, the device code to enter there, or the address the browser could not open; then
 * progress and the outcome. [onRestart] gets a new session after "Try again".
 */
@Composable
internal fun SignInSteps(
    store: MobileStore,
    session: ProviderSignInSession?,
    openUrl: (String) -> Unit,
    onDone: () -> Unit,
    onRestart: (String) -> Unit,
) {
    val busy by store.busy.collectAsState()
    FormColumn {
        if (session == null) {
            Box(Modifier.fillMaxWidth().padding(24.dp), contentAlignment = Alignment.Center) {
                Spinner()
            }
            return@FormColumn
        }
        val phase = session.phase
        when (phase) {
            "succeeded" -> Outcome(Glyph.CHECK_CIRCLE, palette.success, session.instructions)
            "failed" -> Outcome(Glyph.ERROR, palette.destructive, session.instructions)
            "canceled" -> Outcome(Glyph.CANCEL, palette.secondaryLabel, session.instructions)
            "waiting" ->
                Text(
                    session.instructions,
                    Modifier.testTag("signin-instructions"),
                    style = type.body,
                    color = palette.label,
                )
            else ->
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Spinner()
                    Spacer(Modifier.width(12.dp))
                    Text(
                        session.instructions,
                        Modifier.testTag("signin-instructions"),
                        style = type.body,
                        color = palette.label,
                    )
                }
        }
        if (session.remaining_machines > 0 && phase != "failed" && phase != "canceled")
            Text(
                if (session.remaining_machines == 1) "Then one more machine"
                else "Then ${session.remaining_machines} more machines",
                style = type.footnote,
                color = palette.secondaryLabel,
            )
        if (phase == "waiting") {
            // The signing machine's loopback address only completes in a browser on that machine.
            val page =
                if (session.same_host && session.local_url.isNotEmpty()) session.local_url
                else session.open_url
            if (page.isNotEmpty())
                DButton(
                    "Open sign-in page",
                    { openUrl(page) },
                    Modifier.fillMaxWidth().testTag("signin-open"),
                    kind =
                        if (session.expects == "code") ButtonKind.TONAL else ButtonKind.PROMINENT,
                    glyph = Glyph.OPEN,
                )
            when (session.expects) {
                "code" -> {
                    PastedInput(
                        "Code",
                        "Paste the code",
                        "signin-code",
                        "signin-submit",
                        busy,
                        monospace = true,
                    ) {
                        store.providers.submitCode(session.id, it)
                    }
                    var address by remember(session.id) { mutableStateOf(false) }
                    if (!address)
                        DButton(
                            "Paste an address instead",
                            { address = true },
                            Modifier.testTag("signin-address"),
                            kind = ButtonKind.PLAIN,
                        )
                    else
                        PastedInput(
                            "Address",
                            "Paste the address your browser couldn't open",
                            "signin-callback",
                            "signin-callback-submit",
                            busy,
                        ) {
                            store.providers.submitCallback(session.id, it)
                        }
                }
                "none" -> DeviceCode(session)
                "callback" ->
                    if (!session.same_host)
                        PastedInput(
                            "Address",
                            "Paste the address your browser couldn't open",
                            "signin-callback",
                            "signin-submit",
                            busy,
                        ) {
                            store.providers.submitCallback(session.id, it)
                        }
            }
        }
        Spacer(Modifier.height(4.dp))
        when (phase) {
            in finished -> {
                if (phase != "succeeded")
                    DButton(
                        "Try again",
                        {
                            store.providers.signIn(session.account_id, session.daemon_id) {
                                onRestart(it)
                            }
                        },
                        Modifier.fillMaxWidth().testTag("signin-retry"),
                        kind = ButtonKind.TONAL,
                        enabled = !busy,
                    )
                DButton(
                    "Done",
                    onDone,
                    Modifier.fillMaxWidth().testTag("signin-done"),
                    kind = if (phase == "succeeded") ButtonKind.PROMINENT else ButtonKind.PLAIN,
                )
            }
            else ->
                DButton(
                    "Cancel",
                    { store.providers.cancel(session.id) },
                    Modifier.fillMaxWidth().testTag("signin-cancel"),
                    kind = ButtonKind.PLAIN,
                )
        }
    }
}

@Composable
private fun Outcome(glyph: Glyph, tint: androidx.compose.ui.graphics.Color, text: String) {
    Row(Modifier.testTag("signin-outcome"), verticalAlignment = Alignment.CenterVertically) {
        Icon(glyph, null, tint = tint, size = 24.dp)
        Spacer(Modifier.width(12.dp))
        Text(text, style = type.body, color = palette.label)
    }
}

/** A field for what the provider's page shows, and its Continue button. */
@Composable
private fun PastedInput(
    label: String,
    placeholder: String,
    fieldTag: String,
    submitTag: String,
    busy: Boolean,
    monospace: Boolean = false,
    submit: (String) -> Unit,
) {
    var value by remember { mutableStateOf("") }
    val ready = value.isNotBlank() && !busy
    MobileTextField(
        value,
        { value = it },
        Modifier.fillMaxWidth().testTag(fieldTag),
        textStyle = if (monospace) type.body.copy(fontFamily = FontFamily.Monospace) else type.body,
        label = { Text(label) },
        placeholder = { Text(placeholder) },
        singleLine = true,
        keyboardOptions =
            KeyboardOptions(
                autoCorrectEnabled = false,
                keyboardType = if (monospace) KeyboardType.Ascii else KeyboardType.Uri,
                imeAction = ImeAction.Done,
            ),
        keyboardActions = KeyboardActions(onDone = { if (ready) submit(value) }),
    )
    DButton(
        "Continue",
        { submit(value) },
        Modifier.fillMaxWidth().testTag(submitTag),
        enabled = ready,
        loading = busy && value.isNotBlank(),
    )
}

/** The device code to enter on the provider's page, with Copy and its expiry. */
@Composable
private fun DeviceCode(session: ProviderSignInSession) {
    val clipboard = LocalClipboardManager.current
    val code = ProviderExports.deviceCode(session.user_code)
    var now by remember { mutableStateOf(Clock.System.now().toEpochMilliseconds()) }
    LaunchedEffect(session.expires_at) {
        while (true) {
            now = Clock.System.now().toEpochMilliseconds()
            delay(1_000)
        }
    }
    val expiry = ProviderExports.codeExpiry(session.expires_at, now)
    Column(
        Modifier.fillMaxWidth()
            .clip(RoundedCornerShape(if (apple) 18.dp else 16.dp))
            .background(if (apple) palette.cell else colors.surfaceContainerHigh)
            .padding(horizontal = 16.dp, vertical = 18.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        SelectionContainer {
            Text(
                code,
                Modifier.testTag("signin-user-code"),
                style =
                    type.title1.copy(
                        fontFamily = FontFamily.Monospace,
                        fontWeight = FontWeight.SemiBold,
                    ),
                color = palette.label,
                textAlign = TextAlign.Center,
            )
        }
        if (expiry.isNotEmpty()) {
            Spacer(Modifier.height(6.dp))
            Text(expiry, style = type.footnote, color = palette.secondaryLabel)
        }
        Spacer(Modifier.height(6.dp))
        DButton(
            "Copy",
            { clipboard.setText(AnnotatedString(code)) },
            Modifier.testTag("signin-copy-code"),
            kind = ButtonKind.PLAIN,
            glyph = Glyph.COPY,
        )
    }
    Row(verticalAlignment = Alignment.CenterVertically) {
        Spinner(Modifier.size(16.dp))
        Spacer(Modifier.width(10.dp))
        Text(
            "Waiting for you to approve the code…",
            style = type.footnote,
            color = palette.secondaryLabel,
        )
    }
}
