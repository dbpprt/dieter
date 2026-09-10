package com.dbpprt.dieter.ui

import com.dbpprt.dieter.v1.TokenUsage
import java.util.Locale

internal fun taskTokenUsageLabel(usage: TokenUsage): String {
    if (usage.reportedMessages == 0L) return "Tokens unavailable"
    val count = usage.totalTokens
    val compact = when {
        count >= 1_000_000 -> String.format(Locale.getDefault(), "%.1fM", count / 1_000_000.0)
        count >= 1_000 -> String.format(Locale.getDefault(), "%.1fK", count / 1_000.0)
        else -> count.toString()
    }
    return "$compact tokens" + if (usage.partial) " · partial" else ""
}

internal fun taskTokenUsageDetail(usage: TokenUsage): String =
    if (usage.reportedMessages == 0L) "Token usage was not reported by the provider."
    else "${usage.totalTokens} total tokens · ${usage.inputTokens} input · ${usage.outputTokens} output." +
        (if (usage.partial) " Partial provider data; input/output counts may be incomplete." else "") +
        " Cumulative conversation usage. Copied fork history is excluded; separate subagent counters are not added."
