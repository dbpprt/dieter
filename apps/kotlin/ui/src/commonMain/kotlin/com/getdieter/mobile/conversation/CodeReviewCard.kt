package com.getdieter.mobile.conversation

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.getdieter.client.v1.TimelineCodeReview
import com.getdieter.client.v1.TimelineCodeReviewFinding
import com.getdieter.mobile.design.*

/**
 * A code review in the transcript: what was reviewed and by whom, the reviewer's summary, its
 * findings (a tap shows a finding's explanation and suggested fix), and the earlier findings this
 * round resolved. [onLocation] opens a finding's file in the conversation's Changes.
 */
@Composable
internal fun CodeReviewCard(
    review: TimelineCodeReview,
    openUrl: (String) -> Unit,
    onLocation: ((TimelineCodeReviewFinding) -> Unit)?,
) {
    ContentCard(Modifier.testTag("code-review-${review.review_id}")) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(
                Modifier.size(32.dp).clip(CircleShape).background(palette.fill),
                contentAlignment = Alignment.Center,
            ) {
                when {
                    review.running -> Spinner(Modifier.size(15.dp), color = palette.accent)
                    review.error.isNotEmpty() ->
                        Icon(Glyph.WARNING, null, tint = palette.destructive, size = 16.dp)
                    else -> Icon(Glyph.EYE, null, tint = palette.secondaryLabel, size = 16.dp)
                }
            }
            Spacer(Modifier.width(10.dp))
            Column(Modifier.weight(1f)) {
                Text(
                    review.title,
                    style = type.headline,
                    color = palette.label,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                if (review.subtitle.isNotEmpty())
                    Text(
                        review.subtitle,
                        style = type.footnote,
                        color = palette.secondaryLabel,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
            }
        }
        val counts = listOf(review.counts_label, review.change_label).filter { it.isNotEmpty() }
        if (counts.isNotEmpty()) {
            Spacer(Modifier.height(10.dp))
            Text(
                counts.joinToString(" · "),
                style = type.subheadline.copy(fontWeight = FontWeight.Medium),
                color = palette.label,
            )
        }
        val context = listOf(review.round_label, review.trigger_label).filter { it.isNotEmpty() }
        if (context.isNotEmpty()) {
            Spacer(Modifier.height(if (counts.isEmpty()) 10.dp else 2.dp))
            Text(
                context.joinToString(" · "),
                style = type.footnote,
                color = palette.secondaryLabel,
            )
        }
        if (review.summary.isNotEmpty()) {
            Spacer(Modifier.height(10.dp))
            RichText(review.summary, openUrl)
        }
        if (review.security.isNotEmpty()) {
            Spacer(Modifier.height(8.dp))
            Row(verticalAlignment = Alignment.Top) {
                Icon(
                    Glyph.LOCK,
                    null,
                    Modifier.padding(top = 2.dp),
                    tint = palette.warning.readableOn(palette.cell),
                    size = 13.dp,
                )
                Spacer(Modifier.width(6.dp))
                Text(
                    "Security: ${review.security}",
                    style = type.footnote,
                    color = palette.warning.readableOn(palette.cell),
                )
            }
        }
        if (review.error.isNotEmpty()) {
            Spacer(Modifier.height(8.dp))
            Text(review.error, style = type.footnote, color = palette.destructive)
        }
        if (review.findings.isNotEmpty()) {
            Spacer(Modifier.height(8.dp))
            review.findings.forEach { finding ->
                Hairline()
                FindingRow(review.review_id, finding, openUrl, onLocation)
            }
        }
        if (review.resolved.isNotEmpty()) {
            var open by rememberSaveable(review.review_id + ":resolved") { mutableStateOf(false) }
            Spacer(Modifier.height(if (review.findings.isEmpty()) 8.dp else 0.dp))
            Hairline()
            Row(
                Modifier.fillMaxWidth()
                    .pressable(onClick = { open = !open })
                    .padding(vertical = 10.dp)
                    .testTag("code-review-resolved-${review.review_id}")
                    .semantics {
                        contentDescription = (if (open) "Hide " else "Show ") + "resolved findings"
                    },
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(Glyph.CHECK_CIRCLE, null, tint = palette.success, size = 14.dp)
                Spacer(Modifier.width(6.dp))
                Text(
                    "Resolved (${review.resolved.size})",
                    Modifier.weight(1f),
                    style = type.footnote.copy(fontWeight = FontWeight.SemiBold),
                    color = palette.secondaryLabel,
                )
                DisclosureChevron(open)
            }
            AnimatedVisibility(open) {
                Column {
                    review.resolved.forEach { finding ->
                        Hairline()
                        FindingRow(review.review_id, finding, openUrl, null)
                    }
                }
            }
        }
    }
}

/** One finding: its severity, title and location; a tap shows its explanation and suggested fix. */
@Composable
private fun FindingRow(
    reviewId: String,
    finding: TimelineCodeReviewFinding,
    openUrl: (String) -> Unit,
    onLocation: ((TimelineCodeReviewFinding) -> Unit)?,
) {
    var open by rememberSaveable("$reviewId:${finding.id}") { mutableStateOf(false) }
    val expandable = finding.body.isNotEmpty() || finding.suggestion.isNotEmpty()
    Column(
        Modifier.fillMaxWidth()
            .then(if (expandable) Modifier.pressable(onClick = { open = !open }) else Modifier)
            .padding(vertical = 10.dp)
            .testTag("code-review-finding-$reviewId-${finding.id}")
    ) {
        Row(verticalAlignment = Alignment.Top) {
            SeverityChip(finding.severity, finding.severity_label)
            Spacer(Modifier.width(8.dp))
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(
                    finding.title,
                    style = type.subheadline.copy(fontWeight = FontWeight.SemiBold),
                    color = palette.label,
                    maxLines = if (open) Int.MAX_VALUE else 2,
                    overflow = TextOverflow.Ellipsis,
                )
                if (finding.location_label.isNotEmpty()) {
                    val linked = onLocation != null && finding.file_.isNotEmpty()
                    Text(
                        finding.location_label,
                        Modifier.then(
                                if (linked)
                                    Modifier.clip(RoundedCornerShape(4.dp))
                                        .pressable(onClick = { onLocation?.invoke(finding) })
                                else Modifier
                            )
                            .testTag("code-review-location-$reviewId-${finding.id}"),
                        style = type.monoSmall,
                        color = if (linked) palette.info else palette.secondaryLabel,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
            if (finding.status_label.isNotEmpty() && finding.status != "new") {
                Spacer(Modifier.width(6.dp))
                Text(
                    finding.status_label,
                    Modifier.padding(top = 2.dp),
                    style = type.caption,
                    color = palette.secondaryLabel,
                    maxLines = 1,
                )
            }
            if (expandable) {
                Spacer(Modifier.width(6.dp))
                Box(Modifier.padding(top = 3.dp)) { DisclosureChevron(open) }
            }
        }
        AnimatedVisibility(open) {
            Column(
                Modifier.padding(top = 8.dp),
                verticalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                if (finding.body.isNotEmpty()) RichText(finding.body, openUrl)
                if (finding.suggestion.isNotEmpty()) {
                    Text(
                        "Suggested fix",
                        style = type.footnote.copy(fontWeight = FontWeight.SemiBold),
                        color = palette.secondaryLabel,
                    )
                    RichText(finding.suggestion, openUrl)
                }
            }
        }
    }
}

/** "High", "Medium" or "Low" in its severity's colour. */
@Composable
private fun SeverityChip(severity: String, label: String) {
    val tint: Color =
        when (severity) {
            "high" -> palette.destructive
            "medium" -> palette.warning
            else -> palette.secondaryLabel
        }
    Text(
        label,
        Modifier.padding(top = 1.dp)
            .clip(CircleShape)
            .background(tint.copy(alpha = .14f))
            .padding(horizontal = 7.dp, vertical = 2.dp),
        style = type.caption.copy(fontWeight = FontWeight.SemiBold),
        color = tint.readableOn(palette.cell),
        maxLines = 1,
    )
}
