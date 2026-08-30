package com.dbpprt.dieter.ui

import java.util.Locale
import kotlin.math.roundToInt

internal fun subagentUsageMetrics(tokens: Long, contextTokens: Long, contextWindow: Long): List<String> = buildList {
    if (tokens > 0) add("${compactSubagentTokenCount(tokens)} processed")
    if (contextTokens > 0 && contextWindow > 0) {
        val percent = ((contextTokens.toDouble() / contextWindow) * 100).roundToInt().coerceIn(0, 100)
        add("${compactSubagentTokenCount(contextTokens)} / ${compactSubagentTokenCount(contextWindow)} context ($percent%)")
    }
}

private fun compactSubagentTokenCount(tokens: Long): String = when {
    tokens >= 1_000_000 -> String.format(Locale.US, "%.1fM", tokens / 1_000_000.0)
    tokens >= 100_000 -> String.format(Locale.US, "%.0fk", tokens / 1_000.0)
    tokens >= 1_000 -> String.format(Locale.US, "%.1fk", tokens / 1_000.0)
    else -> tokens.toString()
}
