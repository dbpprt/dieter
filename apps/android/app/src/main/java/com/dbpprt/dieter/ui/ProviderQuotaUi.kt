@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.dbpprt.dieter.ui

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.AlertDialog
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
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.dbpprt.dieter.gateway.v1.ProviderQuotaAvailability
import com.dbpprt.dieter.gateway.v1.ProviderQuotaGroup
import com.dbpprt.dieter.gateway.v1.ProviderQuotaProvider
import com.dbpprt.dieter.gateway.v1.ProviderQuotaSnapshot
import com.dbpprt.dieter.gateway.v1.ProviderQuotaWindow
import com.dbpprt.dieter.ui.theme.DieterAmber
import com.dbpprt.dieter.ui.theme.DieterEyes
import com.dbpprt.dieter.ui.theme.DieterMuted
import com.dbpprt.dieter.ui.theme.DieterOutline
import com.dbpprt.dieter.ui.theme.DieterOpenAIQuota
import com.dbpprt.dieter.ui.theme.DieterRunning
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
    Column(modifier, verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text("Provider quotas", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
                Text(
                    "The bar summarizes included accounts. Every account stays separate below.",
                    color = DieterMuted,
                    fontSize = 12.sp,
                )
            }
            Spacer(Modifier.width(12.dp))
            TextButton(
                onClick = onRefresh,
                enabled = !state.providerQuotasLoading,
                modifier = Modifier.testTag("provider-quotas-refresh"),
            ) {
                if (state.providerQuotasLoading) {
                    CircularProgressIndicator(strokeWidth = 2.dp, modifier = Modifier.width(18.dp))
                } else {
                    Text("Refresh")
                }
            }
        }
        state.providerQuotaError?.let {
            Text(it, color = MaterialTheme.colorScheme.error, fontSize = 11.sp)
        }
        if (state.providerQuotaGroups.isEmpty()) {
            Column(
                Modifier.fillMaxWidth().padding(vertical = 32.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Text("No provider accounts", fontWeight = FontWeight.SemiBold)
                Text(
                    state.providerQuotaError ?: "Sign in to a supported provider on an online Dieter machine.",
                    color = DieterMuted,
                    fontSize = 12.sp,
                )
            }
        } else {
            LazyColumn(
                Modifier.fillMaxWidth().heightIn(max = 560.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                items(state.providerQuotaGroups, key = { it.providerValue }) { group ->
                    ProviderQuotaGroupView(group, state, onSetSummaryInclusion, onUseReset)
                }
            }
        }
    }
}

@Composable
private fun ProviderQuotaGroupView(
    group: ProviderQuotaGroup,
    state: DieterUiState,
    onSetSummaryInclusion: (ProviderQuotaProvider, String, Boolean) -> Unit,
    onUseReset: (String) -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(9.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(quotaProviderName(group.provider), fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.weight(1f))
            Text(
                "${group.accountsCount} account${if (group.accountsCount == 1) "" else "s"}",
                color = DieterMuted,
                fontSize = 11.sp,
            )
        }
        if (group.hasSummary() && group.summary.hasRemainingPercent()) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(9.dp)) {
                LinearProgressIndicator(
                    progress = { group.summary.remainingPercent / 100f },
                    modifier = Modifier.weight(1f),
                    color = quotaTint(group.provider, group.summary.remainingPercent),
                )
                Text("${group.summary.remainingPercent}%", fontFamily = FontFamily.Monospace, fontSize = 12.sp)
            }
        }
        if (group.hasSummary() && group.summary.excludedAccountCount > 0) {
            Text(
                "${group.summary.includedAccountCount} included · ${group.summary.excludedAccountCount} excluded",
                color = DieterMuted,
                fontSize = 10.sp,
            )
        }
        group.accountsList.forEach {
            ProviderQuotaAccountView(it, group.provider, state, onSetSummaryInclusion, onUseReset)
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
    var resetConfirmation by remember(account.accountKey) { mutableStateOf(false) }
    Surface(
        shape = RoundedCornerShape(12.dp),
        color = DieterSurfaceHigh,
        border = BorderStroke(1.dp, DieterOutline),
    ) {
        Column(Modifier.fillMaxWidth().padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    account.plan.ifBlank { "Account" }.replaceFirstChar { it.uppercase() },
                    fontWeight = FontWeight.SemiBold,
                    fontSize = 13.sp,
                )
                Spacer(Modifier.width(7.dp))
                Text("••${account.accountKey.takeLast(6)}", color = DieterMuted, fontFamily = FontFamily.Monospace, fontSize = 10.sp)
                Spacer(Modifier.weight(1f))
                Text(
                    quotaAvailability(account.availability),
                    color = if (account.availability == ProviderQuotaAvailability.PROVIDER_QUOTA_AVAILABILITY_AVAILABLE) DieterEyes else DieterAmber,
                    fontSize = 10.sp,
                )
            }
            if (account.displayEmail.isNotBlank()) {
                Text(account.displayEmail, color = DieterMuted, fontSize = 11.sp)
            }
            account.windowsList.forEach { ProviderQuotaWindowView(it, provider) }
            if (showMonetaryBalances && account.hasCredits()) {
                ProviderQuotaMetadata(
                    "Credits",
                    if (account.credits.unlimited) "Unlimited" else account.credits.balance.ifBlank { "Available" },
                )
            }
            if (showMonetaryBalances && account.hasSpendAllowance()) {
                ProviderQuotaMetadata(
                    "Spend",
                    listOf(account.spendAllowance.used, account.spendAllowance.limit)
                        .filter { it.isNotBlank() }.joinToString(" / ").ifBlank { "Reported" },
                )
            }
            if (account.hasResetCredits()) {
                ProviderQuotaMetadata("Reset credits", "${account.resetCredits.availableCount} available")
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Include in usage summary", fontSize = 11.sp, modifier = Modifier.weight(1f))
                Switch(
                    checked = !account.hasIncludedInSummary() || account.includedInSummary,
                    onCheckedChange = { onSetSummaryInclusion(provider, account.accountKey, it) },
                    enabled = account.accountKey !in state.providerQuotaMutatingAccounts,
                    modifier = Modifier.testTag("provider-quotas-include-${account.accountKey}"),
                )
            }
            if (provider == ProviderQuotaProvider.PROVIDER_QUOTA_PROVIDER_OPENAI_CODEX &&
                account.hasResetCredits() && account.resetCredits.availableCount > 0
            ) {
                TextButton(
                    onClick = { resetConfirmation = true },
                    enabled = account.accountKey !in state.providerQuotaMutatingAccounts,
                    modifier = Modifier.testTag("provider-quotas-reset-${account.accountKey}"),
                ) { Text("Use reset credit…") }
            }
            if (account.windowsCount == 0) {
                Text(account.statusCode.ifBlank { "No numeric limit reported" }.replace('_', ' '), color = DieterMuted, fontSize = 11.sp)
            }
        }
    }
    if (resetConfirmation) {
        AlertDialog(
            onDismissRequest = { resetConfirmation = false },
            title = { Text("Use one OpenAI reset credit?") },
            text = { Text("This consumes one credit and resets the eligible quota windows for this exact account.") },
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
    Row(Modifier.fillMaxWidth()) {
        Text(label, color = DieterMuted, fontSize = 10.sp)
        Spacer(Modifier.weight(1f))
        Text(value, fontFamily = FontFamily.Monospace, fontSize = 10.sp)
    }
}

@Composable
private fun ProviderQuotaWindowView(window: ProviderQuotaWindow, provider: ProviderQuotaProvider) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(window.label.ifBlank { "Quota" }, fontSize = 11.sp, modifier = Modifier.width(76.dp))
        if (window.hasRemainingPercent()) {
            LinearProgressIndicator(
                progress = { window.remainingPercent / 100f },
                modifier = Modifier.weight(1f),
                color = quotaTint(provider, window.remainingPercent),
            )
            Text("${window.remainingPercent}%", fontFamily = FontFamily.Monospace, fontSize = 11.sp)
        } else {
            Text("Not reported", color = DieterMuted, fontSize = 11.sp, modifier = Modifier.weight(1f))
        }
        if (window.resetsAt.isNotBlank()) {
            Text(quotaResetText(window.resetsAt), color = DieterMuted, fontSize = 9.sp)
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
    provider == ProviderQuotaProvider.PROVIDER_QUOTA_PROVIDER_OPENAI_CODEX -> DieterOpenAIQuota
    provider == ProviderQuotaProvider.PROVIDER_QUOTA_PROVIDER_ANTHROPIC_CLAUDE -> DieterAmber
    remaining <= 10 -> MaterialTheme.colorScheme.error
    remaining <= 30 -> DieterAmber
    else -> DieterRunning
}

private fun quotaResetText(value: String): String = runCatching {
    val duration = Duration.between(Instant.now(), Instant.parse(value))
    when {
        duration.isNegative -> "reset due"
        duration.toHours() >= 24 -> "${duration.toDays()}d"
        duration.toHours() >= 1 -> "${duration.toHours()}h"
        else -> "${duration.toMinutes().coerceAtLeast(1)}m"
    }
}.getOrDefault(value)
