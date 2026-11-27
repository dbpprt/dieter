package com.getdieter.mobile.providers

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.getdieter.client.v1.*
import com.getdieter.core.client.rules.ProviderExports
import com.getdieter.mobile.app.*
import com.getdieter.mobile.design.*
import com.getdieter.mobile.design.Tone
import com.getdieter.mobile.navigation.*
import com.getdieter.mobile.store.*

/**
 * One account: its usage, its sign-in on each machine, whether it is the provider's default and
 * counts in summaries, its reset credits, and renaming or removing it.
 */
@Composable
internal fun ProviderAccountScreen(
    store: MobileStore,
    accountId: String,
    openUrl: (String) -> Unit,
) {
    val slice = rememberProviders(store)
    val busy by store.busy.collectAsState()
    val outcome by store.providers.reset.collectAsState()
    val now = rememberNow()
    val group = slice.groups.firstOrNull { g -> g.accounts.any { it.id == accountId } }
    val account = group?.accounts?.firstOrNull { it.id == accountId }
    val mutating = accountId in slice.mutating
    var signing by rememberSaveable { mutableStateOf("") }
    var renaming by remember { mutableStateOf(false) }
    var removing by remember { mutableStateOf(false) }
    var resetting by remember { mutableStateOf(false) }
    var allowingOmp by remember { mutableStateOf(false) }
    var signingOut by remember { mutableStateOf<ProviderMachineRow?>(null) }
    Screen(
        ScreenChrome(
            account?.label ?: "Account",
            subtitle = group?.provider_name.orEmpty(),
            actions =
                listOf(
                    ChromeAction(
                        "refresh-usage",
                        "Refresh usage",
                        Glyph.REFRESH,
                        enabled = account != null && !mutating,
                    ) {
                        store.providers.refreshUsage(accountId)
                    }
                ),
        )
    ) {
        if (account == null) {
            EmptyState(
                Glyph.KEY,
                "Account unavailable",
                "It was removed, or this device has not received it yet.",
                Modifier.padding(top = 40.dp),
            )
            return@Screen
        }
        LazyColumn(
            Modifier.fillMaxSize().testTag("provider-account"),
            state = listState,
            contentPadding = padding,
        ) {
            if (slice.error.isNotEmpty())
                item("error") {
                    Banner(
                        slice.error,
                        "",
                        Modifier.padding(horizontal = ScreenMargin, vertical = 6.dp),
                        tone = Tone.WARNING,
                    )
                }
            outcome
                ?.takeIf { it.account_id == accountId }
                ?.let { reset ->
                    item("reset-outcome") {
                        Banner(
                            reset.message,
                            "",
                            Modifier.padding(horizontal = ScreenMargin, vertical = 6.dp),
                            tone = if (reset.outcome == "reset") Tone.SUCCESS else Tone.NEUTRAL,
                            onDismiss = { store.providers.reset.value = null },
                        )
                    }
                }
            item("usage") { UsageCard(account, now, Modifier.padding(top = 8.dp)) }
            item("machines") {
                SectionHeader("Machines")
                Group(account.machines) { machine, position ->
                    MachineRow(
                        machine,
                        position,
                        enabled = !mutating,
                        onSignIn = {
                            store.providers.signIn(accountId, machine.daemon_id) { signing = it }
                        },
                        onCheck = { store.providers.check(accountId, machine.daemon_id) },
                        onSignOut = { signingOut = machine },
                    )
                }
                if (account.can_sign_in_all) {
                    Spacer(Modifier.height(12.dp))
                    ListRow(
                        "Sign in on all machines",
                        Modifier.testTag("provider-signin-all"),
                        glyph = Glyph.KEY,
                        enabled = !mutating,
                        onClick = { store.providers.signInAll(accountId) { signing = it } },
                    )
                }
                when {
                    account.managed ->
                        SectionFooter(
                            "This account follows each machine's own login or API key; there is " +
                                "nothing to sign in."
                        )
                    account.machines.isEmpty() ->
                        SectionFooter("Enroll a machine to sign this account in.")
                }
            }
            item("settings") {
                SectionHeader("Settings")
                val rows = buildList {
                    add("default")
                    add("included")
                    if (account.offers_omp_access) add("omp")
                    if (account.can_reset) add("reset")
                    if (account.manage_usage_url.isNotEmpty()) add("manage")
                }
                Group(rows) { row, position ->
                    when (row) {
                        "default" ->
                            ListRow(
                                "Default ${group.provider_name} account",
                                Modifier.testTag("provider-default"),
                                position = position,
                                subtitle = "New conversations use it unless you choose another",
                                trailing = {
                                    DSwitch(
                                        account.is_default,
                                        { if (it) store.providers.setDefault(accountId) },
                                        enabled = !account.is_default && !mutating,
                                    )
                                },
                            )
                        "included" ->
                            ListRow(
                                "Include in summary",
                                Modifier.testTag("provider-included"),
                                position = position,
                                subtitle = "Count its usage in the Inbox and sidebar",
                                trailing = {
                                    DSwitch(
                                        account.included,
                                        { store.providers.setIncluded(accountId, it) },
                                        enabled = !mutating,
                                    )
                                },
                            )
                        "omp" ->
                            ListRow(
                                ProviderExports.ompAccessLabel(),
                                Modifier.testTag("provider-omp-access"),
                                position = position,
                                subtitle = ProviderExports.ompAccessDetail(),
                                titleMaxLines = 2,
                                trailing = {
                                    DSwitch(
                                        account.omp_access,
                                        {
                                            if (it) allowingOmp = true
                                            else store.providers.setOmpAccess(accountId, false)
                                        },
                                        enabled = !mutating,
                                    )
                                },
                            )
                        "reset" ->
                            ListRow(
                                account.reset_label,
                                Modifier.testTag("provider-reset"),
                                position = position,
                                glyph = Glyph.UNDO,
                                enabled = !mutating && !busy,
                                onClick = { resetting = true },
                            )
                        else ->
                            ListRow(
                                "Manage usage",
                                Modifier.testTag("provider-manage-usage"),
                                position = position,
                                glyph = Glyph.OPEN,
                                onClick = { openUrl(account.manage_usage_url) },
                            )
                    }
                }
            }
            item("account") {
                SectionHeader("Account")
                Group(listOf("rename", "remove")) { row, position ->
                    if (row == "rename")
                        ListRow(
                            "Rename…",
                            Modifier.testTag("provider-rename"),
                            position = position,
                            glyph = Glyph.RENAME,
                            enabled = !mutating,
                            onClick = { renaming = true },
                        )
                    else
                        ListRow(
                            if (account.managed) "Hide account" else "Remove account",
                            Modifier.testTag("provider-remove"),
                            position = position,
                            glyph = Glyph.TRASH,
                            destructive = true,
                            enabled = !mutating,
                            onClick = { removing = true },
                        )
                }
            }
        }
    }
    if (account != null) {
        if (renaming)
            PromptDialog(
                "Rename account",
                account.label,
                "Rename",
                {
                    if (it.isNotBlank() && it.trim() != account.label)
                        store.providers.rename(accountId, it)
                    renaming = false
                },
                { renaming = false },
                placeholder = "Work",
            )
        if (removing)
            ConfirmDialog(
                if (account.managed) "Hide ${account.label}?" else "Remove ${account.label}?",
                if (account.managed) "It comes back while a machine still has that login or key."
                else "Every machine signs it out and forgets it.",
                if (account.managed) "Hide" else "Remove",
                {
                    removing = false
                    store.providers.remove(accountId)
                    if (store.routes.value.top == MobileRoute.ProviderAccount(accountId))
                        store.pop()
                },
                { removing = false },
                destructive = true,
            )
        if (resetting)
            ConfirmDialog(
                ProviderExports.resetTitle(),
                ProviderExports.resetMessage(),
                "Use credit",
                {
                    resetting = false
                    store.providers.consumeReset(accountId)
                },
                { resetting = false },
            )
        if (allowingOmp)
            ConfirmDialog(
                ProviderExports.ompAccessTitle(),
                ProviderExports.ompAccessMessage(),
                ProviderExports.ompAccessConfirm(),
                {
                    allowingOmp = false
                    store.providers.setOmpAccess(accountId, true)
                },
                { allowingOmp = false },
            )
        signingOut?.let { machine ->
            ConfirmDialog(
                "Sign ${account.label} out on ${machine.name}?",
                "Agent turns on ${machine.name} cannot use it until it signs in again.",
                "Sign out",
                {
                    signingOut = null
                    store.providers.signOut(accountId, machine.daemon_id)
                },
                { signingOut = null },
                destructive = true,
            )
        }
    }
    if (signing.isNotEmpty()) SignInSheet(store, signing, openUrl) { signing = "" }
}

/** Identity and plan, what is left of each usage window, when it was read, and Dieter's share. */
@Composable
private fun UsageCard(account: ProviderAccountRow, now: kotlin.time.Instant, modifier: Modifier) {
    val millis = now.toEpochMilliseconds()
    ContentCard(modifier.padding(horizontal = ScreenMargin, vertical = 5.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(
                    account.identity,
                    style = type.headline,
                    color = palette.label,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                if (account.subtitle.isNotEmpty())
                    Text(account.subtitle, style = type.footnote, color = palette.secondaryLabel)
            }
            if (account.remaining >= 0)
                Text(
                    "${account.remaining}%",
                    style = type.title2,
                    color =
                        if (account.severity == ProviderSeverity.PROVIDER_SEVERITY_NORMAL)
                            palette.label
                        else account.severity.tint().readableOn(palette.cell),
                )
        }
        if (account.windows.isNotEmpty())
            UsageMeters(account.windows, now, Modifier.padding(top = 14.dp))
        else if (account.status.isNotEmpty())
            Text(
                account.status,
                Modifier.padding(top = 10.dp),
                style = type.subheadline,
                color = palette.secondaryLabel,
            )
        if (account.windows.isNotEmpty() || account.usage_observed_at.isNotEmpty())
            Text(
                ProviderExports.usageUpdated(account.usage_observed_at, millis),
                Modifier.padding(top = 12.dp).testTag("provider-usage-updated"),
                style = type.footnote,
                color =
                    if (ProviderExports.usageStale(account.usage_observed_at, millis))
                        palette.warning.readableOn(palette.cell)
                    else palette.secondaryLabel,
            )
        if (account.dieter_tokens.isNotEmpty())
            Text(
                "Dieter: ${account.dieter_tokens}",
                Modifier.padding(top = 4.dp),
                style = type.footnote,
                color = palette.secondaryLabel,
            )
    }
}

/** A machine's sign-in state with Sign in, or a menu to check or sign out. */
@Composable
private fun MachineRow(
    machine: ProviderMachineRow,
    position: Position,
    enabled: Boolean,
    onSignIn: () -> Unit,
    onCheck: () -> Unit,
    onSignOut: () -> Unit,
) {
    val stateColor =
        when (machine.state) {
            "signed_in" -> palette.success
            "expired",
            "failed" -> palette.warning
            else -> palette.tertiaryLabel
        }
    GroupItem(position, Modifier.testTag("provider-machine-${machine.daemon_id}")) {
        Row(
            Modifier.fillMaxWidth().padding(start = 16.dp, end = 8.dp, top = 10.dp, bottom = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(Glyph.MACHINE, null, tint = palette.secondaryLabel, size = 22.dp)
            Spacer(Modifier.width(14.dp))
            Column(Modifier.weight(1f)) {
                Text(
                    machine.name,
                    style = type.body,
                    color = if (machine.online) palette.label else palette.secondaryLabel,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Row(verticalAlignment = Alignment.CenterVertically) {
                    ReadinessDot(stateColor, size = 7.dp)
                    Spacer(Modifier.width(6.dp))
                    Text(
                        machine.state_label,
                        Modifier.testTag("provider-machine-state-${machine.daemon_id}"),
                        style = type.subheadline,
                        color = palette.secondaryLabel,
                        maxLines = 1,
                    )
                    if (!machine.online)
                        Text(
                            " · Offline",
                            style = type.subheadline,
                            color = palette.secondaryLabel,
                            maxLines = 1,
                        )
                }
                if (machine.detail.isNotEmpty())
                    Text(
                        machine.detail,
                        style = type.footnote,
                        color = palette.secondaryLabel,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
            }
            if (machine.can_sign_in)
                DButton(
                    "Sign in",
                    onSignIn,
                    Modifier.testTag("provider-signin-${machine.daemon_id}"),
                    kind = ButtonKind.TONAL,
                    enabled = enabled,
                )
            val actions =
                listOfNotNull(
                    if (machine.can_check)
                        ChromeAction(
                            "provider-check-${machine.daemon_id}",
                            "Check sign-in",
                            Glyph.REFRESH,
                            enabled = enabled,
                            onClick = onCheck,
                        )
                    else null,
                    if (machine.can_sign_out)
                        ChromeAction(
                            "provider-signout-${machine.daemon_id}",
                            "Sign out",
                            Glyph.SIGN_OUT,
                            enabled = enabled,
                            destructive = true,
                            onClick = onSignOut,
                        )
                    else null,
                )
            if (actions.isNotEmpty())
                MenuButton(
                    listOf(MenuSection(actions)),
                    "${machine.name} sign-in actions",
                    Modifier.testTag("provider-machine-menu-${machine.daemon_id}"),
                )
        }
    }
}
