package com.getdieter.mobile.providers

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.unit.dp
import com.getdieter.mobile.app.*
import com.getdieter.mobile.design.*
import com.getdieter.mobile.store.*
import kotlinx.coroutines.delay

private val providers = listOf("claude" to "Claude", "chatgpt" to "ChatGPT")
private val chatGptMethods = listOf("codex" to "Codex sign-in", "siwc" to "Continue with ChatGPT")

/**
 * Adds a Claude or ChatGPT account, then signs it in on the chosen machine in the same sheet.
 * Without an online machine the account is only added; it signs in later from its page.
 */
@Composable
internal fun AddAccountSheet(store: MobileStore, openUrl: (String) -> Unit, onClose: () -> Unit) {
    val session by store.session.slice.collectAsState()
    val busy by store.busy.collectAsState()
    val slice = rememberProviders(store)
    var provider by rememberSaveable { mutableStateOf("claude") }
    var label by rememberSaveable { mutableStateOf("") }
    var method by rememberSaveable { mutableStateOf("codex") }
    var machine by rememberSaveable { mutableStateOf("") }
    // The added account, then its sign-in session.
    var created by rememberSaveable { mutableStateOf("") }
    var signing by rememberSaveable { mutableStateOf("") }
    var adding by remember { mutableStateOf(false) }
    var problem by remember { mutableStateOf("") }
    val machines = session.machines.filter { it.online }
    val target =
        machine.takeIf { id -> machines.any { it.id == id } }
            ?: machines.firstOrNull { it.available }?.id
            ?: machines.firstOrNull()?.id.orEmpty()
    fun close() {
        if (signing.isNotEmpty()) store.providers.dismiss(signing)
        onClose()
    }
    // A machine signs in only accounts it knows, so the sign-in waits until the new account
    // reached this device's replica; one that never shows is left to sign in from its page.
    val known =
        created.isNotEmpty() && slice.groups.any { g -> g.accounts.any { it.id == created } }
    LaunchedEffect(created, known) {
        if (created.isEmpty() || signing.isNotEmpty()) return@LaunchedEffect
        if (!known) {
            delay(20_000)
            onClose()
            return@LaunchedEffect
        }
        store.providers.signIn(created, target, failed = { onClose() }) { signing = it }
    }
    val current = slice.sessions.firstOrNull { it.id == signing }
    val started = adding || created.isNotEmpty()
    Sheet(
        if (!started) "Add Account" else current?.title?.ifEmpty { null } ?: "Sign In",
        ::close,
        confirm =
            if (started) null
            else
                ChromeAction(
                    "add-account",
                    if (target.isEmpty()) "Add" else "Continue",
                    Glyph.CHECK,
                    enabled = label.isNotBlank() && !busy,
                ) {
                    adding = true
                    problem = ""
                    store.providers.create(
                        provider,
                        label,
                        if (provider == "chatgpt") method else "",
                        failed = {
                            adding = false
                            problem = it
                        },
                    ) { account ->
                        if (target.isEmpty()) onClose() else created = account
                    }
                },
    ) {
        if (started) {
            SignInSteps(store, current, openUrl, onDone = ::close) { next ->
                store.providers.dismiss(signing)
                signing = next
            }
            return@Sheet
        }
        FormColumn {
            Segmented(
                providers.map { it.second },
                providers.indexOfFirst { it.first == provider }.coerceAtLeast(0),
                { provider = providers[it].first },
                testTagPrefix = "provider-kind",
            )
            MobileTextField(
                label,
                { label = it },
                Modifier.fillMaxWidth().testTag("provider-label"),
                label = { Text("Name") },
                placeholder = { Text(if (provider == "claude") "Work" else "Personal") },
                supportingText = { Text("Your name for the account, e.g. Work or Personal.") },
                singleLine = true,
                keyboardOptions =
                    KeyboardOptions(
                        capitalization = KeyboardCapitalization.Words,
                        imeAction = ImeAction.Done,
                    ),
            )
            if (provider == "chatgpt") {
                FormLabel("Sign in with")
                Segmented(
                    chatGptMethods.map { it.second },
                    chatGptMethods.indexOfFirst { it.first == method }.coerceAtLeast(0),
                    { method = chatGptMethods[it].first },
                    testTagPrefix = "provider-method",
                )
            }
        }
        if (machines.isNotEmpty())
            PickerRow(
                "Sign in on",
                machines.firstOrNull { it.id == target }?.display_name.orEmpty(),
                machines.map { it.id to it.display_name },
                target,
                true,
                Position.SINGLE,
                Glyph.MACHINE,
                tag = "provider-machine",
            ) {
                machine = it
            }
        if (problem.isNotEmpty())
            Text(
                problem,
                Modifier.padding(horizontal = ScreenMargin + 16.dp, vertical = 6.dp),
                style = type.footnote,
                color = palette.destructive,
            )
        SectionFooter(
            when {
                machines.isEmpty() ->
                    "No machine is online. Add the account now and sign it in when one is back."
                provider == "claude" ->
                    "Claude Code signs in on the machine; its sign-in stays there."
                method == "siwc" -> "ChatGPT confirms the account; the machine keeps its key."
                else -> "Codex signs in on the machine; its sign-in stays there."
            }
        )
    }
}
