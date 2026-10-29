@file:OptIn(androidx.compose.foundation.layout.ExperimentalLayoutApi::class)

package com.getdieter.mobile.tools

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.getdieter.client.v1.*
import com.getdieter.mobile.app.*
import com.getdieter.mobile.design.*
import com.getdieter.mobile.design.Tone
import com.getdieter.mobile.store.*

@Composable
internal fun UsageScreen(store: MobileStore) {
    val view by store.machines.quotas.collectAsState()
    var reset by remember { mutableStateOf<QuotaAccountRow?>(null) }
    Screen(
        ScreenChrome(
            "Usage",
            subtitle = "Provider accounts",
            actions =
                listOf(
                    ChromeAction("refresh-usage", "Refresh", Glyph.REFRESH) {
                        store.command(Command(quotas = QuotasCommand(load = QuotasLoad(true))))
                    }
                ),
        )
    ) {
        LazyColumn(
            Modifier.fillMaxSize().testTag("usage"),
            state = listState,
            contentPadding = padding,
        ) {
            if (view.error.isNotEmpty())
                item {
                    Banner(
                        "Usage unavailable",
                        view.error,
                        Modifier.padding(horizontal = ScreenMargin, vertical = 8.dp),
                        tone = Tone.WARNING,
                        actionLabel = "Retry",
                        onAction = {
                            store.command(Command(quotas = QuotasCommand(load = QuotasLoad())))
                        },
                    )
                }
            if (view.loading && view.group_rows.isEmpty())
                item {
                    Box(
                        Modifier.fillMaxWidth().padding(40.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        Spinner(Modifier.size(24.dp))
                    }
                }
            view.group_rows.forEach { group ->
                item("group-${group.provider}") {
                    SectionHeader(
                        group.provider_name,
                        prominent = true,
                        trailing = {
                            Text(
                                group.summary,
                                style = type.footnote,
                                color = palette.secondaryLabel,
                            )
                        },
                    )
                }
                itemsIndexed(
                    group.accounts,
                    key = { _, account -> "${group.provider}-${account.account_key}" },
                ) { _, account ->
                    ContentCard(Modifier.padding(horizontal = ScreenMargin, vertical = 5.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Column(Modifier.weight(1f)) {
                                Text(
                                    account.identity.ifEmpty { account.label },
                                    style = type.headline,
                                    color = palette.label,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                )
                                if (account.subtitle.isNotEmpty())
                                    Text(
                                        account.subtitle,
                                        style = type.footnote,
                                        color = palette.secondaryLabel,
                                    )
                            }
                            if (account.remaining >= 0)
                                Text(
                                    "${account.remaining}%",
                                    style = type.title2,
                                    color =
                                        if (account.remaining < 20)
                                            palette.warning.readableOn(palette.cell)
                                        else palette.label,
                                )
                        }
                        if (account.remaining >= 0) {
                            Spacer(Modifier.height(10.dp))
                            ProgressBar(
                                account.remaining / 100f,
                                color =
                                    if (account.remaining < 20) palette.warning
                                    else palette.success,
                            )
                        }
                        account.status
                            .ifEmpty { account.unavailable }
                            .takeIf { it.isNotEmpty() }
                            ?.let {
                                Spacer(Modifier.height(8.dp))
                                Text(it, style = type.footnote, color = palette.secondaryLabel)
                            }
                        if (account.windows.isNotEmpty()) {
                            Spacer(Modifier.height(10.dp))
                            account.windows.forEach { window ->
                                Row(Modifier.padding(vertical = 3.dp)) {
                                    Text(
                                        window.name,
                                        Modifier.weight(1f),
                                        style = type.subheadline,
                                        color = palette.label,
                                    )
                                    Text(
                                        listOfNotNull(
                                                if (window.remaining >= 0)
                                                    "${window.remaining}% left"
                                                else "Not reported",
                                                window.resets_at
                                                    .takeIf { it.isNotEmpty() }
                                                    ?.let { "resets $it" },
                                            )
                                            .joinToString(" · "),
                                        style = type.subheadline,
                                        color = palette.secondaryLabel,
                                    )
                                }
                            }
                        }
                        account.details
                            .filter { !it.monetary }
                            .forEach {
                                Text(
                                    "${it.label} · ${it.text}",
                                    style = type.footnote,
                                    color = palette.secondaryLabel,
                                )
                            }
                        account.machines.forEach {
                            Text(
                                "${it.name} · ${it.state}",
                                style = type.footnote,
                                color = palette.secondaryLabel,
                            )
                        }
                        Spacer(Modifier.height(8.dp))
                        Hairline()
                        Row(
                            Modifier.padding(top = 8.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Text(
                                "Include in summary",
                                Modifier.weight(1f),
                                style = type.subheadline,
                                color = palette.label,
                            )
                            DSwitch(
                                account.included,
                                {
                                    store.command(
                                        Command(
                                            quotas =
                                                QuotasCommand(
                                                    set_included =
                                                        QuotaInclusion(
                                                            group.provider,
                                                            account.account_key,
                                                            it,
                                                        )
                                                )
                                        )
                                    )
                                },
                                enabled = account.account_key !in view.mutating,
                            )
                        }
                        if (account.can_reset)
                            DButton(
                                "Use reset credit…",
                                { reset = account },
                                Modifier.padding(top = 8.dp),
                                kind = ButtonKind.TONAL,
                                enabled = account.account_key !in view.mutating,
                            )
                    }
                }
            }
            if (!view.loading && view.group_rows.isEmpty() && view.error.isEmpty())
                item {
                    EmptyState(
                        Glyph.USAGE,
                        "No provider usage",
                        "Accounts report usage through an enrolled machine.",
                        Modifier.padding(top = 40.dp),
                    )
                }
        }
    }
    reset?.let { account ->
        ConfirmDialog(
            "Use a reset credit?",
            "This spends one reset credit for ${account.identity}.",
            "Use credit",
            {
                store.command(
                    Command(
                        quotas = QuotasCommand(consume_reset = QuotaAccount(account.account_key))
                    )
                )
                reset = null
            },
            { reset = null },
        )
    }
}
