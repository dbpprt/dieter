@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.dbpprt.dieter.ui

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ExpandLess
import androidx.compose.material.icons.outlined.ExpandMore
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.dbpprt.dieter.api.gateway.v1.ProviderQuotaAvailability
import com.dbpprt.dieter.api.gateway.v1.ProviderQuotaGroup
import com.dbpprt.dieter.api.gateway.v1.ProviderQuotaProvider
import com.dbpprt.dieter.api.gateway.v1.ProviderQuotaSnapshot
import com.dbpprt.dieter.api.gateway.v1.ProviderQuotaWindow
import com.dbpprt.dieter.core.quotas.QuotaLevel
import com.dbpprt.dieter.core.quotas.Quotas
import com.dbpprt.dieter.ui.theme.DieterAmber
import com.dbpprt.dieter.ui.theme.DieterMuted
import com.dbpprt.dieter.ui.theme.DieterOutline
import com.dbpprt.dieter.ui.theme.DieterOpenAIQuota
import com.dbpprt.dieter.ui.theme.DieterRunning
import com.dbpprt.dieter.ui.theme.DieterSurface
import com.dbpprt.dieter.ui.theme.DieterSurfaceHigh
import java.time.Duration
import java.time.Instant
import kotlin.time.Clock

@Composable
internal fun ProviderQuotaDetails(
    state: DieterUiState,
    onRefresh: () -> Unit,
    onSetSummaryInclusion: (ProviderQuotaProvider, String, Boolean) -> Unit,
    onUseReset: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    // One scroll surface uses the available height, with extra columns on tablets.
    // Scale the minimum column width along with text so accessibility stays readable.
    LazyVerticalGrid(
        columns = GridCells.Adaptive((300 * LocalDensity.current.fontScale.coerceAtLeast(1f)).dp),
        modifier = modifier.testTag("provider-quotas-list"),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        item(span = { GridItemSpan(maxLineSpan) }) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text("Usage", style = MaterialTheme.typography.headlineSmall)
                    Text("Your remaining provider allowances", color = DieterMuted, style = MaterialTheme.typography.bodySmall)
                }
                IconButton(
                    onClick = onRefresh,
                    enabled = !state.providerQuotasLoading,
                    modifier = Modifier.testTag("provider-quotas-refresh"),
                ) {
                    if (state.providerQuotasLoading) {
                        CircularProgressIndicator(strokeWidth = 2.dp, modifier = Modifier.size(20.dp)
                            .semantics { contentDescription = "Refreshing usage" })
                    } else Icon(Icons.Outlined.Refresh, contentDescription = "Refresh usage")
                }
            }
        }
        state.providerQuotaError?.let { error ->
            item(span = { GridItemSpan(maxLineSpan) }) {
                Text(error, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall)
            }
        }
        if (state.providerQuotaGroups.isEmpty()) {
            item(span = { GridItemSpan(maxLineSpan) }) {
                Surface(shape = RoundedCornerShape(16.dp), color = DieterSurface) {
                    Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        Text(if (state.providerQuotasLoading) "Loading usage…" else "No provider accounts", style = MaterialTheme.typography.titleSmall)
                        if (!state.providerQuotasLoading) Text(
                            "Sign in to a supported provider on an online Dieter machine.",
                            color = DieterMuted, style = MaterialTheme.typography.bodySmall,
                        )
                    }
                }
            }
        }
        state.providerQuotaGroups.forEach { group ->
            item(key = "provider-${group.provider.value}", span = { GridItemSpan(maxLineSpan) }) {
                ProviderQuotaGroupHeader(group)
            }
            items(group.accounts, key = { "${group.provider.value}-${it.account_key}" }) { account ->
                ProviderQuotaAccountView(account, group.provider, state, onSetSummaryInclusion, onUseReset)
            }
        }
    }
}

@Composable
private fun ProviderQuotaGroupHeader(group: ProviderQuotaGroup) {
    Row(Modifier.fillMaxWidth().padding(top = 8.dp), verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(Quotas.productName(group.provider), style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold)
            Text(Quotas.groupSummary(group), color = DieterMuted, style = MaterialTheme.typography.labelSmall)
        }
        group.summary?.remaining_percent?.let { percent ->
            val remaining = percent.coerceIn(0, 100)
            Column(horizontalAlignment = Alignment.End, modifier = Modifier.semantics(mergeDescendants = true) {
                contentDescription = "Lowest remaining allowance across included accounts"
            }) {
                Text("$remaining% left", style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold)
                Text("Lowest allowance", color = DieterMuted, style = MaterialTheme.typography.labelSmall)
            }
        }
    }
}

@Composable
internal fun ProviderQuotaAccountView(
    account: ProviderQuotaSnapshot,
    provider: ProviderQuotaProvider,
    state: DieterUiState,
    onSetSummaryInclusion: (ProviderQuotaProvider, String, Boolean) -> Unit,
    onUseReset: (String) -> Unit,
    showMonetaryBalances: Boolean = true,
) {
    var expanded by rememberSaveable(account.account_key) { mutableStateOf(false) }
    var resetConfirmation by remember(account.account_key) { mutableStateOf(false) }
    val included = Quotas.included(account)
    val identity = Quotas.identity(account)
    Surface(
        modifier = Modifier.fillMaxWidth().testTag("provider-quotas-account-${account.account_key}"),
        shape = RoundedCornerShape(16.dp), color = DieterSurface,
        border = BorderStroke(1.dp, DieterOutline.copy(alpha = .6f)),
    ) {
        Column {
            Surface(onClick = { expanded = !expanded }, color = Color.Transparent,
                modifier = Modifier.fillMaxWidth().testTag("provider-quotas-details-${account.account_key}")
                    .semantics { stateDescription = if (expanded) "Account details expanded" else "Account details collapsed" }) {
                Row(Modifier.heightIn(min = 56.dp).padding(horizontal = 14.dp, vertical = 10.dp),
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Text(identity, style = MaterialTheme.typography.labelLarge,
                            maxLines = if (expanded) Int.MAX_VALUE else 1, overflow = TextOverflow.Ellipsis)
                        Text(Quotas.subtitle(account), color = DieterMuted, style = MaterialTheme.typography.labelSmall)
                    }
                    Icon(if (expanded) Icons.Outlined.ExpandLess else Icons.Outlined.ExpandMore,
                        contentDescription = if (expanded) "Hide account details" else "Show account details",
                        tint = DieterMuted, modifier = Modifier.size(20.dp))
                }
            }
            Column(Modifier.padding(start = 14.dp, end = 14.dp, bottom = 14.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                if (!Quotas.available(account)) {
                    Text(Quotas.availability(account.availability), color = DieterAmber, style = MaterialTheme.typography.labelMedium)
                }
                if (account.windows.size > 0) {
                    BoxWithConstraints {
                        val columns = if (maxWidth >= 280.dp && LocalDensity.current.fontScale < 1.3f) 2 else 1
                        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                            account.windows.chunked(columns).forEach { windows ->
                                Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                                    windows.forEach { window -> ProviderQuotaWindowView(window, provider, Modifier.weight(1f)) }
                                    if (columns == 2 && windows.size == 1 && account.windows.size > 1) Spacer(Modifier.weight(1f))
                                }
                            }
                        }
                    }
                } else {
                    Text(Quotas.status(account), color = DieterMuted, style = MaterialTheme.typography.bodySmall)
                }
                if (expanded) {
                    HorizontalDivider(color = DieterOutline)
                    Quotas.details(account, monetary = showMonetaryBalances).forEach { (label, value) -> ProviderQuotaMetadata(label, value) }
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        Text("Include in summary", style = MaterialTheme.typography.bodySmall, modifier = Modifier.weight(1f))
                        Switch(
                            checked = included,
                            onCheckedChange = { onSetSummaryInclusion(provider, account.account_key, it) },
                            enabled = account.account_key !in state.providerQuotaMutatingAccounts,
                            modifier = Modifier.testTag("provider-quotas-include-${account.account_key}")
                                .semantics { contentDescription = "Include $identity in usage summary" },
                        )
                    }
                    if (Quotas.canReset(provider, account)) {
                        TextButton(
                            onClick = { resetConfirmation = true },
                            enabled = account.account_key !in state.providerQuotaMutatingAccounts,
                            modifier = Modifier.testTag("provider-quotas-reset-${account.account_key}"),
                        ) { Text("Use reset credit…") }
                    }
                }
            }
        }
    }
    if (resetConfirmation) {
        AlertDialog(
            onDismissRequest = { resetConfirmation = false },
            title = { Text("Use one OpenAI reset credit?") },
            text = { Text("This consumes one credit and resets the eligible quota windows for $identity.") },
            confirmButton = {
                TextButton(onClick = {
                    resetConfirmation = false
                    onUseReset(account.account_key)
                }) { Text("Use reset credit") }
            },
            dismissButton = { TextButton(onClick = { resetConfirmation = false }) { Text("Cancel") } },
        )
    }
}

@Composable
private fun ProviderQuotaMetadata(label: String, value: String) {
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(16.dp)) {
        Text(label, color = DieterMuted, style = MaterialTheme.typography.bodySmall, modifier = Modifier.weight(1f))
        Text(value, style = MaterialTheme.typography.bodySmall, modifier = Modifier.weight(1f))
    }
}

@Composable
private fun ProviderQuotaWindowView(window: ProviderQuotaWindow, provider: ProviderQuotaProvider, modifier: Modifier) {
    Column(modifier.semantics(mergeDescendants = true) {}, verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(Quotas.windowName(window), color = DieterMuted, style = MaterialTheme.typography.labelMedium)
        val percent = window.remaining_percent
        if (percent != null) {
            val remaining = percent.coerceIn(0, 100)
            Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                Text("$remaining%", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
                Text("left", color = DieterMuted, style = MaterialTheme.typography.labelSmall, modifier = Modifier.padding(bottom = 3.dp))
            }
            LinearProgressIndicator(progress = { remaining / 100f }, modifier = Modifier.fillMaxWidth().height(4.dp),
                color = quotaTint(provider, remaining), trackColor = DieterSurfaceHigh, gapSize = 0.dp, drawStopIndicator = {})
        } else {
            Text("Not reported", color = DieterMuted, style = MaterialTheme.typography.bodySmall)
        }
        if (window.resets_at.isNotBlank()) {
            Text(Quotas.resetText(window.resets_at, Clock.System.now()), color = DieterMuted, style = MaterialTheme.typography.labelSmall)
        }
    }
}

@Composable
internal fun quotaTint(provider: ProviderQuotaProvider, remaining: Int): Color = when (Quotas.level(remaining)) {
    QuotaLevel.CRITICAL -> MaterialTheme.colorScheme.error
    QuotaLevel.LOW -> DieterAmber
    else -> when (provider) {
        ProviderQuotaProvider.PROVIDER_QUOTA_PROVIDER_OPENAI_CODEX -> DieterOpenAIQuota
        ProviderQuotaProvider.PROVIDER_QUOTA_PROVIDER_ANTHROPIC_CLAUDE -> DieterAmber
        else -> DieterRunning
    }
}
