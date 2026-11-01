package com.getdieter.mobile.desktop

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.SaveableStateHolder
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.getdieter.client.v1.RuntimeTone
import com.getdieter.core.activity.Activity
import com.getdieter.core.workspace.WorkspaceBadge
import com.getdieter.mobile.app.*
import com.getdieter.mobile.design.*
import com.getdieter.mobile.navigation.*
import com.getdieter.mobile.store.*

/**
 * An open conversation: status, title and breadcrumb, then a tab track over its transcript and
 * panes (changes, subagents, files, terminal, processes), as the Mac's conversation header.
 */
@Composable
internal fun ConversationPanel(
    store: MobileStore,
    cardId: String,
    pane: CardPane?,
    top: MobileRoute,
    detail: List<MobileRoute>,
    holder: SaveableStateHolder,
    openUrl: (String) -> Unit,
) {
    val view by store.conversation.slice.collectAsState()
    val workspace by store.workspace.slice.collectAsState()
    val boardView by store.boards.slice.collectAsState()
    val outbox by store.workspace.outbox.collectAsState()
    // A task opened while it was created keeps its local ID; its card has the server's.
    val id = outbox.resolutions[cardId] ?: cardId
    val card = view.card?.takeIf { it.id == id } ?: workspace.cards.firstOrNull { it.id == id }
    val chat = card?.scope == "chat"
    val flags = boardView.cards[id]
    val host = remember(top.key) { DesktopChromeHost() }
    // A file or terminal opened inside a pane goes back to the pane.
    val inner = top !is MobileRoute.Conversation && top !is MobileRoute.Pane
    val project = workspace.projects.firstOrNull { it.id == card?.project_id }
    val board = workspace.boards.firstOrNull { it.id == card?.board_id }
    Column(Modifier.fillMaxSize().testTag("conversation-panel")) {
        Row(
            Modifier.fillMaxWidth().height(44.dp).padding(start = 12.dp, end = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            if (inner || detail.size > 1 && detail.first() !is MobileRoute.Conversation)
                DesktopIconButton(Glyph.BACK, "Back", store::pop, Modifier.testTag("chrome-back"))
            val tone =
                when {
                    view.state?.working == true || flags?.tone == RuntimeTone.RUNTIME_TONE_ACTIVE ->
                        tokens.running
                    flags?.tone == RuntimeTone.RUNTIME_TONE_ATTENTION -> tokens.attention
                    flags?.tone == RuntimeTone.RUNTIME_TONE_FAILED -> tokens.coral
                    else -> null
                }
            if (tone != null) {
                if (tone == tokens.running) LiveDot(tone, size = 7.dp) else StatusDot(tone)
                Spacer(Modifier.width(2.dp))
            }
            Text(
                card?.let(Activity::title) ?: if (chat) "Chat" else "Conversation",
                Modifier.weight(1f, fill = false).testTag("conversation-title"),
                color = tokens.text,
                fontSize = 14.5.sp,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            flags
                ?.runtime_label
                ?.takeIf { it.isNotEmpty() }
                ?.let { label ->
                    val tint = tone ?: tokens.subtle
                    Text(
                        label,
                        Modifier.height(20.dp)
                            .background(tint.copy(alpha = .14f), RoundedCornerShape(50))
                            .padding(horizontal = 8.dp, vertical = 3.dp),
                        color = tint,
                        fontSize = 10.5.sp,
                        fontWeight = FontWeight.SemiBold,
                        maxLines = 1,
                    )
                }
            if (view.syncing) Text("Refreshing…", color = tokens.tertiary, fontSize = 11.sp)
            Spacer(Modifier.weight(1f))
            host.chrome
                ?.actions
                ?.filterNot { it.id.startsWith("pane-") }
                ?.forEach { DesktopChromeButton(it, host) }
            DesktopIconButton(
                Glyph.CLOSE,
                "Close",
                store::closeDetail,
                Modifier.testTag("desktop-close"),
                tooltip = "Close (Ctrl+W)",
            )
        }
        val crumbs =
            listOfNotNull(
                project?.name,
                if (chat) "Chat" else board?.name,
                card?.id?.take(8),
            )
        Row(
            Modifier.fillMaxWidth().padding(start = 14.dp, end = 12.dp, bottom = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                crumbs.joinToString(" › "),
                color = tokens.tertiary,
                fontSize = 11.5.sp,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f, fill = false),
            )
            card?.let(WorkspaceBadge::of)?.let { badge ->
                Text(
                    " · ${badge.fullTitle}",
                    color = if (badge.conflicted) tokens.coral else tokens.tertiary,
                    fontSize = 11.5.sp,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
        val subagents = view.conversation?.subagents.orEmpty().size
        val changed = card?.workspace?.changed_files ?: 0
        PaneTrack(
            buildList {
                add(PaneTab(null, "Conversation", Glyph.CHAT))
                if (!chat)
                    add(PaneTab(CardPane.CHANGES, "Changes", CardPane.CHANGES.glyph, changed))
                add(PaneTab(CardPane.SUBAGENTS, "Subagents", CardPane.SUBAGENTS.glyph, subagents))
                add(PaneTab(CardPane.FILES, "Files", CardPane.FILES.glyph))
                add(PaneTab(CardPane.TERMINAL, "Terminal", CardPane.TERMINAL.glyph))
                add(PaneTab(CardPane.PROCESSES, "Processes", CardPane.PROCESSES.glyph))
            },
            pane,
        ) {
            store.showConversationPane(cardId, it)
        }
        BandRule()
        Box(Modifier.weight(1f).fillMaxWidth()) {
            CompositionLocalProvider(LocalChromeHost provides host, LocalBackAction provides null) {
                holder.SaveableStateProvider(top.key) { RouteContent(store, top, openUrl) }
            }
        }
    }
}

private class PaneTab(val pane: CardPane?, val title: String, val glyph: Glyph, val count: Int = 0)

/** The panes as one capsule track; a narrow panel names only the selected one. */
@Composable
private fun PaneTrack(tabs: List<PaneTab>, selected: CardPane?, onSelect: (CardPane?) -> Unit) =
    BoxWithConstraints(Modifier.fillMaxWidth()) {
        val compact = maxWidth < 600.dp
        PaneTrackRow(tabs, selected, compact, onSelect)
    }

@Composable
private fun PaneTrackRow(
    tabs: List<PaneTab>,
    selected: CardPane?,
    compact: Boolean,
    onSelect: (CardPane?) -> Unit,
) {
    Row(
        Modifier.fillMaxWidth()
            .padding(start = 10.dp, end = 10.dp, bottom = 8.dp)
            .horizontalScroll(rememberScrollState()),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Row(
            Modifier.height(32.dp)
                .background(tokens.inset, RoundedCornerShape(50))
                .border(1.dp, tokens.controlRim, RoundedCornerShape(50))
                .padding(3.dp),
            horizontalArrangement = Arrangement.spacedBy(2.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            tabs.forEach { tab ->
                val on = tab.pane == selected
                val named = on || !compact
                DesktopTooltip(if (named) "" else tab.title) {
                    Row(
                        Modifier.fillMaxHeight()
                            .desktopClickable(
                                { onSelect(tab.pane) },
                                RoundedCornerShape(50),
                                selected = on,
                                selectedFill = tokens.segmentThumb,
                                role = Role.Tab,
                            )
                            .padding(horizontal = 10.dp)
                            .testTag("pane-tab-${tab.pane?.name?.lowercase() ?: "conversation"}"),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(5.dp),
                    ) {
                        Icon(
                            tab.glyph,
                            if (named) null else tab.title,
                            tint = if (on) tokens.text else tokens.subtle,
                            size = 13.dp,
                        )
                        if (named)
                            Text(
                                tab.title,
                                color = if (on) tokens.text else tokens.subtle,
                                fontSize = 12.sp,
                                fontWeight = if (on) FontWeight.SemiBold else FontWeight.Medium,
                                maxLines = 1,
                            )
                        if (tab.count > 0)
                            Text(
                                "${tab.count}",
                                color = tokens.tertiary,
                                fontSize = 11.sp,
                                fontWeight = FontWeight.Medium,
                            )
                    }
                }
            }
        }
    }
}
