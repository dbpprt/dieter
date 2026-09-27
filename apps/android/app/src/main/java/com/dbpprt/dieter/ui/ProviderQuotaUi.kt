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
import com.dbpprt.dieter.gateway.v1.ProviderQuotaAvailability
import com.dbpprt.dieter.gateway.v1.ProviderQuotaGroup
import com.dbpprt.dieter.gateway.v1.ProviderQuotaProvider
import com.dbpprt.dieter.gateway.v1.ProviderQuotaSnapshot
import com.dbpprt.dieter.gateway.v1.ProviderQuotaWindow
import com.dbpprt.dieter.ui.theme.DieterAmber
import com.dbpprt.dieter.ui.theme.DieterMuted
import com.dbpprt.dieter.ui.theme.DieterOutline
import com.dbpprt.dieter.ui.theme.DieterOpenAIQuota
import com.dbpprt.dieter.ui.theme.DieterRunning
import com.dbpprt.dieter.ui.theme.DieterSurface
import com.dbpprt.dieter.ui.theme.DieterSurfaceHigh
import java.time.Duration
import java.time.Instant

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
            item(key = "provider-${group.providerValue}", span = { GridItemSpan(maxLineSpan) }) {
                ProviderQuotaGroupHeader(group)
            }
            items(group.accountsList, key = { "${group.providerValue}-${it.accountKey}" }) { account ->
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
            Text(quotaProviderName(group.provider), style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold)
            Text(buildString {
                append("${group.accountsCount} account${if (group.accountsCount == 1) "" else "s"}")
                if (group.hasSummary() && group.summary.excludedAccountCount > 0) append(" · ${group.summary.excludedAccountCount} excluded")
            }, color = DieterMuted, style = MaterialTheme.typography.labelSmall)
        }
        if (group.hasSummary() && group.summary.hasRemainingPercent()) {
            val remaining = group.summary.remainingPercent.coerceIn(0, 100)
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
    var expanded by rememberSaveable(account.accountKey) { mutableStateOf(false) }
    var resetConfirmation by remember(account.accountKey) { mutableStateOf(false) }
    val included = !account.hasIncludedInSummary() || account.includedInSummary
    val plan = account.plan.ifBlank { "Account" }.replaceFirstChar { it.uppercase() }
    val identity = account.displayEmail.ifBlank { "$plan · ••${account.accountKey.takeLast(6)}" }
    Surface(
        modifier = Modifier.fillMaxWidth().testTag("provider-quotas-account-${account.accountKey}"),
        shape = RoundedCornerShape(16.dp), color = DieterSurface,
        border = BorderStroke(1.dp, DieterOutline.copy(alpha = .6f)),
    ) {
        Column {
            Surface(onClick = { expanded = !expanded }, color = Color.Transparent,
                modifier = Modifier.fillMaxWidth().testTag("provider-quotas-details-${account.accountKey}")
                    .semantics { stateDescription = if (expanded) "Account details expanded" else "Account details collapsed" }) {
                Row(Modifier.heightIn(min = 56.dp).padding(horizontal = 14.dp, vertical = 10.dp),
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Text(identity, style = MaterialTheme.typography.labelLarge,
                            maxLines = if (expanded) Int.MAX_VALUE else 1, overflow = TextOverflow.Ellipsis)
                        Text(listOfNotNull(plan.takeIf { account.displayEmail.isNotBlank() },
                            "Excluded from summary".takeIf { !included }).joinToString(" · ").ifBlank { "Account details" },
                            color = DieterMuted, style = MaterialTheme.typography.labelSmall)
                    }
                    Icon(if (expanded) Icons.Outlined.ExpandLess else Icons.Outlined.ExpandMore,
                        contentDescription = if (expanded) "Hide account details" else "Show account details",
                        tint = DieterMuted, modifier = Modifier.size(20.dp))
                }
            }
            Column(Modifier.padding(start = 14.dp, end = 14.dp, bottom = 14.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                if (account.availability != ProviderQuotaAvailability.PROVIDER_QUOTA_AVAILABILITY_AVAILABLE) {
                    Text(quotaAvailability(account.availability), color = DieterAmber, style = MaterialTheme.typography.labelMedium)
                }
                if (account.windowsCount > 0) {
                    BoxWithConstraints {
                        val columns = if (maxWidth >= 280.dp && LocalDensity.current.fontScale < 1.3f) 2 else 1
                        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                            account.windowsList.chunked(columns).forEach { windows ->
                                Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                                    windows.forEach { window -> ProviderQuotaWindowView(window, provider, Modifier.weight(1f)) }
                                    if (columns == 2 && windows.size == 1 && account.windowsCount > 1) Spacer(Modifier.weight(1f))
                                }
                            }
                        }
                    }
                } else {
                    Text(account.statusCode.ifBlank { "No numeric limit reported" }.replace('_', ' '),
                        color = DieterMuted, style = MaterialTheme.typography.bodySmall)
                }
                if (expanded) {
                    HorizontalDivider(color = DieterOutline)
                    ProviderQuotaMetadata("Account", "••${account.accountKey.takeLast(6)}")
                    if (showMonetaryBalances && account.hasCredits()) {
                        ProviderQuotaMetadata("Credits", if (account.credits.unlimited) "Unlimited" else account.credits.balance.ifBlank { "Available" })
                    }
                    if (showMonetaryBalances && account.hasSpendAllowance()) {
                        ProviderQuotaMetadata("Spend", listOf(account.spendAllowance.used, account.spendAllowance.limit)
                            .filter { it.isNotBlank() }.joinToString(" / ").ifBlank { "Reported" })
                    }
                    if (account.hasResetCredits()) ProviderQuotaMetadata("Reset credits", "${account.resetCredits.availableCount} available")
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        Text("Include in summary", style = MaterialTheme.typography.bodySmall, modifier = Modifier.weight(1f))
                        Switch(
                            checked = included,
                            onCheckedChange = { onSetSummaryInclusion(provider, account.accountKey, it) },
                            enabled = account.accountKey !in state.providerQuotaMutatingAccounts,
                            modifier = Modifier.testTag("provider-quotas-include-${account.accountKey}")
                                .semantics { contentDescription = "Include $identity in usage summary" },
                        )
                    }
                    if (provider == ProviderQuotaProvider.PROVIDER_QUOTA_PROVIDER_OPENAI_CODEX &&
                        account.hasResetCredits() && account.resetCredits.availableCount > 0) {
                        TextButton(
                            onClick = { resetConfirmation = true },
                            enabled = account.accountKey !in state.providerQuotaMutatingAccounts,
                            modifier = Modifier.testTag("provider-quotas-reset-${account.accountKey}"),
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
                    onUseReset(account.accountKey)
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
        Text(window.label.ifBlank { "Quota" }, color = DieterMuted, style = MaterialTheme.typography.labelMedium)
        if (window.hasRemainingPercent()) {
            val remaining = window.remainingPercent.coerceIn(0, 100)
            Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                Text("$remaining%", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
                Text("left", color = DieterMuted, style = MaterialTheme.typography.labelSmall, modifier = Modifier.padding(bottom = 3.dp))
            }
            LinearProgressIndicator(progress = { remaining / 100f }, modifier = Modifier.fillMaxWidth().height(4.dp),
                color = quotaTint(provider, remaining), trackColor = DieterSurfaceHigh, gapSize = 0.dp, drawStopIndicator = {})
        } else {
            Text("Not reported", color = DieterMuted, style = MaterialTheme.typography.bodySmall)
        }
        if (window.resetsAt.isNotBlank()) {
            Text(quotaResetText(window.resetsAt), color = DieterMuted, style = MaterialTheme.typography.labelSmall)
        }
    }
}

internal fun quotaProviderName(provider: ProviderQuotaProvider): String = when (provider) {
    ProviderQuotaProvider.PROVIDER_QUOTA_PROVIDER_OPENAI_CODEX -> "OpenAI Codex"
    ProviderQuotaProvider.PROVIDER_QUOTA_PROVIDER_ANTHROPIC_CLAUDE -> "Anthropic Claude"
    else -> "Provider"
}

internal fun quotaAvailability(value: ProviderQuotaAvailability): String = when (value) {
    ProviderQuotaAvailability.PROVIDER_QUOTA_AVAILABILITY_AVAILABLE -> "Available"
    ProviderQuotaAvailability.PROVIDER_QUOTA_AVAILABILITY_SIGNED_OUT -> "Signed out"
    ProviderQuotaAvailability.PROVIDER_QUOTA_AVAILABILITY_UNSUPPORTED -> "Unsupported"
    ProviderQuotaAvailability.PROVIDER_QUOTA_AVAILABILITY_PERMISSION_DENIED -> "Permission denied"
    ProviderQuotaAvailability.PROVIDER_QUOTA_AVAILABILITY_TEMPORARILY_UNAVAILABLE -> "Unavailable"
    else -> "Unknown"
}

@Composable
internal fun quotaTint(provider: ProviderQuotaProvider, remaining: Int): Color = when {
    remaining <= 10 -> MaterialTheme.colorScheme.error
    remaining <= 30 -> DieterAmber
    provider == ProviderQuotaProvider.PROVIDER_QUOTA_PROVIDER_OPENAI_CODEX -> DieterOpenAIQuota
    provider == ProviderQuotaProvider.PROVIDER_QUOTA_PROVIDER_ANTHROPIC_CLAUDE -> DieterAmber
    else -> DieterRunning
}

private fun quotaResetText(value: String): String = runCatching {
    val duration = Duration.between(Instant.now(), Instant.parse(value))
    when {
        duration.isNegative || duration.isZero -> "Reset due"
        duration.toHours() >= 24 -> "Resets in ${duration.toDays()}d ${duration.toHours() % 24}h"
        duration.toHours() >= 1 -> "Resets in ${duration.toHours()}h ${duration.toMinutes() % 60}m"
        else -> "Resets in ${duration.toMinutes().coerceAtLeast(1)}m"
    }
}.getOrDefault("Reset time unavailable")
