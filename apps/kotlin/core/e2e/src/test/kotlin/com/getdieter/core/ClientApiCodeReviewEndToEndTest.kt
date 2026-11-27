package com.getdieter.core

import com.getdieter.api.v1.HarnessSelection
import com.getdieter.client.v1.CodeReviewCommand
import com.getdieter.client.v1.CodeReviewMachine
import com.getdieter.client.v1.CodeReviewSettingsUpdate
import com.getdieter.client.v1.CodeReviewStart
import com.getdieter.client.v1.CodeReviewSwitch
import com.getdieter.client.v1.Command
import com.getdieter.client.v1.ConversationSlice
import com.getdieter.client.v1.CreateConversation
import com.getdieter.client.v1.CreationIntent
import com.getdieter.client.v1.SendMessage
import com.getdieter.client.v1.Slice
import com.getdieter.client.v1.TimelineCodeReview
import com.getdieter.core.client.ClientApi
import com.getdieter.core.client.ClientFailure
import com.getdieter.core.outbox.OutboxPolicy
import com.getdieter.core.testing.EndToEnd
import com.getdieter.core.testing.SliceFolds
import com.getdieter.core.testing.await
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.flow.MutableStateFlow

/**
 * The code reviewer over the real gateway and daemon with the mock harness: the account's reviewer
 * setting is read and saved compare-and-set, a chat created with the reviewer shows it at once and
 * once its machine has it, the switch turns it off, and a review the user starts arrives in the
 * conversation's timeline as a CODE_REVIEW step that replaces its running form.
 */
class ClientApiCodeReviewEndToEndTest : EndToEnd() {
    @AfterTest fun tearDown() = tearDownRuntimes()

    private suspend fun ClientApi.review(command: CodeReviewCommand) =
        dispatch(Command(code_review = command))

    private fun ConversationSlice?.reviews(): List<TimelineCodeReview> =
        this?.timeline.orEmpty().flatMap { row ->
            row.groups.flatMap { group -> group.steps.mapNotNull { it.code_review } }
        }

    @Test
    fun settingsSwitchAndReviewsGoThroughTheCore() = e2e {
        val fixture = fixture()
        val runtime = runtime(fixture)
        runtime.awaitConnected()
        runtime.awaitLoaded(fixture)
        val api = ClientApi(runtime)

        // Nobody saved a setting yet: the daemon's defaults.
        val defaults =
            api.review(CodeReviewCommand(settings = CodeReviewMachine())).reviewer_settings!!
        assertFalse(defaults.configured)
        assertEquals("quick", defaults.depth)
        assertTrue(defaults.max_findings in 1..20)
        // The mock harness reviews, so no review leaves the fixture.
        val saved =
            api.review(
                    CodeReviewCommand(
                        update_settings =
                            CodeReviewSettingsUpdate(
                                settings =
                                    defaults.copy(
                                        harness = "mock",
                                        model = "mock",
                                        effort = "",
                                        max_findings = 4,
                                        instructions = "  Mind the SQL.  ",
                                    )
                            )
                    )
                )
                .reviewer_settings!!
        assertTrue(saved.configured)
        assertEquals("mock", saved.harness)
        assertEquals(4, saved.max_findings)
        assertEquals("Mind the SQL.", saved.instructions)
        assertTrue(saved.revision.isNotEmpty())
        val again =
            api.review(
                    CodeReviewCommand(
                        update_settings =
                            CodeReviewSettingsUpdate(
                                daemon_id = fixture.daemonId,
                                settings = saved.copy(max_rounds = 2),
                            )
                    )
                )
                .reviewer_settings!!
        assertEquals(2, again.max_rounds)
        // A save based on an older read is refused with the daemon's reason.
        val stale = runCatching {
            api.review(
                CodeReviewCommand(
                    update_settings =
                        CodeReviewSettingsUpdate(settings = saved.copy(max_rounds = 5))
                )
            )
        }
            .exceptionOrNull()
        assertIs<ClientFailure>(stale)
        assertTrue(stale.failure.message.isNotEmpty())
        // A setting the daemon would refuse is refused before any machine is asked.
        val invalid = runCatching {
            api.review(
                CodeReviewCommand(
                    update_settings =
                        CodeReviewSettingsUpdate(settings = again.copy(max_findings = 21))
                )
            )
        }
            .exceptionOrNull()
        assertIs<ClientFailure>(invalid)
        val read =
            api.review(CodeReviewCommand(settings = CodeReviewMachine(fixture.daemonId)))
                .reviewer_settings!!
        assertEquals(again.revision, read.revision)
        assertEquals(2, read.max_rounds)

        // A chat created with the reviewer shows it at once, and once its machine has it.
        val created =
            api.dispatch(
                    Command(
                        create_conversation =
                            CreateConversation(
                                intent =
                                    CreationIntent(
                                        project_id = fixture.projectId,
                                        title = "Reviewed chat",
                                        prompt = "first",
                                        selection = HarnessSelection("mock", "mock", "low"),
                                        workspace_mode = "project",
                                        code_review = true,
                                    ),
                                chat = true,
                            )
                    )
                )
                .card!!
        assertTrue(created.code_review, "the optimistic card carries the reviewer")
        val synced =
            runtime.workspace.state.await(30.seconds, describe = { "reviewer synced" }) { view ->
                view.chats.any {
                    OutboxPolicy.isServerBacked(it.id) &&
                        it.id !in view.pendingCardIds &&
                        it.title == "Reviewed chat" &&
                        it.code_review
                }
            }
        val id = synced.chats.first { it.title == "Reviewed chat" }.id

        val conversation = MutableStateFlow<ConversationSlice?>(null)
        val watch =
            api.observe(Slice.SLICE_CONVERSATION, id) { update ->
                conversation.value =
                    update.conversation
                        ?: update.conversation_delta?.let {
                            SliceFolds.apply(checkNotNull(conversation.value), it)
                        }
                        ?: error("conversation observation failed: $update")
            }
        try {
            conversation.await(
                60.seconds,
                describe = { "reviewer on: ${conversation.value?.state}" },
            ) {
                val state = it?.state?.code_review
                state != null && state.enabled && state.can_toggle && state.can_start
            }

            // The switch turns it off on the conversation's machine.
            val off =
                api.review(CodeReviewCommand(set_enabled = CodeReviewSwitch(id, enabled = false)))
                    .card!!
            assertFalse(off.code_review)
            runtime.workspace.state.await(30.seconds, describe = { "reviewer off" }) { view ->
                view.card(id)?.code_review == false && id !in view.pendingCardIds
            }
            conversation.await(30.seconds, describe = { "switch shown" }) {
                it?.state?.code_review?.enabled == false
            }

            // A review the user starts runs, then shows its result in place.
            val started =
                api.review(CodeReviewCommand(start = CodeReviewStart(card_id = id))).code_review!!
            assertEquals("user", started.trigger)
            assertTrue(started.id.isNotEmpty())
            val finished =
                conversation.await(
                    90.seconds,
                    describe = { "review: ${conversation.value.reviews()}" },
                ) {
                    it.reviews().any { review -> review.review_id == started.id && !review.running }
                }!!
            val review = finished.reviews().single { it.review_id == started.id }
            assertEquals("completed", review.status, "review: $review")
            assertEquals("Code review", review.title)
            assertEquals("Requested by you", review.trigger_label)
            // The harness reads as its catalog name.
            assertTrue(review.subtitle.startsWith("Mock · mock · quick"), review.subtitle)
            assertTrue(review.counts_label.isNotEmpty())
            val state = finished.state!!.code_review!!
            assertEquals(started.id, state.latest?.review_id)
            assertFalse(state.running)
            assertTrue(state.can_start)

            // With the reviewer on again, the agent asks for a review; its card stands in for
            // the agent's tool call.
            api.review(CodeReviewCommand(set_enabled = CodeReviewSwitch(id, enabled = true)))
            conversation.await(30.seconds, describe = { "switch on shown" }) {
                it?.state?.code_review?.enabled == true
            }
            api.dispatch(
                Command(send_message = SendMessage(card_id = id, text = "please mock-code-review"))
            )
            val asked =
                conversation.await(
                    120.seconds,
                    describe = { "agent review: ${conversation.value.reviews()}" },
                ) {
                    it.reviews().any { review ->
                        review.trigger_label == "Requested by the agent" && !review.running
                    }
                }!!
            val agentReview =
                asked.reviews().single { it.trigger_label == "Requested by the agent" }
            assertEquals("completed", agentReview.status, "review: $agentReview")
            val row =
                asked.timeline.single { row ->
                    row.groups.any { group ->
                        group.steps.any { it.code_review?.review_id == agentReview.review_id }
                    }
                }
            assertFalse(row.activity)
            val steps = row.groups.flatMap { it.steps }
            assertTrue(
                steps.none { it.tool_title.contains("review", ignoreCase = true) },
                "the request leaves no tool row: ${steps.map { it.tool_title }}",
            )
            assertEquals(agentReview.review_id, asked.state!!.code_review!!.latest?.review_id)
        } finally {
            watch.close()
        }
    }
}
