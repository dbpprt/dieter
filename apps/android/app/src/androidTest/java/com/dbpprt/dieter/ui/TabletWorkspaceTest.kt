package com.dbpprt.dieter.ui

import android.content.Context
import android.graphics.Bitmap
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModelStore
import androidx.test.platform.app.InstrumentationRegistry
import com.dbpprt.dieter.connection.ConnectionPhase
import com.dbpprt.dieter.connection.DieterConnectionManager
import com.dbpprt.dieter.data.DIETER_ENDPOINTS
import com.dbpprt.dieter.data.DieterEndpoint
import com.dbpprt.dieter.data.DieterRepository
import com.dbpprt.dieter.settings.AppPreferences
import com.dbpprt.dieter.settings.DieterPalette
import com.dbpprt.dieter.v1.ConversationSnapshot
import com.dbpprt.dieter.v1.Conversation
import com.dbpprt.dieter.v1.CardDetail
import com.dbpprt.dieter.v1.UiMessage
import com.dbpprt.dieter.v1.MessagePart
import com.dbpprt.dieter.settings.NavigationFolder
import com.dbpprt.dieter.settings.NavigationFolderPreferences
import com.dbpprt.dieter.ui.theme.DieterTheme
import com.dbpprt.dieter.v1.Board
import com.dbpprt.dieter.v1.Card
import com.dbpprt.dieter.v1.Lane
import com.dbpprt.dieter.v1.Project
import java.io.File
import java.lang.reflect.Proxy
import java.time.Instant
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Rule
import org.junit.Test

/** Real Android compositions with isolated data. No operator account or daemon. */
class TabletWorkspaceTest {
    @get:Rule val compose = createComposeRule()
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val lifecycle = ViewModelStore()
    private val managerScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private lateinit var model: DieterViewModel
    private val now = Instant.now()
    private val projects = listOf(project("dieter", "dieter"), project("infra", "Infrastructure"), project("atlas", "Atlas"))
    private val board = Board.newBuilder().setId("main").setProjectId("dieter").setName("Main")
        .addAllLanes(listOf("todo", "running", "review", "done").map { Lane.newBuilder().setId(it).setName(it.replaceFirstChar(Char::uppercase)).build() }).build()
    private val cards = listOf(
        card("plan", "Plan the next release", "todo"),
        card("running", "Improve Android navigation", "running", "running"),
        card("review", "Review the tablet workspace", "review"),
        card("done", "Verify connection recovery", "done"),
    )
    private val fixture get() = DieterUiState(
        loading = false, desiredConnected = false, connectionPhase = ConnectionPhase.CONNECTED,
        projects = projects, boards = listOf(board), spaceBoards = listOf(board), cards = cards, spaceCards = cards,
        selectedProjectId = "dieter", selectedBoardId = "main", selectedLane = "todo", boardOverviewVisible = false,
        pinnedProjectOrder = listOf("dieter"),
        projectFolders = NavigationFolderPreferences.from(listOf(NavigationFolder("work", "Work", listOf("infra", "atlas")))),
    )

    @Before fun setup() {
        check(context.packageName.endsWith(".e2e")) { "Tablet tests require the isolated E2E package" }
        context.getSharedPreferences("dieter_shared_kv", Context.MODE_PRIVATE).edit().clear().putString("activeAccount", "tablet-fixture").commit()
        var endpoints = DIETER_ENDPOINTS
        val repository = Proxy.newProxyInstance(DieterRepository::class.java.classLoader, arrayOf(DieterRepository::class.java)) { _, method, args ->
            when (method.name) {
                "getEndpoints" -> endpoints
                "getActiveEndpoint" -> endpoints.first()
                "replaceEndpoints" -> { @Suppress("UNCHECKED_CAST") val replacement = args!![0] as List<DieterEndpoint>; endpoints = replacement; Unit }
                "close", "reconnect" -> Unit
                else -> error("Unexpected repository call in tablet layout test: ${method.name}")
            }
        } as DieterRepository
        compose.runOnUiThread {
            model = DieterViewModel(DieterConnectionManager(context, repository, managerScope), AppPreferences(context))
            lifecycle.put("tablet", model)
        }
    }

    @After fun cleanup() {
        compose.runOnUiThread { lifecycle.clear() }
        managerScope.cancel()
    }

    @Test fun boardShowsParallelLanesAndKeepsProjectsBesideDetail() {
        var selected by mutableStateOf<String?>(null)
        compose.setContent { TabletTestSurface {
            DieterTheme(palette = DieterPalette.ULTRAVIOLET_RELAY, darkTheme = true) {
                TabletWorkspace(fixture.copy(destination = Destination.BOARD, selectedCardId = selected,
                    conversation = selected?.let { snapshot(it) }), model,
                    destinationContent = { BoardScreen(it, model, true, PaddingValues()) }, surfaceContent = {})
            }
        } }
        compose.onNodeWithTag("tablet-project-navigator").assertIsDisplayed()
        val navigatorWidth = compose.onNodeWithTag("tablet-project-navigator").fetchSemanticsNode().boundsInRoot.width
        compose.onNodeWithTag("tablet-lane-todo").assertIsDisplayed()
        compose.onNodeWithTag("tablet-lane-running").assertIsDisplayed()
        val first = compose.onNodeWithTag("tablet-lane-todo").fetchSemanticsNode().boundsInRoot
        val second = compose.onNodeWithTag("tablet-lane-running").fetchSemanticsNode().boundsInRoot
        assertTrue("Board lanes must sit beside each other", second.left >= first.right)
        capture("tablet-board")
        compose.runOnIdle { selected = "review" }
        compose.onNodeWithTag("tablet-project-navigator").assertIsDisplayed()
        compose.onNodeWithTag("tablet-projects-pane-divider").assertIsDisplayed()
        assertEquals(navigatorWidth, compose.onNodeWithTag("tablet-project-navigator").fetchSemanticsNode().boundsInRoot.width, 1f)
        visibleMessageEditor().assertIsDisplayed()
        compose.onNodeWithContentDescription("Back").assertIsDisplayed()
        capture("tablet-board-detail")
        compose.runOnIdle { selected = null }
        compose.onNodeWithTag("tablet-project-navigator").assertIsDisplayed()
    }

    @Test fun projectSearchKeepsSyncedFoldersAndBoardSelectionReachable() {
        var opened: Pair<String, String>? = null
        compose.setContent { TabletTestSurface {
            DieterTheme(palette = DieterPalette.ULTRAVIOLET_RELAY, darkTheme = true) {
                Surface(Modifier.width(320.dp).fillMaxHeight()) {
                    TabletProjectNavigator(fixture, model, Modifier.fillMaxSize(), onOpenBoard = { p, b -> opened = p to b })
                }
            }
        } }
        compose.onNodeWithText("Work").assertIsDisplayed()
        compose.onNodeWithTag("tablet-board-main").performClick()
        compose.runOnIdle { assertEquals("dieter" to "main", opened) }
        compose.onNode(hasSetTextAction()).performTextInput("Atlas")
        compose.onNodeWithTag("tablet-project-row-atlas").assertIsDisplayed()
        compose.onNodeWithTag("tablet-project-row-dieter").assertDoesNotExist()
        compose.onNode(hasSetTextAction()).performTextClearance()
        compose.onNodeWithTag("tablet-project-row-dieter").assertIsDisplayed()
    }

    @Test fun inboxTimelineUsesExistingActivityAndReturnsTheSelectedConversation() {
        var timeline by mutableStateOf(false)
        var opened: Card? = null
        compose.setContent { TabletTestSurface {
            DieterTheme(palette = DieterPalette.ULTRAVIOLET_RELAY, darkTheme = true) {
                Surface(Modifier.fillMaxSize()) {
                    Row {
                        TabletNavigationRail(Destination.ACTIVITY, false, false, 1, 2, {}, {}, {}, {}, {})
                        val feed: @Composable (Modifier) -> Unit = { modifier ->
                            ActivityFeed(fixture, modifier, { opened = it; timeline = false }, {}, {}, {}, now,
                                tablet = true, timelineOnly = timeline, onTimelineToggle = { timeline = it })
                        }
                        Box(Modifier.weight(1f).fillMaxHeight()) {
                            TabletListDetail(dividerTag = "activity-pane-divider", list = feed, detail = { modifier ->
                                Box(modifier.testTag("inbox-detail")) {
                                    CardDetailScreen(fixture.copy(selectedCardId = "review", conversation = snapshot("review")), model, Modifier.fillMaxSize(), showBack = false)
                                }
                            })
                        }
                    }
                }
            }
        } }
        compose.onNodeWithTag("inbox-detail").assertIsDisplayed()
        capture("tablet-inbox")
        compose.onNodeWithTag("tablet-inbox-timeline").performClick()
        compose.onNodeWithTag("inbox-detail").assertIsDisplayed()
        compose.onNodeWithTag("tablet-activity-timeline").assertIsDisplayed()
        capture("tablet-timeline")
        compose.onNodeWithTag("tablet-activity-running").performScrollTo().performClick()
        compose.runOnIdle { assertEquals("running", opened?.id) }
        compose.onNodeWithTag("inbox-detail").assertIsDisplayed()
    }

    @Test fun railAndSettingsRemainUsableAtLargeFontScale() {
        var settings by mutableStateOf(false)
        var selectedTab by mutableIntStateOf(0)
        var destination: Destination? = null
        compose.setContent { TabletTestSurface {
            val density = androidx.compose.ui.platform.LocalDensity.current
            CompositionLocalProvider(LocalTabletWorkspace provides true,
                androidx.compose.ui.platform.LocalDensity provides androidx.compose.ui.unit.Density(density.density, 1.5f)) {
                DieterTheme(darkTheme = false) {
                    Surface(Modifier.fillMaxSize()) {
                        Row {
                            TabletNavigationRail(Destination.CHATS, false, settings, 4, 3, { destination = it }, {}, {}, {}, { settings = true })
                            SettingsAdaptiveLayout(selectedTab, { selectedTab = it }, { settings = false }, PaddingValues()) {
                                Text("Settings content", Modifier.padding(24.dp))
                            }
                        }
                    }
                }
            }
        } }
        compose.onNodeWithTag("nav-settings").performClick()
        compose.runOnIdle { assertTrue(settings) }
        compose.onNodeWithTag("settings-display").performClick()
        compose.runOnIdle { assertEquals(2, selectedTab) }
        compose.onNodeWithTag("tablet-settings-categories").assertIsDisplayed()
        compose.onNodeWithTag("nav-chats").performClick()
        compose.runOnIdle { assertEquals(Destination.CHATS, destination) }
        capture("tablet-settings-large-text")
    }

    @Test fun portraitWidthAndResizeKeepTheSelectedConversationReadable() {
        var width by mutableFloatStateOf(1280f)
        var destination by mutableStateOf(Destination.ACTIVITY)
        compose.setContent { TabletTestSurface(width = width, height = 1000f) {
            DieterTheme(darkTheme = true) {
                TabletWorkspace(fixture.copy(destination = destination, selectedCardId = "review", conversation = snapshot("review")), model,
                    destinationContent = {
                        if (it.destination == Destination.BOARD) BoardScreen(it, model, true, PaddingValues())
                        else ActivityScreen(it, model, true, PaddingValues())
                    }, surfaceContent = {})
            }
        } }
        visibleMessageEditor().assertIsDisplayed()
        compose.runOnIdle { width = 840f }
        compose.onNodeWithTag("activity-feed").assertIsDisplayed()
        visibleMessageEditor().assertIsDisplayed()
        compose.onNodeWithTag("activity-row-review").assertIsSelected()
        val feed = compose.onNodeWithTag("activity-feed").fetchSemanticsNode().boundsInRoot
        val editor = visibleMessageEditor().fetchSemanticsNode().boundsInRoot
        assertTrue("The editor must remain beside the list", editor.left >= feed.right)
        assertTrue("The editor must have usable width", editor.width >= feed.width)
        capture("tablet-portrait")
        compose.runOnIdle { destination = Destination.BOARD }
        compose.onNodeWithTag("tablet-project-navigator").assertIsDisplayed()
        visibleMessageEditor().assertIsDisplayed()
        val projects = compose.onNodeWithTag("tablet-project-navigator").fetchSemanticsNode().boundsInRoot
        val projectEditor = visibleMessageEditor().fetchSemanticsNode().boundsInRoot
        assertTrue("Project content must remain beside its navigator", projectEditor.left >= projects.right)
        assertTrue("The project editor must have usable width", projectEditor.width >= projects.width)
        capture("tablet-projects-portrait")
        compose.runOnIdle { destination = Destination.ACTIVITY }
        compose.runOnIdle { width = 1280f }
        compose.onNodeWithTag("activity-row-review").assertIsSelected()
        visibleMessageEditor().assertIsDisplayed()
    }

    @Test fun activityKeepsContentBesideListTimelineAndEmptySelection() {
        var selected by mutableStateOf<String?>(null)
        compose.setContent { TabletTestSurface {
            DieterTheme(darkTheme = true) {
                TabletWorkspace(fixture.copy(destination = Destination.ACTIVITY, selectedCardId = selected,
                    conversation = selected?.let(::snapshot)), model,
                    destinationContent = { ActivityScreen(it, model, true, PaddingValues()) }, surfaceContent = {})
            }
        } }
        compose.onNodeWithText("Your inbox").assertIsDisplayed()
        val width = compose.onNodeWithTag("activity-feed").fetchSemanticsNode().boundsInRoot.width
        compose.runOnIdle { selected = "review" }
        visibleMessageEditor().assertIsDisplayed()
        compose.onNodeWithTag("tablet-inbox-timeline").performClick()
        compose.onNodeWithTag("tablet-activity-timeline").assertIsDisplayed()
        visibleMessageEditor().assertIsDisplayed()
        assertEquals(width, compose.onNodeWithTag("activity-feed").fetchSemanticsNode().boundsInRoot.width, 1f)
        compose.onNodeWithTag("tablet-inbox-list").performClick()
        // Review cards without unread replies sort into Recent, sometimes offscreen.
        compose.onNodeWithTag("activity-feed").performScrollToNode(hasTestTag("activity-row-review"))
        compose.onNodeWithTag("activity-row-review").assertIsSelected()
        compose.runOnIdle { selected = null }
        compose.onNodeWithText("Your inbox").assertIsDisplayed()
        assertEquals(width, compose.onNodeWithTag("activity-feed").fetchSemanticsNode().boundsInRoot.width, 1f)
        capture("tablet-inbox-empty")
    }

    @Test fun sidebarDragsPersistIndependentlyAcrossRecreation() {
        var destination by mutableStateOf(Destination.ACTIVITY)
        var restoredPreferences by mutableStateOf<AppPreferences?>(null)
        var generation by mutableIntStateOf(0)
        var width by mutableFloatStateOf(1280f)
        compose.setContent { TabletTestSurface(width = width) {
            val live by model.state.collectAsState()
            key(generation) {
                DieterTheme(darkTheme = true) {
                    TabletWorkspace(fixture.copy(destination = destination, boardOverviewVisible = true,
                        activityPaneLeadingFraction = restoredPreferences?.activityPaneLeadingFraction?.value ?: live.activityPaneLeadingFraction,
                        projectsPaneLeadingFraction = restoredPreferences?.projectsPaneLeadingFraction?.value ?: live.projectsPaneLeadingFraction), model,
                        destinationContent = { ActivityScreen(it, model, true, PaddingValues()) }, surfaceContent = {})
                }
            }
        } }
        fun paneWidth(tag: String) = compose.onNodeWithTag(tag).fetchSemanticsNode().boundsInRoot.width
        fun drag(tag: String, distance: Float) = compose.onNodeWithTag(tag).performTouchInput {
            down(center)
            moveBy(Offset(distance, 0f), delayMillis = 500)
            up()
        }
        val originalActivityWidth = paneWidth("activity-feed")
        drag("activity-pane-divider", 60f)
        val activityWidth = paneWidth("activity-feed")
        assertTrue(activityWidth > originalActivityWidth)
        compose.runOnIdle { destination = Destination.BOARD }
        val originalProjectsWidth = paneWidth("tablet-project-navigator")
        drag("tablet-projects-pane-divider", 100f)
        val projectsWidth = paneWidth("tablet-project-navigator")
        assertTrue(projectsWidth > originalProjectsWidth)
        compose.runOnIdle {
            restoredPreferences = AppPreferences(context)
            generation += 1
        }
        assertEquals(projectsWidth, paneWidth("tablet-project-navigator"), 1f)
        compose.runOnIdle { destination = Destination.ACTIVITY }
        assertEquals(activityWidth, paneWidth("activity-feed"), 1f)
        compose.runOnIdle { width = 840f }
        compose.onNodeWithText("Your inbox").assertIsDisplayed()
        compose.runOnIdle { width = 1280f }
        assertEquals(activityWidth, paneWidth("activity-feed"), 1f)
        compose.runOnIdle { destination = Destination.BOARD }
        assertEquals(projectsWidth, paneWidth("tablet-project-navigator"), 1f)
        capture("tablet-projects-resized")
    }

    @Test fun longPressActionsKeepTabletDetailVisibleInListAndTimeline() {
        var timeline by mutableStateOf(false)
        var opened: String? = null
        val archived = mutableListOf<String>()
        val renamed = mutableListOf<Pair<String, String>>()
        compose.setContent { TabletTestSurface {
            DieterTheme(darkTheme = true) {
                TabletListDetail(dividerTag = "activity-pane-divider", list = { modifier ->
                    ActivityFeed(fixture, modifier, { opened = it.id }, {}, {}, {}, now,
                        tablet = true, timelineOnly = timeline, onTimelineToggle = { timeline = it },
                        actions = ActivityItemActions({ card, title -> renamed += card.id to title },
                            { archived += it.id }, {}))
                }, detail = { modifier ->
                    CardDetailScreen(fixture.copy(selectedCardId = "review", conversation = snapshot("review")),
                        model, modifier, showBack = false)
                })
            }
        } }
        val editor = visibleMessageEditor().fetchSemanticsNode().boundsInRoot
        compose.onNodeWithTag("activity-feed").performScrollToNode(hasTestTag("activity-row-running"))
        compose.onNodeWithTag("activity-row-running").performTouchInput { longClick() }
        compose.onNodeWithTag("activity-rename-running").performClick()
        compose.onNodeWithTag("activity-rename-title-running").performTextReplacement("Renamed from tablet")
        compose.onNodeWithTag("activity-rename-confirm-running").performClick()
        compose.runOnIdle { assertEquals(listOf("running" to "Renamed from tablet"), renamed); assertNull(opened) }
        assertEquals(editor, visibleMessageEditor().fetchSemanticsNode().boundsInRoot)
        compose.onNodeWithTag("activity-feed").performScrollToNode(hasTestTag("tablet-inbox-timeline"))
        compose.onNodeWithTag("tablet-inbox-timeline").performClick()
        compose.onNodeWithTag("tablet-activity-running").performScrollTo().performTouchInput { longClick() }
        compose.onNodeWithTag("activity-archive-running").performClick()
        compose.runOnIdle { assertEquals(listOf("running"), archived); assertNull(opened) }
        visibleMessageEditor().assertIsDisplayed()
        assertEquals(editor, visibleMessageEditor().fetchSemanticsNode().boundsInRoot)
    }

    private fun visibleMessageEditor(): SemanticsNodeInteraction {
        // Pager precomposition can retain an offscreen editor. Assert that exactly
        // one editor is visible, then measure that editor through each resize.
        val editors = compose.onAllNodes(hasTestTag("message-input") and hasSetTextAction())
        val visible = editors.fetchSemanticsNodes().indices.filter { editors[it].isDisplayed() }
        assertEquals("Expected one visible composer: ${editors.fetchSemanticsNodes().map { it.boundsInRoot }}", 1, visible.size)
        return editors[visible.single()]
    }

    @Composable
    private fun TabletTestSurface(width: Float = 1280f, height: Float = 800f, content: @Composable () -> Unit) {
        val density = androidx.compose.ui.platform.LocalDensity.current
        BoxWithConstraints(Modifier.fillMaxSize()) {
            val scale = minOf(maxWidth.value / width, maxHeight.value / height)
            CompositionLocalProvider(androidx.compose.ui.platform.LocalDensity provides
                androidx.compose.ui.unit.Density(density.density * scale, density.fontScale)) {
                Box(Modifier.requiredSize(width.dp, height.dp).testTag("tablet-test-surface")) { content() }
            }
        }
    }

    private fun capture(name: String) {
        File(context.getExternalFilesDir(null), "$name.png").outputStream().use {
            assertTrue(compose.onNodeWithTag("tablet-test-surface").captureToImage().asAndroidBitmap().compress(Bitmap.CompressFormat.PNG, 100, it))
        }
        File(context.getExternalFilesDir(null), "$name.txt").writeText(compose.onRoot().printToString())
    }
    private fun snapshot(id: String): ConversationSnapshot {
        val card = cards.first { it.id == id }
        return ConversationSnapshot.newBuilder()
            .setDetail(CardDetail.newBuilder().setCard(card).setProject(projects.first()).setBoard(board))
            .setConversation(Conversation.newBuilder().setCardId(id).setStatus("idle")
                .addMessages(UiMessage.newBuilder().setId("request").setRole("user")
                    .addParts(MessagePart.newBuilder().setType("text").setText("Review the tablet layout and keep the Fold experience intact.")))
                .addMessages(UiMessage.newBuilder().setId("response").setRole("assistant")
                    .addParts(MessagePart.newBuilder().setType("text").setText(
                        "The tablet workspace is ready for review.\n\n### What changed\n\n" +
                            "- Project navigation stays beside the board.\n- Workflow lanes use the available width.\n" +
                            "- Conversations open beside the list, so your context stays visible.\n\n" +
                            "Phone and Fold windows keep their existing navigation. The layout uses the same conversations, files, and schedules."))))
            .build()
    }

    private fun project(id: String, name: String) = Project.newBuilder().setId(id).setName(name).setPath("/work/$id").build()
    private fun card(id: String, title: String, lane: String, runtime: String = "idle") = Card.newBuilder()
        .setId(id).setTitle(title).setProjectId("dieter").setBoardId("main").setLane(lane).setRuntime(runtime)
        .setInitialPromptSentAt(now.minusSeconds(1200).toString()).setRuntimeUpdatedAt(now.minusSeconds(600).toString())
        .setUpdatedAt(now.minusSeconds(600).toString()).build()
}
