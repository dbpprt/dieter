package com.getdieter.mobile.conversation

import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import com.getdieter.client.v1.MemoryDreamState
import com.getdieter.mobile.design.*
import com.getdieter.mobile.store.MobileStore

/**
 * A dream conversation's dream: what it did and changed, laid out by the core, with the actions its
 * status allows (Apply and Discard while it awaits review, Undo once applied).
 */
@Composable
internal fun MemoryDreamBanner(
    store: MobileStore,
    dream: MemoryDreamState,
    modifier: Modifier = Modifier,
) {
    val apply = dream.can_apply
    val undo = !apply && dream.can_undo
    Banner(
        dream.title,
        listOf(dream.counts_label, dream.error, dream.detail)
            .filter { it.isNotEmpty() }
            .joinToString("\n"),
        modifier.testTag("memory-dream"),
        tone =
            when {
                dream.error.isNotEmpty() -> Tone.DANGER
                apply -> Tone.WARNING
                else -> Tone.NEUTRAL
            },
        glyph = if (dream.error.isNotEmpty()) null else Glyph.MOON,
        actionLabel =
            when {
                apply -> "Apply"
                undo -> "Undo"
                else -> null
            },
        onAction =
            when {
                apply -> store.conversation::applyDream
                undo -> store.conversation::undoDream
                else -> null
            },
        secondaryLabel = if (dream.can_discard) "Discard" else null,
        onSecondary = if (dream.can_discard) store.conversation::discardDream else null,
    )
}
