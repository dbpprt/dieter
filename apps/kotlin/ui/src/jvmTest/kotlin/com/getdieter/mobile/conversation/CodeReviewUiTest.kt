@file:OptIn(androidx.compose.ui.test.ExperimentalTestApi::class)

package com.getdieter.mobile.conversation

import androidx.compose.ui.test.*
import com.getdieter.api.v1.Harness
import com.getdieter.api.v1.HarnessCatalog
import com.getdieter.api.v1.HarnessModel
import com.getdieter.api.v1.ReviewerSettings
import com.getdieter.client.v1.*
import com.getdieter.mobile.app.MobileApp
import com.getdieter.mobile.desktop.DesktopFixture
import com.getdieter.mobile.navigation.CardPane
import com.getdieter.mobile.navigation.MobileRoute
import com.getdieter.mobile.store.*
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlinx.coroutines.Dispatchers

/**
 * The code reviewer in the shared UI, rendered offscreen: a review's card with its findings, the
 * conversation's switch, "Review changes", the creation toggle and the reviewer settings.
 */
class CodeReviewUiTest {
    private val review =
        TimelineCodeReview(
            review_id = "rev_1",
            status = "completed",
            title = "Code review",
            subtitle = "Claude Code · opus · quick · 42 s",
            counts_label = "2 findings · 1 high",
            change_label = "3 files · +40 −2",
            round_label = "Round 2 · 1 resolved · 1 still open · 1 new",
            trigger_label = "Requested by the agent",
            summary = "Adds unborn-branch handling.",
            security = "Writes the token to the log.",
            findings =
                listOf(
                    TimelineCodeReviewFinding(
                        id = "f1",
                        file_ = "internal/git/unborn.go",
                        start_line = 23,
                        end_line = 26,
                        location_label = "internal/git/unborn.go:23–26",
                        severity = "high",
                        severity_label = "High",
                        title = "Nil dereference",
                        body = "The head may be nil here.",
                        suggestion = "Check the head first.",
                        status = "open",
                        status_label = "Still open",
                    ),
                    TimelineCodeReviewFinding(
                        id = "f2",
                        file_ = "README.md",
                        start_line = 4,
                        location_label = "README.md:4",
                        severity = "low",
                        severity_label = "Low",
                        title = "Typo",
                        body = "Spelled recieve.",
                        status = "new",
                        status_label = "New",
                    ),
                ),
            resolved =
                listOf(
                    TimelineCodeReviewFinding(
                        id = "f0",
                        file_ = "a.go",
                        start_line = 1,
                        location_label = "a.go:1",
                        severity = "medium",
                        severity_label = "Medium",
                        title = "Leaked file",
                        body = "Closed now.",
                        status = "resolved",
                        status_label = "Resolved",
                    )
                ),
            card_id = "ship",
        )

    private fun conversation(enabled: Boolean, running: Boolean = false) =
        DesktopFixture.conversation("ship")
            .copy(
                timeline =
                    listOf(
                        TimelineItem(
                            id = "message:a",
                            message_ids = listOf("a"),
                            groups =
                                listOf(
                                    TimelineStepGroup(
                                        id = "a:part:0",
                                        steps =
                                            listOf(
                                                TimelineStep(
                                                    id = "a:part:0",
                                                    message_id = "a",
                                                    kind =
                                                        TimelineStepKind
                                                            .TIMELINE_STEP_KIND_CODE_REVIEW,
                                                    code_review = review,
                                                )
                                            ),
                                    )
                                ),
                        )
                    ),
                state =
                    ConversationState(
                        code_review =
                            ConversationCodeReview(
                                enabled = enabled,
                                can_toggle = true,
                                running = running,
                                can_start = !running,
                                latest = review,
                            )
                    ),
            )

    private val defaults =
        ReviewerSettings(
            harness = "claude-code",
            model = "opus",
            depth = "quick",
            max_findings = 6,
            max_rounds = 3,
            revision = "r1",
        )

    private fun core() = FakeMobileCore { command ->
        val reviewer = command.code_review
        when {
            reviewer?.settings != null -> Result(reviewer_settings = defaults)
            reviewer?.update_settings != null ->
                Result(
                    reviewer_settings =
                        reviewer.update_settings!!
                            .settings!!
                            .copy(configured = true, revision = "r2")
                )
            else -> Result(done = Done())
        }
    }

    private fun render(block: DesktopComposeUiTest.(MobileStore, FakeMobileCore) -> Unit) =
        runDesktopComposeUiTest(width = 600, height = 1600) {
            val core = core()
            val store = MobileStore(core, Dispatchers.Unconfined)
            DesktopFixture.publish(core)
            setContent { MobileApp(store, desktopHost = false) }
            waitForIdle()
            try {
                block(store, core)
            } finally {
                store.close()
            }
        }

    private fun DesktopComposeUiTest.open(
        store: MobileStore,
        core: FakeMobileCore,
        enabled: Boolean = true,
        running: Boolean = false,
    ) {
        store.openConversation("ship")
        waitForIdle()
        core.publish(
            Slice.SLICE_CONVERSATION,
            "ship",
            Update(conversation = conversation(enabled, running)),
        )
        waitForIdle()
    }

    @Test
    fun aReviewShowsItsFindingsAndOpensTheirFiles() = render { store, core ->
        open(store, core)
        onNodeWithTag("code-review-rev_1").assertIsDisplayed()
        onNodeWithText("Claude Code · opus · quick · 42 s").assertIsDisplayed()
        onNodeWithText("2 findings · 1 high · 3 files · +40 −2").assertIsDisplayed()
        onNodeWithText("Round 2 · 1 resolved · 1 still open · 1 new · Requested by the agent")
            .assertIsDisplayed()
        onNodeWithText("Security: Writes the token to the log.").assertIsDisplayed()
        onNodeWithTag("code-review-finding-rev_1-f2").assertIsDisplayed()
        // A finding opens to its explanation and suggested fix.
        onAllNodesWithText("The head may be nil here.", useUnmergedTree = true).assertCountEquals(0)
        onNodeWithText("Nil dereference").performClick()
        waitForIdle()
        onNodeWithText("The head may be nil here.", useUnmergedTree = true).assertExists()
        onNodeWithText("Suggested fix").assertIsDisplayed()
        // Resolved findings wait behind their disclosure.
        onAllNodesWithText("Leaked file").assertCountEquals(0)
        onNodeWithTag("code-review-resolved-rev_1").performClick()
        waitForIdle()
        onNodeWithText("Leaked file").assertIsDisplayed()
        // A finding's location opens the conversation's Changes at its file.
        onNodeWithTag("code-review-location-rev_1-f1").performClick()
        waitForIdle()
        assertEquals(MobileRoute.Pane("ship", CardPane.CHANGES), store.routes.value.top)
        assertTrue(
            core.sentOf { it.review?.select }.any { it.path == "internal/git/unborn.go" },
            "the file is selected in Changes",
        )
    }

    @Test
    fun theConversationMenuSwitchesTheReviewer() = render { store, core ->
        open(store, core, enabled = true)
        onNodeWithTag("chrome-conversation-menu").performClick()
        waitForIdle()
        onNodeWithTag("menu-code-review-switch").performClick()
        waitForIdle()
        assertEquals(
            listOf(CodeReviewSwitch(card_id = "ship", enabled = false)),
            core.sentOf { it.code_review?.set_enabled },
        )
    }

    @Test
    fun changesStartAReviewUnlessOneRuns() = render { store, core ->
        open(store, core)
        store.push(MobileRoute.Pane("ship", CardPane.CHANGES))
        waitForIdle()
        onNodeWithTag("chrome-review-menu").performClick()
        waitForIdle()
        onNodeWithTag("menu-review-changes").performClick()
        waitForIdle()
        assertEquals(
            listOf("ship"),
            core.sentOf { it.code_review?.start }.map { it.card_id },
        )
        // While a review runs, another waits.
        core.publish(
            Slice.SLICE_CONVERSATION,
            "ship",
            Update(conversation = conversation(enabled = true, running = true)),
        )
        waitForIdle()
        onNodeWithTag("chrome-review-menu").performClick()
        waitForIdle()
        onNodeWithTag("menu-review-changes").assertIsNotEnabled()
        onNodeWithText("Reviewing changes…").assertIsDisplayed()
    }

    @Test
    fun aNewConversationCanHaveTheReviewer() = render { store, _ ->
        store.newConversation()
        waitForIdle()
        onNodeWithTag("creation-form").performScrollToNode(hasTestTag("code-review"))
        onNodeWithText("The agent can ask a separate reviewer model to check its changes")
            .assertIsDisplayed()
        assertTrue(!store.creation.intent.value.code_review, "off unless chosen")
        onNodeWithTag("code-review").performClick()
        waitForIdle()
        assertTrue(store.creation.intent.value.code_review)
    }

    @Test
    fun theReviewerSettingsSaveWhatWasRead() = render { store, core ->
        store.push(MobileRoute.CodeReviewer)
        waitForIdle()
        core.publish(
            Slice.SLICE_METADATA,
            update =
                Update(
                    metadata =
                        MetadataSlice(
                            machines =
                                mapOf(
                                    "mini" to
                                        MachineMetadata(
                                            harnesses =
                                                HarnessCatalog(
                                                    listOf(
                                                        Harness(
                                                            id = "claude-code",
                                                            name = "Claude Code",
                                                            default_model = "opus",
                                                            models =
                                                                listOf(
                                                                    HarnessModel(
                                                                        id = "opus",
                                                                        name = "Opus",
                                                                    ),
                                                                    HarnessModel(
                                                                        id = "sonnet",
                                                                        name = "Sonnet",
                                                                    ),
                                                                ),
                                                        )
                                                    )
                                                ),
                                            loaded = true,
                                        )
                                )
                        )
                ),
        )
        waitForIdle()
        onNodeWithTag("code-reviewer-settings").assertIsDisplayed()
        // Nobody saved a setting yet.
        onAllNodesWithText("Defaults").onFirst().assertExists()
        onNodeWithTag("picker-model").assertIsDisplayed()
        onNodeWithText("Opus").assertIsDisplayed()
        onNodeWithTag("code-reviewer-depth-1").performClick()
        onNodeWithText(
                "Every finding is confirmed in the code first. Slower.",
                useUnmergedTree = true,
            )
            .assertIsDisplayed()
        onNodeWithTag("code-reviewer-settings")
            .performScrollToNode(hasTestTag("code-reviewer-findings"))
        onNodeWithTag("code-reviewer-findings-plus").performClick()
        onNodeWithTag("code-reviewer-findings-value", useUnmergedTree = true).assertTextEquals("7")
        onNodeWithTag("code-reviewer-settings")
            .performScrollToNode(hasTestTag("code-reviewer-save"))
        onNodeWithTag("code-reviewer-save").performClick()
        waitForIdle()
        val saved = core.sentOf { it.code_review?.update_settings }.single()
        assertEquals("mini", saved.daemon_id)
        assertEquals("thorough", saved.settings?.depth)
        assertEquals(7, saved.settings?.max_findings)
        assertEquals("r1", saved.settings?.revision, "a save checks the revision it read")
        assertEquals(
            listOf("mini"),
            core.sentOf { it.code_review?.settings }.map { it.daemon_id },
        )
    }
}
