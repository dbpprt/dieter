package com.dbpprt.dieter.ui

import android.graphics.Bitmap
import androidx.compose.foundation.layout.*
import androidx.compose.material3.Scaffold
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.test.platform.app.InstrumentationRegistry
import com.dbpprt.dieter.connection.ConnectionPhase
import com.dbpprt.dieter.connection.EndpointConnection
import com.dbpprt.dieter.gateway.v1.*
import com.dbpprt.dieter.ui.theme.DieterTheme
import com.dbpprt.dieter.v1.Board
import com.dbpprt.dieter.v1.Card
import com.dbpprt.dieter.v1.CardStateField
import com.dbpprt.dieter.v1.CardStateVersion
import com.dbpprt.dieter.v1.Project
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import java.io.File
import java.time.Instant

class ActivityScreenTest {
    @get:Rule val compose = createComposeRule()
    private val now = Instant.parse("2026-09-21T12:00:00Z")
    private val provider = ProviderQuotaProvider.PROVIDER_QUOTA_PROVIDER_OPENAI_CODEX
    private fun card(id: String, title: String, runtime: String, project: String = "dieter", chat: Boolean = false) =
        Card.newBuilder().setId(id).setTitle(title).setProjectId(project).setBoardId(if (chat) "" else "main")
            .setOwnerDaemonId(if (chat) "mac" else "linux")
            .setScope(if (chat) "chat" else "card").setInitialPromptSentAt(now.minusSeconds(1800).toString()).setRuntime(runtime).setLane(if (runtime == "idle") "review" else "running")
            .setRuntimeUpdatedAt(now.minusSeconds(1200).toString()).setUpdatedAt(now.minusSeconds(1200).toString()).build()
    private val account = ProviderQuotaSnapshot.newBuilder().setAccountKey("account-one").setProvider(provider)
        .setDisplayEmail("developer@example.com").setFreshUntil(now.plusSeconds(300).toString())
        .setAvailability(ProviderQuotaAvailability.PROVIDER_QUOTA_AVAILABILITY_AVAILABLE)
        .addWindows(ProviderQuotaWindow.newBuilder().setLabel("5-hour").setRemainingPercent(72).setResetsAt(now.plusSeconds(7200).toString()))
        .addWindows(ProviderQuotaWindow.newBuilder().setLabel("Weekly").setRemainingPercent(41)).build()
    private val state get() = DieterUiState(
        connectionPhase = ConnectionPhase.CONNECTED,
        endpointConnections = listOf(
            EndpointConnection("linux", "garuda", "", daemonId = "linux"),
            EndpointConnection("mac", "MacBook Pro", "", daemonId = "mac"),
        ),
        projects = listOf(Project.newBuilder().setId("dieter").setName("dieter").build(), Project.newBuilder().setId("atlas").setName("atlas").build()),
        spaceBoards = listOf(Board.newBuilder().setId("main").setName("Main").build()),
        spaceCards = listOf(card("review", "Understand the code", "idle"), card("running", "Migrate schedule store", "running")),
        chats = listOf(card("answer", "Agent asked a question", "waiting_for_user", chat = true),
            card("chat-running", "Explore navigation", "running", "atlas", chat = true)),
        providerQuotaGroups = listOf(ProviderQuotaGroup.newBuilder().setProvider(provider).addAccounts(account).build()),
    )

    @Test fun mixedActivityFiltersAndOpensBothConversationTypesAndAccount() {
        var opened: Card? = null
        var openedAccount: String? = null
        compose.setContent {
            DieterTheme {
                ActivityFeed(state, Modifier.fillMaxSize(), { opened = it }, {}, { openedAccount = it.accountKey }, {}, now)
            }
        }
        compose.onNodeWithTag("activity-range").performClick()
        compose.onNodeWithTag("activity-range-6").performClick()
        compose.onNodeWithTag("activity-timeline-expand").performClick()
        compose.onNodeWithTag("activity-bar-chat-running").performClick()
        compose.runOnIdle { assertEquals("chat", opened?.scope) }
        compose.onNodeWithTag("activity-feed").performScrollToNode(hasTestTag("activity-project-dieter"))
        compose.onNodeWithTag("activity-project-dieter").performClick()
        compose.onNodeWithTag("activity-timeline-expand").performClick()
        compose.onNodeWithTag("activity-bar-chat-running").assertDoesNotExist()
        compose.onNodeWithTag("activity-feed").performScrollToNode(hasTestTag("activity-row-review"))
        compose.onNodeWithTag("activity-row-review").performClick()
        compose.runOnIdle { assertEquals("card", opened?.scope) }
        compose.onNodeWithTag("activity-feed").performScrollToNode(hasTestTag("activity-row-answer"))
        compose.onNodeWithTag("activity-row-answer").performClick()
        compose.runOnIdle { assertEquals("chat", opened?.scope) }
        compose.onNodeWithTag("activity-feed").performScrollToNode(hasTestTag("activity-account-account-one"))
        compose.onNodeWithText("5-hour · 72% remaining").assertIsDisplayed()
        compose.onNodeWithTag("activity-account-account-one").performClick()
        compose.runOnIdle { assertEquals("account-one", openedAccount) }
    }

    @Test fun olderChatsRemainReachableBesideCardsInAllAndProjectFeeds() {
        val recentCards = (1..25).map { index ->
            card("newer-$index", "Newer card $index", "idle").toBuilder()
                .setLane("done")
                .setRuntimeUpdatedAt(now.minusSeconds(index.toLong()).toString())
                .build()
        }
        val olderChat = card("older-chat", "Older project chat", "idle", chat = true)
            .toBuilder().setRuntimeUpdatedAt(now.minusSeconds(3600).toString()).build()
        val otherChat = card("other-chat", "Other project chat", "idle", "atlas", chat = true)
            .toBuilder().setRuntimeUpdatedAt(now.minusSeconds(7200).toString()).build()
        val mixed = state.copy(spaceCards = recentCards, chats = listOf(olderChat, otherChat))
        var opened: Card? = null
        compose.setContent {
            DieterTheme { ActivityFeed(mixed, onOpen = { opened = it }, onConnections = {},
                onAccount = {}, onRefreshAccounts = {}, clock = now) }
        }
        compose.onNodeWithTag("activity-feed").performScrollToNode(hasTestTag("activity-row-other-chat"))
        compose.onNodeWithTag("activity-row-other-chat").performClick()
        compose.runOnIdle { assertEquals(otherChat.id, opened?.id) }
        compose.onNodeWithTag("activity-feed").performScrollToNode(hasTestTag("activity-project-dieter"))
        compose.onNodeWithTag("activity-project-dieter").performClick()
        compose.onNodeWithTag("activity-feed").performScrollToNode(hasTestTag("activity-row-older-chat"))
        compose.onNodeWithTag("activity-row-older-chat").performClick()
        compose.runOnIdle { assertEquals(olderChat.id, opened?.id) }
        compose.onNodeWithTag("activity-feed").performScrollToNode(hasTestTag("activity-project-atlas"))
        compose.onNodeWithTag("activity-project-atlas").performClick()
        compose.onNodeWithTag("activity-feed").performScrollToNode(hasTestTag("activity-row-other-chat"))
        compose.onNodeWithTag("activity-row-other-chat").assertIsDisplayed()
    }

    @Test fun searchAndEmptyResultsKeepAccountsAvailable() {
        compose.setContent { DieterTheme { ActivityFeed(state, onOpen = {}, onConnections = {}, onAccount = {}, onRefreshAccounts = {}, clock = now) } }
        compose.onNodeWithContentDescription("Search activity").performClick()
        compose.onNodeWithTag("activity-search").performTextInput("no such conversation")
        compose.onNodeWithTag("activity-feed").performScrollToNode(hasText("No matching activity"))
        compose.onNodeWithText("No matching activity").assertIsDisplayed()
        compose.onNodeWithTag("activity-feed").performScrollToNode(hasTestTag("activity-account-account-one"))
        compose.onNodeWithText("Weekly · 41% remaining").performScrollTo().assertIsDisplayed()
    }

    @Test fun referenceLayoutDarkLightLargeTextAndUnavailableUsage() {
        var dark by mutableStateOf(true)
        var fontScale by mutableFloatStateOf(1f)
        var current by mutableStateOf(state)
        compose.setContent {
            val density = LocalDensity.current
            CompositionLocalProvider(LocalDensity provides Density(density.density, fontScale)) {
                DieterTheme(darkTheme = dark) {
                    Scaffold(bottomBar = { DieterBottomBar(Destination.ACTIVITY, {}, {}) }) { padding ->
                        ActivityFeed(current, Modifier.fillMaxSize().padding(padding), {}, {}, {}, {}, now)
                    }
                }
            }
        }
        compose.onNodeWithTag("nav-activity").assertIsSelected()
        capture("activity-dark.png")
        compose.onNodeWithTag("activity-feed").performScrollToNode(hasTestTag("activity-row-running"))
        capture("activity-cards-dark.png")
        compose.onNodeWithTag("activity-feed").performScrollToNode(hasTestTag("activity-account-account-one"))
        capture("activity-accounts.png")
        compose.runOnIdle { dark = false; fontScale = 1.5f }
        compose.onNodeWithText("Weekly · 41% remaining").performScrollTo().assertIsDisplayed()
        capture("activity-light-large-text.png")
        compose.onNodeWithTag("activity-feed").performScrollToNode(hasTestTag("activity-row-running"))
        capture("activity-cards-light-large-text.png")
        compose.runOnIdle {
            current = state.copy(connectionPhase = ConnectionPhase.UNAVAILABLE,
                lastConnectedAtMillis = now.minusSeconds(60).toEpochMilli(),
                providerQuotaGroups = listOf(ProviderQuotaGroup.newBuilder().setProvider(provider).addAccounts(
                    account.toBuilder().clearWindows().setAvailability(ProviderQuotaAvailability.PROVIDER_QUOTA_AVAILABILITY_TEMPORARILY_UNAVAILABLE),
                ).build()))
        }
        compose.onNodeWithTag("activity-feed").performScrollToNode(hasText("Usage windows unavailable"))
        compose.onNodeWithText("Usage windows unavailable").assertIsDisplayed()
        compose.onNodeWithText("0% remaining", substring = true).assertDoesNotExist()
        compose.onNodeWithTag("activity-feed").performScrollToNode(hasTestTag("activity-timeline"))
        compose.onNodeWithText("CACHED").assertIsDisplayed()
    }

    @Test fun cardsShowLatestActivityAndOwningMachineAcrossUpdatesAndOffline() {
        val running = card("running", "Polish the Inbox cards", "running").toBuilder()
            .setRuntimeUpdatedAt(now.minusSeconds(7200).toString())
            .setLastActivityAt(now.minusSeconds(120).toString()).build()
        var current by mutableStateOf(state.copy(spaceCards = listOf(running)))
        var clock by mutableStateOf(now)
        compose.setContent { DieterTheme {
            ActivityFeed(current, onOpen = {}, onConnections = {}, onAccount = {}, onRefreshAccounts = {}, clock = clock)
        } }
        compose.onNodeWithTag("activity-feed").performScrollToNode(hasTestTag("activity-row-running"))
        compose.onNodeWithTag("activity-age-running", useUnmergedTree = true)
            .assertContentDescriptionEquals("Last activity: 2m ago").assertIsDisplayed()
        compose.onNodeWithTag("activity-machine-running", useUnmergedTree = true)
            .assertContentDescriptionEquals("Machine: garuda").assertIsDisplayed()
        compose.runOnIdle {
            current = current.copy(spaceCards = listOf(running.toBuilder().setLastActivityAt(now.toString()).build()))
        }
        compose.onNodeWithTag("activity-age-running", useUnmergedTree = true)
            .assertContentDescriptionEquals("Last activity: Just now")
        compose.runOnIdle {
            current = current.copy(connectionPhase = ConnectionPhase.UNAVAILABLE, lastConnectedAtMillis = now.toEpochMilli())
            clock = now.plusSeconds(180)
        }
        compose.onNodeWithTag("activity-age-running", useUnmergedTree = true)
            .assertContentDescriptionEquals("Last activity: 3m ago")
        compose.onNodeWithTag("activity-feed").performScrollToNode(hasTestTag("activity-row-answer"))
        compose.onNodeWithTag("activity-age-answer", useUnmergedTree = true).assertIsDisplayed()
        compose.onNodeWithTag("activity-machine-answer", useUnmergedTree = true)
            .assertContentDescriptionEquals("Machine: MacBook Pro").assertIsDisplayed()
    }

    @Test fun streamingRowsKeepTheirOrderAndStaleCopiesCannotRestoreRunning() {
        val older = card("older", "Earlier turn", "running").toBuilder()
            .setRuntimeUpdatedAt(now.minusSeconds(7200).toString()).build()
        val newer = card("newer", "Later turn", "running", chat = true).toBuilder()
            .setRuntimeUpdatedAt(now.minusSeconds(3600).toString()).build()
        var current by mutableStateOf(state.copy(spaceCards = listOf(older), chats = listOf(newer), providerQuotaGroups = emptyList()))
        compose.setContent { DieterTheme {
            ActivityFeed(current, onOpen = {}, onConnections = {}, onAccount = {}, onRefreshAccounts = {}, clock = now)
        } }
        fun assertOrder() {
            compose.onNodeWithTag("activity-feed").performScrollToNode(hasTestTag("activity-row-newer"))
            val first = compose.onNodeWithTag("activity-row-newer").fetchSemanticsNode().boundsInRoot.top
            val second = compose.onNodeWithTag("activity-row-older").fetchSemanticsNode().boundsInRoot.top
            assertTrue("Streaming updates moved the earlier turn ahead of the later turn", first < second)
        }
        assertOrder()
        for (id in listOf("older", "newer", "older")) {
            compose.runOnIdle {
                current = current.copy(
                    spaceCards = listOf(older.toBuilder().setLastActivityAt(now.minusSeconds(if (id == "older") 0 else 60).toString()).build()),
                    chats = listOf(newer.toBuilder().setLastActivityAt(now.minusSeconds(if (id == "newer") 0 else 60).toString()).build()),
                )
            }
            assertOrder()
            compose.onNodeWithTag("activity-age-$id", useUnmergedTree = true)
                .assertContentDescriptionEquals("Last activity: Just now")
        }
        fun versioned(value: Card, sequence: Long) = value.toBuilder().apply {
            for (name in listOf("summary", "placement")) {
                addStateFields(CardStateField.newBuilder().setName(name).setRevision("$name-$sequence")
                    .addVersions(CardStateVersion.newBuilder().putClock("owner", sequence)
                        .setRank(sequence.toString()).setValue(value)))
            }
        }.build()
        val complete = versioned(older.toBuilder().setRuntime("idle").setLane("review")
            .setRuntimeUpdatedAt(now.toString()).build(), 2)
        val stale = versioned(older, 1).toBuilder().setUpdatedAt(now.plusSeconds(60).toString()).build()
        for (copies in listOf(listOf(complete, stale), listOf(stale, complete), listOf(complete, stale))) {
            compose.runOnIdle { current = current.copy(spaceCards = listOf(copies[0]), cards = listOf(copies[1])) }
            compose.onNodeWithTag("activity-feed").performScrollToNode(hasTestTag("activity-row-older"))
            compose.onNodeWithTag("activity-row-older").assertTextContains("Ready for review")
        }
    }

    @Test fun narrowCardKeepsTimeAndMachineAccessibleWithLargeText() {
        val entry = buildActivityEntries(listOf(card("narrow", "Make the Inbox feel thoughtful, clear, and a little more delightful", "waiting_for_user"))).single()
        val machine = "Development workstation with a very long machine name"
        var dark by mutableStateOf(true)
        compose.setContent {
            val density = LocalDensity.current
            CompositionLocalProvider(LocalDensity provides Density(density.density, 2f)) {
                DieterTheme(darkTheme = dark) {
                    Box(Modifier.width(320.dp).padding(12.dp)) {
                        ActivityRow(entry, "A long project name", "Main", machine, now) {}
                    }
                }
            }
        }
        compose.onNodeWithTag("activity-age-narrow", useUnmergedTree = true)
            .assertContentDescriptionEquals("Last activity: 20m ago").assertIsDisplayed()
        compose.onNodeWithTag("activity-machine-narrow", useUnmergedTree = true)
            .assertContentDescriptionEquals("Machine: $machine").assertIsDisplayed()
        capture("activity-card-narrow-dark.png")
        compose.runOnIdle { dark = false }
        compose.onNodeWithTag("activity-machine-narrow", useUnmergedTree = true).assertIsDisplayed()
        capture("activity-card-narrow-light.png")
    }

    @Test fun longPressRenamesArchivesAndPinsWithoutOpeningTheConversation() {
        var current by mutableStateOf(state)
        val opened = mutableListOf<String>()
        val renamed = mutableListOf<Pair<String, String>>()
        val archived = mutableListOf<String>()
        val pinned = mutableListOf<String>()
        val moved = mutableListOf<String>()
        compose.setContent { DieterTheme {
            ActivityFeed(current, onOpen = { opened += it.id }, onConnections = {}, onAccount = {},
                onRefreshAccounts = {}, clock = now, actions = ActivityItemActions(
                    onRename = { card, title ->
                        renamed += card.id to title
                        current = current.copy(spaceCards = current.spaceCards.map {
                            if (it.id == card.id) it.toBuilder().setTitle(title).build() else it
                        })
                    },
                    onArchive = { archived += it.id }, onTogglePin = { pinned += it.id },
                    onMoveToFolder = { moved += it.id },
                ))
        } }
        fun longPress(id: String) {
            compose.onNodeWithTag("activity-feed").performScrollToNode(hasTestTag("activity-row-$id"))
            compose.onNodeWithTag("activity-row-$id").performTouchInput { longClick() }
            compose.runOnIdle { assertTrue("Long press must not open the conversation", opened.isEmpty()) }
        }
        longPress("review")
        compose.onNodeWithTag("activity-pin-review").assertDoesNotExist()
        compose.onNodeWithTag("activity-folder-review").assertDoesNotExist()
        compose.onNodeWithTag("activity-rename-review").performClick()
        compose.onNodeWithTag("activity-rename-title-review").performTextReplacement("   ")
        compose.onNodeWithTag("activity-rename-confirm-review").assertIsNotEnabled()
        compose.onNodeWithText("Cancel").performClick()
        compose.runOnIdle { assertTrue(renamed.isEmpty()) }
        longPress("review")
        compose.onNodeWithTag("activity-rename-review").performClick()
        compose.onNodeWithTag("activity-rename-title-review").performTextReplacement("  New card title  ")
        compose.onNodeWithTag("activity-rename-confirm-review").performClick()
        compose.runOnIdle { assertEquals(listOf("review" to "New card title"), renamed) }
        longPress("review")
        compose.onNodeWithTag("activity-archive-review").performClick()
        compose.runOnIdle { assertEquals(listOf("review"), archived) }
        longPress("answer")
        compose.onNodeWithTag("activity-pin-answer").performClick()
        compose.runOnIdle {
            assertEquals(listOf("answer"), pinned)
            current = current.copy(chats = current.chats.map { if (it.id == "answer") it.toBuilder().setPinned(true).build() else it })
        }
        longPress("answer")
        compose.onNodeWithText("Unpin").assertIsDisplayed()
        compose.onNodeWithTag("activity-folder-answer").performClick()
        compose.runOnIdle { assertEquals(listOf("answer"), moved) }
        longPress("answer")
        compose.onNodeWithTag("activity-archive-answer").performClick()
        compose.runOnIdle { assertEquals(listOf("review", "answer"), archived) }
        compose.onNodeWithTag("activity-row-answer").performClick()
        compose.runOnIdle { assertEquals(listOf("answer"), opened) }
    }

    @Test fun timelineSupportsLongPressAndOfflineActionsStayDisabled() {
        var online by mutableStateOf(true)
        var opened: String? = null
        compose.setContent { DieterTheme {
            ActivityFeed(state, onOpen = { opened = it.id }, onConnections = {}, onAccount = {}, onRefreshAccounts = {},
                clock = now, actions = ActivityItemActions({ _, _ -> fail("Unexpected rename") },
                    { fail("Unexpected archive") }, { fail("Unexpected pin") }, enabled = online))
        } }
        compose.onNodeWithTag("activity-timeline-expand").performClick()
        compose.onNodeWithTag("activity-bar-chat-running").performTouchInput { longClick() }
        compose.onNodeWithTag("activity-rename-chat-running").assertIsEnabled()
        compose.runOnIdle { online = false }
        compose.onNodeWithTag("activity-rename-chat-running").assertIsNotEnabled()
        compose.onNodeWithTag("activity-archive-chat-running").assertIsNotEnabled()
        compose.onNodeWithTag("activity-pin-chat-running").assertIsNotEnabled()
        compose.onNodeWithTag("activity-open-chat-running").performClick()
        compose.runOnIdle { assertEquals("chat-running", opened) }
        compose.onNodeWithTag("activity-feed").performScrollToNode(hasTestTag("activity-row-answer"))
        compose.onNodeWithTag("activity-row-answer").performSemanticsAction(SemanticsActions.OnLongClick) { it() }
        compose.onNodeWithTag("activity-archive-answer").assertIsNotEnabled()
    }

    private fun capture(name: String) {
        compose.waitForIdle()
        val dir = File(InstrumentationRegistry.getInstrumentation().targetContext.getExternalFilesDir(null), "activity-evidence").apply { mkdirs() }
        File(dir, name).outputStream().use { compose.onRoot().captureToImage().asAndroidBitmap().compress(Bitmap.CompressFormat.PNG, 100, it) }
    }
}
