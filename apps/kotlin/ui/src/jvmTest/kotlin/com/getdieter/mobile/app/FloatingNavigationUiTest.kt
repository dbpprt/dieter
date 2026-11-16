@file:OptIn(androidx.compose.ui.test.ExperimentalTestApi::class)

package com.getdieter.mobile.app

import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.toAwtImage
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.test.*
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.height
import androidx.compose.ui.unit.width
import com.getdieter.api.v1.Lane
import com.getdieter.client.v1.*
import com.getdieter.mobile.desktop.DesktopFixture
import com.getdieter.mobile.navigation.MobileTab
import com.getdieter.mobile.store.*
import java.io.File
import javax.imageio.ImageIO
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlinx.coroutines.Dispatchers

/**
 * The floating liquid glass navigation and the floating composers, rendered offscreen at the sizes
 * of a phone, an unfolded Fold in portrait and in landscape, in light and dark. Skia runs the same
 * lens shader as Android 13+, so the screenshots in `desktop-screenshots/glass` show the real
 * effect.
 */
class FloatingNavigationUiTest {
    /** Phone, Fold inner portrait and landscape in dp; rendered at twice the density. */
    private enum class Window(val width: Int, val height: Int) {
        PHONE(412, 915),
        FOLD(750, 832),
        FOLD_LANDSCAPE(832, 750),
        PHONE_LANDSCAPE(915, 412),
    }

    private val scale = 2f
    private val shownAt = kotlin.time.Clock.System.now().toEpochMilliseconds() - 6 * 60_000

    /** A busy Inbox like a real account's, so the glass has a page to bend. */
    private val activity: ActivitySlice
        get() {
            fun row(
                id: String,
                title: String,
                project: String,
                kind: String,
                section: ActivityRow.Section,
                preview: String,
                minutes: Int,
                pinned: Boolean = false,
            ) =
                ActivityRow(
                    card =
                        com.getdieter.api.v1.Card(
                            id = id,
                            project_id = project.lowercase(),
                            board_id = "main",
                            title = title,
                            lane = "todo",
                            owner_daemon_id = "mini",
                        ),
                    kind = kind,
                    section = section,
                    detail = preview,
                    preview = preview,
                    project_name = project,
                    board_name = "Main",
                    needs_you = section == ActivityRow.Section.SECTION_ATTENTION,
                    pinned = pinned,
                    title = title,
                    shown_at_millis = shownAt - minutes * 60_000L,
                )
            val attention = ActivityRow.Section.SECTION_ATTENTION
            val running = ActivityRow.Section.SECTION_RUNNING
            val pinned = ActivityRow.Section.SECTION_PINNED
            val recent = ActivityRow.Section.SECTION_RECENT
            return ActivitySlice(
                rows =
                    listOf(
                        row(
                            "t1",
                            "Affinity tracking",
                            "Atlas API",
                            "ANSWER",
                            attention,
                            "New reply",
                            0,
                        ),
                        row(
                            "t2",
                            "Check upstream for updates",
                            "Homelab",
                            "ANSWER",
                            attention,
                            "New reply",
                            1,
                        ),
                        row(
                            "ship",
                            "Ship the v2 pagination cursor",
                            "Atlas API",
                            "RUNNING",
                            running,
                            "Thinking…",
                            5,
                        ),
                        row(
                            "t4",
                            "Affinity",
                            "Storefront",
                            "RUNNING",
                            running,
                            "Thinking…",
                            6,
                            pinned = true,
                        ),
                        row(
                            "t5",
                            "The current changes view in conversations",
                            "Atlas API",
                            "RUNNING",
                            running,
                            "Running gh pr checks 218",
                            23,
                        ),
                        row(
                            "t6",
                            "Understand the current project",
                            "Pocket",
                            "RUNNING",
                            running,
                            "Running date +%H:%M:%S",
                            170,
                        ),
                        row(
                            "t7",
                            "Managed login experience for Claude",
                            "Atlas API",
                            "REVIEW",
                            pinned,
                            "Finished",
                            290,
                            pinned = true,
                        ),
                        row(
                            "t8",
                            "Maintenance",
                            "Storefront",
                            "RECENT",
                            pinned,
                            "Finished",
                            410,
                            pinned = true,
                        ),
                        row(
                            "t9",
                            "Wear OS 24/7 recorder",
                            "Recorder",
                            "RECENT",
                            pinned,
                            "Finished",
                            480,
                            pinned = true,
                        ),
                        row(
                            "t10",
                            "Rate-limit the public search endpoint",
                            "Atlas API",
                            "RECENT",
                            recent,
                            "Finished",
                            600,
                        ),
                        row(
                            "t11",
                            "Document the auth scopes",
                            "Atlas API",
                            "RECENT",
                            recent,
                            "Finished",
                            700,
                        ),
                        row(
                            "t12",
                            "Nightly backup check",
                            "Homelab",
                            "RECENT",
                            recent,
                            "Finished",
                            800,
                        ),
                        row(
                            "t13",
                            "Rotate the gateway certificates",
                            "Homelab",
                            "RECENT",
                            recent,
                            "Finished",
                            900,
                        ),
                    ),
                summary =
                    ActivitySummary(
                        running = 4,
                        attention = 2,
                        recent = 4,
                        headline = "2 need you · 4 running",
                    ),
            )
        }

    private fun conversation(id: String): ConversationSlice {
        val base = DesktopFixture.conversation(id)
        fun text(rowId: String, user: Boolean, body: String) =
            TimelineItem(
                id = rowId,
                message_ids = listOf(rowId),
                user = user,
                copyable = true,
                groups =
                    listOf(
                        TimelineStepGroup(
                            id = "$rowId:part:0",
                            steps =
                                listOf(
                                    TimelineStep(
                                        id = "$rowId:part:0",
                                        message_id = rowId,
                                        kind = TimelineStepKind.TIMELINE_STEP_KIND_TEXT,
                                        text = body,
                                    )
                                ),
                        )
                    ),
            )
        return base.copy(
            board =
                base.board?.copy(
                    lanes =
                        listOf(
                            Lane(id = "todo", name = "To do"),
                            Lane(id = "running", name = "Running"),
                            Lane(id = "review", name = "Review"),
                            Lane(id = "done", name = "Done"),
                        )
                ),
            card = base.card?.copy(lane = "running"),
            timeline =
                listOf(
                    text(
                        "u1",
                        true,
                        "Why did the page views drop on Sunday? Check the tracker and CPM.",
                    ),
                    text(
                        "a1",
                        false,
                        "The tracker is fine. I loaded the article page and the tracker sent " +
                            "the page view to the collector (`events.example.eu`), which " +
                            "answered `204` (accepted).\n\n" +
                            "- **In CPM's numbers:** the newest minute in our metrics copy is " +
                            "about 5 minutes old, which is CPM's normal delay. It counted " +
                            "11,579 page views in the 30 minutes up to 22:30.\n" +
                            "- **Today's total** is higher than last Sunday's, because push " +
                            "reads now open as `/app/` pages.\n\n" +
                            "What did stop has nothing to do with CPM:\n\n" +
                            "- **The own event pipeline:** events to the EventCollector " +
                            "(`/api/events`) are gone since #206. That pipeline never fed CPM.\n" +
                            "- **Native app screens:** CPM never received events from the " +
                            "app's native screens. Its `native_app` platform has been 0 since " +
                            "at least Friday, before any of our changes.",
                    ),
                    text("u2", true, "Good. Draft the note for the analytics channel."),
                    text(
                        "a2",
                        false,
                        "Here is a short note you can post:\n\n> Page views are healthy. " +
                            "The drop you saw is the retired EventCollector pipeline (#206), " +
                            "which never fed CPM. Native screens were never counted.",
                    ),
                ),
            state =
                ConversationState(
                    agent =
                        AgentControlsState(
                            provider_label = "Claude Code",
                            model_label = "Opus",
                            effort_label = "Extra high",
                        ),
                    context_percent = 34,
                ),
        )
    }

    private fun DesktopComposeUiTest.shot(name: String) {
        val directory = System.getProperty("dieter.screenshots") ?: return
        waitForIdle()
        val folder = File(directory, "glass").apply { mkdirs() }
        // A sheet is a window of its own: lay every root over the first.
        val roots =
            onAllNodes(isRoot()).fetchSemanticsNodes().indices.map {
                onAllNodes(isRoot())[it].captureToImage().toAwtImage()
            }
        val image =
            java.awt.image.BufferedImage(
                roots[0].getWidth(null),
                roots[0].getHeight(null),
                java.awt.image.BufferedImage.TYPE_INT_ARGB,
            )
        val graphics = image.createGraphics()
        roots.forEach { graphics.drawImage(it, 0, 0, null) }
        graphics.dispose()
        ImageIO.write(image, "png", File(folder, "$name.png"))
    }

    private fun render(
        window: Window,
        navigation: NavigationStyle,
        composer: ComposerStyle = ComposerStyle.CARD,
        dark: Boolean = false,
        open: String? = null,
        palette: com.getdieter.mobile.settings.DieterPalette =
            com.getdieter.mobile.settings.DieterPalette.MONOCHROME,
        seed: (FakeMobileCore) -> Unit = {},
        block: DesktopComposeUiTest.(MobileStore) -> Unit,
    ) =
        runDesktopComposeUiTest(
            width = (window.width * scale).toInt(),
            height = (window.height * scale).toInt(),
        ) {
            val core = DesktopFixture.core()
            val store = MobileStore(core, Dispatchers.Unconfined)
            store.layout.setInterfaceMode(InterfaceMode.TOUCH)
            store.layout.setNavigationStyle(navigation)
            store.layout.setComposerStyle(composer)
            store.theme.setAppearance(if (dark) "dark" else "light")
            store.theme.setPalette(palette)
            DesktopFixture.publish(core)
            core.publish(Slice.SLICE_ACTIVITY, update = Update(activity = activity))
            seed(core)
            setContent {
                CompositionLocalProvider(LocalDensity provides Density(scale)) {
                    MobileApp(store, desktopHost = false)
                }
            }
            waitForIdle()
            if (open != null) {
                store.openConversation(open)
                core.publish(
                    Slice.SLICE_CONVERSATION,
                    open,
                    Update(conversation = conversation(open)),
                )
                waitForIdle()
            }
            try {
                block(store)
            } finally {
                store.close()
            }
        }

    private fun name(window: Window, vararg parts: Any) =
        (listOf(window.name.lowercase().replace('_', '-')) +
                parts.map { it.toString().lowercase() })
            .joinToString("-")

    @Test
    fun everyFloatingStyleShowsFiveTabsAndTheComposeOrbInPlaceOfTheFab() {
        for (style in NavigationStyle.entries) for (dark in listOf(false, true)) {
            if (style == NavigationStyle.CLASSIC && dark) continue
            render(Window.PHONE, style, dark = dark) {
                for (tab in MobileTab.entries) onNodeWithTag("nav-${tab.name.lowercase()}")
                    .assertIsDisplayed()
                // One creation command: the orb when floating, the Material FAB otherwise.
                onAllNodesWithTag("chrome-new-task").assertCountEquals(1)
                if (style != NavigationStyle.CLASSIC)
                    onNodeWithTag("floating-navigation").assertIsDisplayed()
                shot(name(Window.PHONE, "inbox", style, if (dark) "dark" else "light"))
            }
        }
    }

    @Test
    fun aColorPaletteTintsTheDropAndTheOrb() {
        val blue = com.getdieter.mobile.settings.DieterPalette.ELECTRIC_BLUE
        for (style in
            listOf(NavigationStyle.DOCK, NavigationStyle.LENS, NavigationStyle.ISLAND)) for (dark in
            listOf(false, true)) render(Window.PHONE, style, dark = dark, palette = blue) {
            shot(name(Window.PHONE, "inbox", style, "blue", if (dark) "dark" else "light"))
        }
        render(
            Window.FOLD,
            NavigationStyle.LENS,
            ComposerStyle.GLASS,
            open = "ship",
            palette = blue,
        ) {
            shot(name(Window.FOLD, "lens", "glass", "blue", "light"))
        }
    }

    @Test
    fun selectingATabMovesTheSelectionAndKeepsTheOrbForTheTabsCommand() =
        render(Window.PHONE, NavigationStyle.DOCK) { store ->
            mainClock.autoAdvance = false
            onNodeWithTag("nav-chats").performClick()
            // Mid-flight: the drop stretches between Inbox and Chats.
            mainClock.advanceTimeBy(90)
            shot(name(Window.PHONE, "dock", "stretch"))
            mainClock.autoAdvance = true
            waitForIdle()
            assertEquals(MobileTab.CHATS, store.routes.value.tab)
            onNodeWithTag("nav-chats").assertIsSelected()
            // The orb follows the tab's command: Chats starts chats.
            onAllNodesWithTag("chrome-new-chat").assertCountEquals(1)
            onAllNodesWithTag("chrome-new-task").assertCountEquals(0)
            shot(name(Window.PHONE, "dock", "chats"))
        }

    @Test
    fun draggingTheLensSelectsTheTabBeneathIt() =
        render(Window.PHONE, NavigationStyle.LENS) { store ->
            val bar = onNodeWithTag("floating-navigation").getBoundsInRoot()
            val projects = onNodeWithTag("nav-projects").getBoundsInRoot()
            onNodeWithTag("floating-navigation").performTouchInput {
                val y = height / 2f
                down(Offset(width * .12f, y))
                moveBy(Offset(width * .1f, 0f))
                moveBy(Offset(width * .1f, 0f))
                moveBy(Offset(width * .08f, 0f))
            }
            mainClock.advanceTimeBy(400)
            // The lifted lens magnifies the icons it passes.
            shot(name(Window.PHONE, "lens", "drag"))
            onNodeWithTag("floating-navigation").performTouchInput {
                val target = ((projects.left + projects.right) / 2 - bar.left).value * scale
                moveTo(Offset(target, height / 2f))
                up()
            }
            waitForIdle()
            assertEquals(MobileTab.PROJECTS, store.routes.value.tab)
        }

    @Test
    fun aLongSwipeAlongTheBarKeepsTheLensItsSizeAndSelectsWhereItEnds() =
        render(Window.PHONE, NavigationStyle.LENS) { store ->
            val bar = onNodeWithTag("floating-navigation").getBoundsInRoot()
            // A real swipe sends a hundred or more moves; the lens once grew with each one
            // until its size could no longer be laid out and the app crashed.
            onNodeWithTag("floating-navigation").performTouchInput {
                val y = height / 2f
                down(Offset(width * .1f, y))
                repeat(160) { moveBy(Offset(width * .0045f, 0f)) }
                repeat(160) { moveBy(Offset(-width * .002f, 0f)) }
                repeat(120) { moveBy(Offset(width * .01f, 0f)) }
            }
            mainClock.advanceTimeBy(300)
            shot(name(Window.PHONE, "lens", "long-swipe"))
            onNodeWithTag("floating-navigation").assertWidthIsEqualTo(bar.right - bar.left)
            onNodeWithTag("floating-navigation").performTouchInput { up() }
            waitForIdle()
            // Dragged past the last tab, the lens stops on More and opens its sheet.
            onNodeWithTag("more-sheet").assertExists()
            assertEquals(MobileTab.INBOX, store.routes.value.tab)
        }

    @Test
    fun aWideBadgeOnMoreIsNotCutOff() =
        render(
            Window.PHONE,
            NavigationStyle.LENS,
            seed = { core ->
                core.publish(
                    Slice.SLICE_CHANNELS,
                    MobileStore.CHANNELS_SCOPE,
                    Update(channels = ChannelsSlice(unread_label = "99+")),
                )
            },
        ) {
            onNodeWithTag("nav-more").assertIsDisplayed()
            shot(name(Window.PHONE, "lens", "badge"))
        }

    @Test
    fun theLensShrinksWhileThePageScrollsDownAndReturnsOnTheWayUp() =
        render(Window.PHONE, NavigationStyle.LENS) {
            onNodeWithTag("activity-feed").performTouchInput { swipeUp() }
            waitForIdle()
            onNodeWithTag("navigation-expand").assertIsDisplayed()
            shot(name(Window.PHONE, "lens", "minimized"))
            onNodeWithTag("navigation-expand").performClick()
            waitForIdle()
            onNodeWithTag("nav-mail").assertIsDisplayed()
        }

    @Test
    fun theMoreSheetKeepsTheFloatingBarAtItsFoot() =
        render(Window.PHONE, NavigationStyle.LENS) {
            onNodeWithTag("nav-more").performClick()
            waitForIdle()
            onNodeWithTag("more-sheet").assertExists()
            shot(name(Window.PHONE, "lens", "more"))
        }

    @Test
    fun unfoldedPortraitFloatsTheBarUnderTheListAndTheComposerBesideIt() {
        val pairs =
            listOf(
                NavigationStyle.CLASSIC to ComposerStyle.CLASSIC,
                NavigationStyle.DOCK to ComposerStyle.CARD,
                NavigationStyle.LENS to ComposerStyle.GLASS,
                NavigationStyle.LENS to ComposerStyle.CARD,
                NavigationStyle.ISLAND to ComposerStyle.CARD,
            )
        for ((style, composer) in pairs) for (dark in listOf(false, true)) {
            if (style == NavigationStyle.CLASSIC && dark) continue
            render(Window.FOLD, style, composer, dark, open = "ship") {
                onNodeWithTag("message-input").assertExists()
                if (style != NavigationStyle.CLASSIC) {
                    val bar = onNodeWithTag("floating-navigation").getBoundsInRoot()
                    val input = onNodeWithTag("message-input").getBoundsInRoot()
                    // The bar stays under the list; the composer reaches the bottom beside it.
                    assertTrue(bar.right < input.left, "bar $bar beside input $input")
                }
                if (composer != ComposerStyle.CLASSIC) {
                    onNodeWithTag("composer-card").assertIsDisplayed()
                    onNodeWithTag("move-review").assertIsDisplayed()
                }
                shot(name(Window.FOLD, style, composer, if (dark) "dark" else "light"))
            }
        }
    }

    @Test
    fun landscapeWindowsStandTheBarOnTheLeadingEdge() {
        for (window in listOf(Window.FOLD_LANDSCAPE, Window.PHONE_LANDSCAPE)) for (style in
            listOf(NavigationStyle.DOCK, NavigationStyle.LENS, NavigationStyle.ISLAND)) {
            val open = if (window == Window.FOLD_LANDSCAPE) "ship" else null
            render(window, style, ComposerStyle.CARD, open = open) {
                val bar = onNodeWithTag("floating-navigation").getBoundsInRoot()
                assertTrue(bar.height > bar.width, "a vertical bar, not $bar")
                for (tab in MobileTab.entries) onNodeWithTag("nav-${tab.name.lowercase()}")
                    .assertIsDisplayed()
                shot(name(window, style))
            }
        }
        render(Window.FOLD_LANDSCAPE, NavigationStyle.LENS, ComposerStyle.GLASS, true, "ship") {
            shot(name(Window.FOLD_LANDSCAPE, "lens", "glass", "dark"))
        }
    }

    @Test
    fun thePhoneConversationShowsEachComposerStyle() {
        for (composer in ComposerStyle.entries) for (dark in listOf(false, true)) render(
            Window.PHONE,
            NavigationStyle.LENS,
            composer,
            dark,
            open = "ship",
        ) {
            onNodeWithTag("message-input").assertIsDisplayed()
            onNodeWithTag("agent-chip").assertIsDisplayed()
            onNodeWithTag("send-message").assertIsDisplayed()
            // A conversation fills the phone: the navigation steps aside.
            onAllNodesWithTag("floating-navigation").assertCountEquals(0)
            shot(name(Window.PHONE, "conversation", composer, if (dark) "dark" else "light"))
        }
    }
}
