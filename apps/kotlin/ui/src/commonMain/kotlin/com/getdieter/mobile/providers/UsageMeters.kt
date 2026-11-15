package com.getdieter.mobile.providers

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.getdieter.client.v1.*
import com.getdieter.core.client.rules.ProviderExports
import com.getdieter.mobile.design.*
import kotlin.time.Instant

/** An allowance's color: red when critical, orange when low, green otherwise, gray if unknown. */
@Composable
@ReadOnlyComposable
internal fun ProviderSeverity.tint(): Color =
    when (this) {
        ProviderSeverity.PROVIDER_SEVERITY_CRITICAL -> palette.destructive
        ProviderSeverity.PROVIDER_SEVERITY_LOW -> palette.warning
        ProviderSeverity.PROVIDER_SEVERITY_NORMAL -> palette.success
        else -> palette.tertiaryLabel
    }

/**
 * Whether an account can run anywhere: signed in on a machine (green), a machine's sign-in needs
 * attention (orange), or signed in nowhere (gray).
 */
@Composable
@ReadOnlyComposable
internal fun ProviderAccountRow.readiness(): Color =
    when {
        machines.any { it.state == "expired" || it.state == "failed" } -> palette.warning
        machines.any { it.state == "signed_in" } -> palette.success
        else -> palette.tertiaryLabel
    }

@Composable
internal fun ReadinessDot(color: Color, modifier: Modifier = Modifier, size: Dp = 9.dp) {
    Box(modifier.size(size).background(color, CircleShape))
}

/**
 * One account's usage windows as meters: each window's name, what is left and when it resets, over
 * a bar in the window's severity color.
 */
@Composable
internal fun UsageMeters(windows: List<ProviderWindowRow>, now: Instant, modifier: Modifier) {
    Column(modifier, verticalArrangement = Arrangement.spacedBy(12.dp)) {
        windows.forEach { window -> UsageMeter(window, now) }
    }
}

@Composable
private fun UsageMeter(window: ProviderWindowRow, now: Instant) {
    val left = ProviderExports.usageText(window.remaining)
    Column(Modifier.fillMaxWidth().testTag("usage-window-${window.id}")) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                window.name,
                Modifier.weight(1f),
                style = type.subheadline.copy(fontWeight = FontWeight.Medium),
                color = palette.label,
                maxLines = 1,
            )
            Text(
                left.ifEmpty { "Not reported" },
                style = type.subheadline,
                color =
                    if (window.severity == ProviderSeverity.PROVIDER_SEVERITY_NORMAL) palette.label
                    else window.severity.tint().readableOn(palette.cell),
                maxLines = 1,
            )
        }
        if (window.remaining >= 0) {
            Spacer(Modifier.height(6.dp))
            ProgressBar(window.remaining / 100f, color = window.severity.tint())
        }
        if (window.resets_at.isNotEmpty()) {
            Spacer(Modifier.height(4.dp))
            Text(
                ProviderExports.resetText(window.resets_at, now.toEpochMilliseconds(), fine = true),
                style = type.footnote,
                color = palette.secondaryLabel,
                maxLines = 1,
            )
        }
    }
}
