package com.getdieter.mobile.providers

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.getdieter.client.v1.*
import com.getdieter.core.client.rules.ProviderExports
import com.getdieter.mobile.app.*
import com.getdieter.mobile.design.*
import com.getdieter.mobile.design.Tone
import com.getdieter.mobile.navigation.*
import com.getdieter.mobile.store.*

/** The providers slice, observed while the calling view is shown. */
@Composable
internal fun rememberProviders(store: MobileStore): ProvidersSlice {
    DisposableEffect(store) {
        val release = store.providers.show()
        onDispose { release() }
    }
    val slice by store.providers.slice.collectAsState()
    return slice
}

/** Claude and ChatGPT accounts, grouped by provider, with their usage and sign-in state. */
@Composable
internal fun ProvidersScreen(store: MobileStore, openUrl: (String) -> Unit) {
    val slice = rememberProviders(store)
    var adding by rememberSaveable { mutableStateOf(false) }
    Screen(ScreenChrome("Providers", subtitle = slice.summary?.text.orEmpty())) {
        LazyColumn(
            Modifier.fillMaxSize().testTag("providers"),
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
            item("add") {
                Spacer(Modifier.height(8.dp))
                ListRow(
                    "Add account",
                    Modifier.testTag("providers-add"),
                    glyph = Glyph.ADD,
                    onClick = { adding = true },
                )
            }
            slice.groups.forEach { group ->
                item("group-${group.provider}") {
                    SectionHeader(
                        group.provider_name,
                        trailing = {
                            Text(
                                group.summary,
                                style = type.footnote,
                                color = palette.secondaryLabel,
                            )
                        },
                    )
                    Group(group.accounts) { account, position ->
                        ProviderAccountListRow(
                            account,
                            position,
                            Modifier.testTag("provider-${account.id}"),
                        ) {
                            store.push(MobileRoute.ProviderAccount(account.id))
                        }
                    }
                    if (group.accounts.isEmpty())
                        SectionFooter(
                            "No ${group.provider_name} accounts yet. Add one, then sign it in on " +
                                "your machines."
                        )
                }
            }
            item("footer") {
                SectionFooter(
                    "Each machine keeps its own sign-in; Dieter shares only the accounts, their " +
                        "sign-in state and usage between your machines."
                )
            }
        }
    }
    if (adding) AddAccountSheet(store, openUrl) { adding = false }
}

/** An account as a row: readiness, label, identity and plan, and what is left of its usage. */
@Composable
internal fun ProviderAccountListRow(
    account: ProviderAccountRow,
    position: Position,
    modifier: Modifier = Modifier,
    providerName: String = "",
    onClick: () -> Unit,
) {
    ListRow(
        account.label,
        modifier,
        position = position,
        subtitle =
            listOf(
                    providerName,
                    if (account.is_default) "Default" else "",
                    account.identity,
                    account.subtitle,
                )
                .filter { it.isNotBlank() }
                .joinToString(" · "),
        value = ProviderExports.usageText(account.remaining).ifEmpty { account.status },
        leading = { ReadinessDot(account.readiness()) },
        accessory = Accessory.CHEVRON,
        onClick = onClick,
    )
}
