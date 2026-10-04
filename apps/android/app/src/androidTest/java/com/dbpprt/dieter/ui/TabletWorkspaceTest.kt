package com.dbpprt.dieter.ui

import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModelStore
import androidx.test.platform.app.InstrumentationRegistry
import com.dbpprt.dieter.core.board.BoardTarget
import com.dbpprt.dieter.core.board.BoardViews
import com.dbpprt.dieter.core.connection.ConnectionPhase
import com.dbpprt.dieter.core.navigation.Destination
import com.dbpprt.dieter.e2e.TestCore
import com.dbpprt.dieter.e2e.Evidence
import com.dbpprt.dieter.e2e.saveEvidence
import com.dbpprt.dieter.settings.AppPreferences
import com.dbpprt.dieter.settings.DieterPalette
import com.dbpprt.dieter.api.v1.ConversationSnapshot
import com.dbpprt.dieter.api.v1.Conversation
import com.dbpprt.dieter.api.v1.CardDetail
import com.dbpprt.dieter.api.v1.UiMessage
import com.dbpprt.dieter.api.v1.MessagePart
import com.dbpprt.dieter.core.navigation.NavigationFolder
import com.dbpprt.dieter.ui.theme.DieterTheme
import com.dbpprt.dieter.ui.theme.DieterSurface
import com.dbpprt.dieter.api.v1.Board
import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.Lane
import com.dbpprt.dieter.api.v1.Project
import com.dbpprt.dieter.core.activity.Activity
import java.time.Instant
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Rule
import org.junit.Test

/** Real Android compositions with isolated data. No operator account or daemon. */
class TabletWorkspaceTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext
    private val lifecycle = ViewModelStore()
    private lateinit var core: TestCore
    private lateinit var model: DieterViewModel
    private val now = Instant.now()
    private val projects = listOf(project("dieter", "dieter"), project("infra", "Infrastructure"), project("atlas", "Atlas"))
    private val board = Board(id = "main", project_id = "dieter", name = "Main", lanes = listOf("todo", "running", "review", "done").map { Lane(id = it, name = it.replaceFirstChar(Char::uppercase)) }.toList())
    private val cards = listOf(
        card("plan", "Plan the next release", "todo"),
        card("running", "Improve Android navigation", "running", "running"),
        card("review", "Review the tablet workspace", "review"),
        card("done", "Verify connection recovery", "done"),
    )
    private val fixture get() = DieterUiState(
        loading = false, desiredConnected = false, connectionPhase = ConnectionPhase.CONNECTED,
        endpointConnections = listOf(com.dbpprt.dieter.core.machines.MachineRow(
            id = "tablet-host", label = "mini-home", address = "https://fixture.invalid", daemonId = "tablet-host",
        )),
        projects = projects, boards = listOf(board), spaceBoards = listOf(board), cards = cards, spaceCards = cards,
        activityItems = Activity.project(cards, emptyMap(), projects, listOf(board)),
        selectedProjectId = "dieter", selectedBoardId = "main", selectedLane = "todo", boardOverviewVisible = false,
        pinnedProjectOrder = listOf("dieter"),
        projectFolders = listOf(NavigationFolder("work", "Work", listOf("infra", "atlas"))),
    )

    @Before fun setup() {
        check(context.packageName.endsWith(".e2e")) { "Tablet tests require the isolated E2E package" }
        core = TestCore(navigationAccount = "component-fixture")
        compose.runOnUiThread {
            model = core.viewModel(withCaptures = true)
            lifecycle.put("tablet", model)
        }
        compose.waitUntil(5_000) { core.core.captures.view.value.bound }
    }

    @After fun cleanup() {
        compose.runOnUiThread { lifecycle.clear() }
        core.close()
        core.delete()
    }

    @Test fun sidebarBackgroundCoversSystemBarsWhileControlsStayInsideInsets() {
        var destination by mutableStateOf(Destination.ACTIVITY)
        var topInset = 0
        var bottomInset = 0
        var surfaceColor = 0
        compose.runOnUiThread {
            compose.activity.enableEdgeToEdge(
                statusBarStyle = SystemBarStyle.dark(android.graphics.Color.TRANSPARENT),
                navigationBarStyle = SystemBarStyle.dark(android.graphics.Color.TRANSPARENT),
            )
        }
        compose.setContent { TabletTestSurface(consumeSystemBars = false) {
            val density = LocalDensity.current
            val insets = WindowInsets.systemBars
            val statusInsetPx = insets.getTop(density)
            val navigationInsetPx = insets.getBottom(density)
            DieterTheme(darkTheme = true) {
                SideEffect {
                    topInset = statusInsetPx
                    bottomInset = navigationInsetPx
                    surfaceColor = DieterSurface.toArgb()
                }
                TabletWorkspace(fixture.copy(destination = destination, selectedCardId = "review",
                    conversation = snapshot("review")), model,
                    destinationContent = {
                        if (it.destination == Destination.BOARD) BoardScreen(it, model, true, PaddingValues())
                        else ActivityScreen(it, model, true, PaddingValues())
                    }, surfaceContent = {})
            }
        } }
        fun verify(name: String) {
            capture(name)
            Evidence.display("$name-window.png")
            val root = compose.onNodeWithTag("tablet-test-surface")
            val bounds = root.fetchSemanticsNode().boundsInRoot
            val sidebar = compose.onNode(SemanticsMatcher.expectValue(SemanticsProperties.PaneTitle, "List"))
                .fetchSemanticsNode().boundsInRoot
            val bitmap = root.captureToImage().asAndroidBitmap()
            try {
                val x = ((sidebar.left + sidebar.right) / 2 - bounds.left).toInt()
                assertEquals("Sidebar must paint behind the status bar", surfaceColor, bitmap.getPixel(x, 1))
                assertEquals("Sidebar must paint behind the navigation bar", surfaceColor, bitmap.getPixel(x, bitmap.height - 2))
            } finally { bitmap.recycle() }
            assertTrue("Exercise real status bar insets", topInset > 0)
            assertTrue("Exercise real navigation bar insets", bottomInset > 0)
            assertEquals(bounds.top, sidebar.top, 1f)
            assertEquals(bounds.bottom, sidebar.bottom, 1f)
            val header = compose.onNode(hasText(if (destination == Destination.BOARD) "Projects" else "Inbox") and
                hasAnyAncestor(hasTestTag(if (destination == Destination.BOARD) "tablet-project-navigator" else "activity-feed")))
                .fetchSemanticsNode().boundsInRoot
            assertTrue("Header stays below the status bar", header.top >= bounds.top + topInset)
            assertTrue("Composer stays above the navigation bar",
                visibleMessageEditor().fetchSemanticsNode().boundsInRoot.bottom <= bounds.bottom - bottomInset + 1f)
        }
        verify("tablet-inbox-system-bars")
        compose.runOnIdle { destination = Destination.BOARD }
        verify("tablet-projects-system-bars")
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
        compose.onAllNodesWithText("Main").assertCountEquals(1)
        compose.onAllNodesWithText("dieter").assertCountEquals(1)
        compose.onNodeWithText("Reverse board order").assertDoesNotExist()
        compose.onNodeWithTag("card-runtime-running", useUnmergedTree = true).assertIsDisplayed()
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

    @Test fun longPressDragMovesCardsBetweenPopulatedAndEmptyLanes() {
        var current by mutableStateOf(fixture)
        val drops = mutableListOf<BoardCardLaneDrop>()
        compose.setContent { TabletTestSurface {
            DieterTheme {
                BoardLanePager(current, model, BoardViews.build(BoardTarget(boardId = board.id), board, current.cards),
                    remember { BoardLabelDragState() }, Modifier.fillMaxSize(), showAllLanes = true,
                    onCardDrop = { drop ->
                        drops += drop
                        current = current.copy(cards = current.cards.map {
                            if (it.id == drop.cardId) it.copy(lane = drop.laneId) else it
                        })
                    })
            }
        } }
        fun drag(cardId: String, laneId: String, cancelDrop: Boolean = false) {
            val root = compose.onNodeWithTag("tablet-test-surface").fetchSemanticsNode().boundsInRoot
            val source = compose.onNodeWithTag("swipe-card-$cardId").fetchSemanticsNode().boundsInRoot.center - root.topLeft
            val target = compose.onNodeWithTag("board-drop-lane-$laneId").fetchSemanticsNode().boundsInRoot.center - root.topLeft
            compose.onNodeWithTag("tablet-test-surface").performTouchInput {
                down(source)
                advanceEventTime(650)
                moveTo(source)
                moveTo(target, delayMillis = 200)
            }
            compose.onNodeWithTag("board-card-drag-preview").assertIsDisplayed()
            compose.onNodeWithText("Move to ${laneId.replaceFirstChar(Char::uppercase)}").assertIsDisplayed()
            compose.onNodeWithTag("tablet-test-surface").performTouchInput {
                if (cancelDrop) cancel() else up()
            }
            compose.onNodeWithTag("board-card-drag-preview").assertDoesNotExist()
        }
        drag("running", "review", cancelDrop = true)
        compose.runOnIdle { assertTrue(drops.isEmpty()) }
        drag("running", "review")
        compose.runOnIdle { assertEquals(listOf(BoardCardLaneDrop("running", "review")), drops) }
        compose.onNodeWithTag("swipe-card-running").assert(hasAnyAncestor(hasTestTag("board-drop-lane-review")))
        compose.onNodeWithTag("card-runtime-running", useUnmergedTree = true).assertIsDisplayed()
        drag("running", "running") // The source lane is now empty.
        compose.runOnIdle { assertEquals(BoardCardLaneDrop("running", "running"), drops.last()); assertEquals(2, drops.size) }
        compose.onNodeWithTag("swipe-card-running").assert(hasAnyAncestor(hasTestTag("board-drop-lane-running")))
        capture("tablet-board-dragged")
    }

    @Test fun draggingAtBoardEdgeReachesAnOffscreenLane() {
        var dropped: BoardCardLaneDrop? = null
        compose.setContent { TabletTestSurface {
            DieterTheme {
                BoardLanePager(fixture, model, BoardViews.build(BoardTarget(boardId = board.id), board, cards),
                    remember { BoardLabelDragState() }, Modifier.width(480.dp).fillMaxHeight(),
                    showAllLanes = true, onCardDrop = { dropped = it })
            }
        } }
        val root = compose.onNodeWithTag("tablet-test-surface").fetchSemanticsNode().boundsInRoot
        val viewport = compose.onNodeWithTag("tablet-board-lanes").fetchSemanticsNode().boundsInRoot
        val laneWidth = compose.onNodeWithTag("tablet-lane-todo").fetchSemanticsNode().boundsInRoot.width
        val source = compose.onNodeWithTag("swipe-card-plan").fetchSemanticsNode().boundsInRoot.center - root.topLeft
        val edge = Offset(viewport.right - root.left - 2f, viewport.center.y - root.top)
        compose.onNodeWithTag("tablet-test-surface").performTouchInput {
            down(source)
            advanceEventTime(650)
            moveTo(source)
            moveTo(edge, delayMillis = 200)
        }
        try {
            compose.waitUntil(5_000) {
                val done = compose.onNodeWithTag("tablet-lane-done").fetchSemanticsNode().boundsInRoot
                done.width >= laneWidth - 1f && done.right <= viewport.right
            }
        } finally {
            capture("tablet-board-edge-held")
        }
        // Move inward from the board's outer padding onto the newly visible lane.
        val target = compose.onNodeWithTag("board-drop-lane-done").fetchSemanticsNode().boundsInRoot.center - root.topLeft
        compose.onNodeWithTag("tablet-test-surface").performTouchInput { moveTo(target) }
        compose.onNodeWithText("Move to Done").assertIsDisplayed()
        compose.onNodeWithTag("board-card-drag-preview").assertIsDisplayed()
        capture("tablet-board-drag-preview")
        compose.onNodeWithTag("tablet-test-surface").performTouchInput { up() }
        compose.runOnIdle { assertEquals(BoardCardLaneDrop("plan", "done"), dropped) }
        compose.onNodeWithTag("board-card-drag-preview").assertDoesNotExist()
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
        var opened: Card? = null
        var titlePadding = 0f
        compose.setContent { TabletTestSurface {
            val density = LocalDensity.current
            SideEffect { titlePadding = with(density) { 16.dp.toPx() } }
            DieterTheme(palette = DieterPalette.ULTRAVIOLET_RELAY, darkTheme = true) {
                Surface(Modifier.fillMaxSize()) {
                    Row {
                        TabletNavigationRail(Destination.ACTIVITY, false, false, 1, "2 of 2 machines online", {}, {}, {}, {}, {})
                        val feed: @Composable (Modifier) -> Unit = { modifier ->
                            ActivityFeed(fixture, modifier, { opened = it }, {}, {}, {}, now,
                                tablet = true)
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
        compose.onNodeWithTag("activity-timeline").assertIsDisplayed()
        compose.onNodeWithTag("tablet-inbox-list").assertDoesNotExist()
        compose.onNodeWithTag("tablet-inbox-timeline").assertDoesNotExist()
        compose.onNodeWithTag("tablet-inbox-projects").assertDoesNotExist()
        val title = compose.onNode(hasText("Review the tablet workspace") and hasAnyAncestor(hasTestTag("inbox-detail"))).fetchSemanticsNode().boundsInRoot
        val detail = compose.onNodeWithTag("inbox-detail").fetchSemanticsNode().boundsInRoot
        assertTrue("Conversation title has padding beside the divider", title.left >= detail.left + titlePadding - 1f)
        compose.onNodeWithTag("conversation-owner-machine").assertIsDisplayed().assertTextEquals("mini-home")
        capture("tablet-inbox")
        compose.onNodeWithTag("activity-timeline-expand").performClick()
        compose.onNodeWithTag("inbox-detail").assertIsDisplayed()
        compose.onNodeWithTag("activity-timeline").assertIsDisplayed()
        capture("tablet-timeline")
        compose.onNodeWithTag("activity-bar-running").performScrollTo().performClick()
        compose.runOnIdle { assertEquals("running", opened?.id) }
        compose.onNodeWithTag("inbox-detail").assertIsDisplayed()
    }

    @Test fun tabletComposerKeepsAgentSettingsBehindOneButton() {
        val controls = com.dbpprt.dieter.core.selection.AgentControls(
            com.dbpprt.dieter.api.v1.HarnessSelection(provider = "codex", model = "gpt-6.1-sol"),
            emptyList(), locked = true,
        )
        compose.setContent { TabletTestSurface {
            CompositionLocalProvider(LocalTabletWorkspace provides true) {
                DieterTheme(darkTheme = true) {
                    MessageComposer("", "Message", true, controls = controls,
                        onValueChange = {}, onSend = {})
                }
            }
        } }
        compose.onNodeWithText("gpt-6.1-sol").assertDoesNotExist()
        compose.onNodeWithTag("composer-next-message-settings").assertDoesNotExist()
        compose.onNodeWithContentDescription("Show agent settings").performClick()
        compose.onNodeWithText("gpt-6.1-sol").assertIsDisplayed()
        compose.onNodeWithTag("composer-next-message-settings").assertIsDisplayed()
        compose.onNodeWithContentDescription("Hide agent settings").performClick()
        compose.onNodeWithText("gpt-6.1-sol").assertDoesNotExist()
        compose.onNodeWithTag("message-input").assertIsDisplayed()
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
                            TabletNavigationRail(Destination.CHATS, false, settings, 4, "3 of 4 machines online", { destination = it }, {}, {}, {}, { settings = true })
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
        compose.onNodeWithTag("activity-feed").performScrollToNode(hasTestTag("activity-row-review"))
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
        compose.onNodeWithTag("activity-feed").performScrollToNode(hasTestTag("activity-row-review"))
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
        capture("tablet-inbox-detail")
        compose.onNodeWithTag("activity-timeline-expand").performClick()
        compose.onNodeWithTag("activity-timeline").assertIsDisplayed()
        visibleMessageEditor().assertIsDisplayed()
        capture("tablet-inbox-timeline-detail")
        assertEquals(width, compose.onNodeWithTag("activity-feed").fetchSemanticsNode().boundsInRoot.width, 1f)
        // Review cards without unread replies sort into Recent, sometimes offscreen.
        compose.onNodeWithTag("activity-feed").performScrollToNode(hasTestTag("activity-row-review"))
        compose.onNodeWithTag("activity-row-review").assertIsSelected()
        compose.runOnIdle { selected = null }
        compose.onNodeWithText("Your inbox").assertIsDisplayed()
        assertEquals(width, compose.onNodeWithTag("activity-feed").fetchSemanticsNode().boundsInRoot.width, 1f)
        capture("tablet-inbox-empty")
    }

    @Test fun newTaskStaysInsideActivityPaneAcrossFoldTabletAndPhoneLayouts() {
        var width by mutableFloatStateOf(760f)
        var selected by mutableStateOf<String?>("review")
        compose.setContent { TabletTestSurface(width = width, height = 840f) {
            DieterTheme(darkTheme = true) {
                Surface(Modifier.fillMaxSize()) {
                    val state = fixture.copy(destination = Destination.ACTIVITY, selectedCardId = selected,
                        conversation = selected?.let(::snapshot), activityPaneLeadingFraction = 0.5f)
                    if (usesTabletWorkspace(width)) {
                        TabletWorkspace(state, model,
                            destinationContent = { ActivityScreen(it, model, true, PaddingValues()) }, surfaceContent = {})
                    } else {
                        ActivityScreen(state, model, width >= 600f, PaddingValues(top = 12.dp, bottom = 24.dp))
                    }
                }
            }
        } }
        fun verifyButtonInList() {
            val button = compose.onNodeWithTag("inbox-new-task").assertIsDisplayed().assertHasClickAction()
                .assertContentDescriptionEquals("New task").fetchSemanticsNode().boundsInRoot
            val feed = compose.onNodeWithTag("activity-feed").fetchSemanticsNode().boundsInRoot
            assertTrue("New task stays inside the activity pane", button.left >= feed.left && button.right <= feed.right &&
                button.top >= feed.top && button.bottom <= feed.bottom)
            if (selected != null) {
                val editor = visibleMessageEditor().fetchSemanticsNode().boundsInRoot
                val sends = compose.onAllNodesWithTag("send-message")
                val visible = sends.fetchSemanticsNodes().indices.filter { sends[it].isDisplayed() }
                assertEquals("Expected one visible Send button", 1, visible.size)
                val send = sends[visible.single()].fetchSemanticsNode().boundsInRoot
                assertFalse("New task must not overlap the message editor", button.overlaps(editor))
                assertFalse("New task must not overlap Send", button.overlaps(send))
            }
        }
        verifyButtonInList()
        capture("activity-fold-new-task")
        compose.onNodeWithTag("activity-pane-divider").performTouchInput {
            down(center)
            moveBy(Offset(-40f, 0f), delayMillis = 500)
            up()
        }
        verifyButtonInList()
        compose.runOnIdle { selected = null }
        verifyButtonInList()
        compose.onNodeWithText("Your activity").assertIsDisplayed()
        compose.runOnIdle { width = 1280f; selected = "review" }
        verifyButtonInList()
        compose.onNodeWithTag("activity-timeline-expand").performClick()
        verifyButtonInList()
        capture("activity-tablet-new-task")
        compose.runOnIdle { width = 400f }
        visibleMessageEditor().assertIsDisplayed()
        compose.onNodeWithTag("inbox-new-task").assertDoesNotExist()
        compose.runOnIdle { selected = null }
        verifyButtonInList()
        capture("activity-phone-new-task")
        compose.onNodeWithTag("inbox-new-task").performClick()
        compose.waitUntil(5_000) { model.captureChooserVisible }
        compose.runOnIdle { assertTrue("New task opens the capture chooser", model.captureChooserVisible) }
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
        var opened: String? = null
        val archived = mutableListOf<String>()
        val renamed = mutableListOf<Pair<String, String>>()
        compose.setContent { TabletTestSurface {
            DieterTheme(darkTheme = true) {
                TabletListDetail(dividerTag = "activity-pane-divider", list = { modifier ->
                    ActivityFeed(fixture, modifier, { opened = it.id }, {}, {}, {}, now,
                        tablet = true,
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
        compose.onNodeWithTag("activity-feed").performScrollToNode(hasTestTag("activity-timeline-expand"))
        compose.onNodeWithTag("activity-timeline-expand").performClick()
        compose.onNodeWithTag("activity-bar-running").performScrollTo().performTouchInput { longClick() }
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
    private fun TabletTestSurface(width: Float = 1280f, height: Float = 800f, consumeSystemBars: Boolean = true, content: @Composable () -> Unit) {
        val density = androidx.compose.ui.platform.LocalDensity.current
        BoxWithConstraints(Modifier.fillMaxSize()) {
            val scale = minOf(maxWidth.value / width, maxHeight.value / height)
            CompositionLocalProvider(androidx.compose.ui.platform.LocalDensity provides
                androidx.compose.ui.unit.Density(density.density * scale, density.fontScale)) {
                // This represents the tablet's content area. Do not apply the
                // host phone's unscaled status/navigation insets inside it.
                Box(Modifier.requiredSize(width.dp, height.dp)
                    .then(if (consumeSystemBars) Modifier.consumeWindowInsets(WindowInsets.systemBars) else Modifier)
                    .testTag("tablet-test-surface")) { content() }
            }
        }
    }

    private fun capture(name: String) {
        compose.onNodeWithTag("tablet-test-surface").saveEvidence("$name.png")
        Evidence.text("$name.txt", compose.onRoot().printToString())
    }
    private fun snapshot(id: String): ConversationSnapshot {
        val card = cards.first { it.id == id }
        return ConversationSnapshot(detail = CardDetail(card = card, project = projects.first(), board = board), conversation = Conversation(card_id = id, status = "idle", messages = listOf(UiMessage(id = "request", role = "user", parts = listOf(MessagePart(type = "text", text = "Review the tablet layout and keep the Fold experience intact."))), UiMessage(id = "response", role = "assistant", parts = listOf(MessagePart(type = "text", text = "The tablet workspace is ready for review.\n\n### What changed\n\n" +
                            "- Project navigation stays beside the board.\n- Workflow lanes use the available width.\n" +
                            "- Conversations open beside the list, so your context stays visible.\n\n" +
                            "Phone and Fold windows keep their existing navigation. The layout uses the same conversations, files, and schedules."))))))
    }

    private fun project(id: String, name: String) = Project(id = id, name = name, path = "/work/$id")
    private fun card(id: String, title: String, lane: String, runtime: String = "idle") = Card(id = id, title = title, project_id = "dieter", board_id = "main", owner_daemon_id = "tablet-host", lane = lane, runtime = runtime, initial_prompt_sent_at = now.minusSeconds(1200).toString(), runtime_updated_at = now.minusSeconds(600).toString(), updated_at = now.minusSeconds(600).toString())
}
