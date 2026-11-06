package com.getdieter.mobile.desktop

import com.getdieter.api.v1.Board
import com.getdieter.api.v1.Card
import com.getdieter.api.v1.Label
import com.getdieter.api.v1.Project
import com.getdieter.api.v1.WorkspaceSummary
import com.getdieter.client.v1.*
import com.getdieter.mobile.store.*

/**
 * A small, realistic account for the desktop shell's UI tests: two projects, a board with work in
 * every lane, Inbox activity, chats and two machines. Conversations and searches answer from the
 * same data.
 */
internal object DesktopFixture {
    val atlas = Project(id = "atlas", name = "Atlas API")
    val homelab = Project(id = "homelab", name = "Homelab")
    val main =
        Board(
            id = "main",
            project_id = "atlas",
            name = "Main",
            labels =
                listOf(
                    Label(id = "api", name = "api", color = "#0A84FF"),
                    Label(id = "infra", name = "infra", color = "#30D158"),
                ),
        )
    val ops = Board(id = "ops", project_id = "homelab", name = "Ops")

    private fun card(
        id: String,
        title: String,
        lane: String,
        summary: String = "",
        vararg labels: String,
    ) =
        Card(
            id = id,
            project_id = "atlas",
            board_id = "main",
            title = title,
            lane = lane,
            summary = summary,
            provider = "codex",
            model = "gpt-5",
            label_ids = labels.toList(),
            owner_daemon_id = "mini",
            workspace_mode = "worktree",
            workspace_branch = "dieter/$id",
            workspace =
                WorkspaceSummary(
                    mode = "worktree",
                    branch = "dieter/$id",
                    changed_files = 3,
                    additions = 120,
                    deletions = 14,
                ),
            updated_at =
                (kotlin.time.Clock.System.now() - kotlin.time.Duration.parse("3h")).toString(),
        )

    val cards =
        listOf(
            card(
                "rate",
                "Rate-limit the public search endpoint",
                "todo",
                "Token bucket per API key, 429 with Retry-After.",
                "api",
            ),
            card("billing", "Migrate billing webhooks to the queue", "todo", "", "infra"),
            card(
                "ship",
                "Ship the v2 pagination cursor",
                "running",
                "Cursor encoding done; updating the SDK clients.",
                "api",
            ),
            card(
                "flaky",
                "Fix the flaky integration test",
                "review",
                "Root cause was a shared temp dir between workers.",
                "infra",
            ),
            card(
                "docs",
                "Document the auth scopes",
                "done",
                "Every scope with an example request.",
            ),
            Card(
                id = "chat",
                project_id = "atlas",
                scope = "chat",
                title = "How do we version the SDK?",
                provider = "claude",
                model = "opus",
                owner_daemon_id = "mini",
            ),
        )

    val workspace =
        WorkspaceSlice(
            projects = listOf(atlas, homelab),
            boards = listOf(main, ops),
            cards = cards,
            loaded = true,
            board_attention = mapOf("main" to 2),
        )

    val session =
        SessionSlice(
            phase = SessionSlice.Phase.PHASE_CONNECTED,
            phase_label = "Connected",
            tone = Tone.TONE_SUCCESS,
            synced = true,
            device_trust = DeviceTrust.DEVICE_TRUST_TRUSTED,
            machines =
                listOf(
                    MachineEntry(
                        id = "mini",
                        name = "Home mini",
                        display_name = "Home mini",
                        online = true,
                        available = true,
                        compatible = true,
                        presence = "Online",
                        sync_label = "Live",
                    ),
                    MachineEntry(
                        id = "mbp",
                        name = "MacBook Pro",
                        display_name = "MacBook Pro",
                        online = false,
                        presence = "Offline",
                        sync_label = "Offline",
                    ),
                ),
        )

    private fun row(
        card: Card,
        kind: String,
        section: ActivityRow.Section,
        detail: String,
        label: String,
        needsYou: Boolean = false,
        finish: Boolean = false,
    ) =
        ActivityRow(
            card = card,
            kind = kind,
            section = section,
            detail = detail,
            project_name = "Atlas API",
            board_name = if (card.scope == "chat") "" else "Main",
            chat = card.scope == "chat",
            needs_you = needsYou,
            can_finish = finish,
            kind_label = label,
            title = card.title,
            shown_at_millis = kotlin.time.Clock.System.now().toEpochMilliseconds() - 7 * 60_000,
        )

    val activity =
        ActivitySlice(
            rows =
                listOf(
                    row(
                        cards[3],
                        "REVIEW",
                        ActivityRow.Section.SECTION_ATTENTION,
                        "Ready for review: 3 files changed.",
                        "Review",
                        finish = true,
                    ),
                    row(
                        cards[5],
                        "ANSWER",
                        ActivityRow.Section.SECTION_ATTENTION,
                        "Which registry should publish the SDK?",
                        "Answer",
                        needsYou = true,
                    ),
                    row(
                        cards[2],
                        "RUNNING",
                        ActivityRow.Section.SECTION_RUNNING,
                        "Updating the TypeScript client…",
                        "Running",
                    ),
                    row(
                        cards[4],
                        "RECENT",
                        ActivityRow.Section.SECTION_RECENT,
                        "Finished.",
                        "Recent",
                    ),
                ),
            summary = ActivitySummary(running = 1, attention = 2, recent = 1, review = 1),
        )

    val chats =
        ChatsSlice(
            projects =
                listOf(
                    ChatProjectSection(
                        project_id = "atlas",
                        chat_ids = listOf("chat"),
                        total = 1,
                        show_chats = true,
                    )
                ),
            visible_ids = listOf("chat"),
        )

    val board =
        BoardViewSlice(
            target = BoardViewTarget(board_id = "main"),
            lanes =
                listOf(
                    BoardLaneView(
                        lane_id = "todo",
                        name = "Todo",
                        card_ids = listOf("rate", "billing"),
                    ),
                    BoardLaneView(
                        lane_id = "running",
                        name = "Running",
                        kind = BoardLaneKind.BOARD_LANE_KIND_RUNNING,
                        card_ids = listOf("ship"),
                    ),
                    BoardLaneView(
                        lane_id = "review",
                        name = "Review",
                        kind = BoardLaneKind.BOARD_LANE_KIND_REVIEW,
                        card_ids = listOf("flaky"),
                    ),
                    BoardLaneView(
                        lane_id = "done",
                        name = "Done",
                        kind = BoardLaneKind.BOARD_LANE_KIND_DONE,
                        card_ids = listOf("docs"),
                    ),
                ),
            label_counts = mapOf("api" to 2, "infra" to 2),
            total = 5,
            cards =
                mapOf(
                    "rate" to BoardCardFlags(can_start = true, runtime_label = "Idle"),
                    "ship" to
                        BoardCardFlags(
                            tone = RuntimeTone.RUNTIME_TONE_ACTIVE,
                            badge = "Running",
                            runtime_label = "Running",
                        ),
                    "flaky" to
                        BoardCardFlags(
                            tone = RuntimeTone.RUNTIME_TONE_ATTENTION,
                            runtime_label = "Waiting for you",
                        ),
                ),
            state_options =
                listOf(
                    BoardStateOption(
                        state = BoardStateFilter.BOARD_STATE_FILTER_ALL,
                        title = "All states",
                    )
                ),
            state_title = "All states",
        )

    fun conversation(id: String) =
        ConversationSlice(
            card_id = id,
            daemon_id = "mini",
            card = cards.first { it.id == id },
            project = atlas,
            board = main,
        )

    /** Answers searches from the cards; every other command succeeds. */
    fun core() = FakeMobileCore { command ->
        val query = command.search?.query
        if (query != null)
            Result(
                search_results =
                    SearchResults(
                        cards
                            .filter { it.title.contains(query, ignoreCase = true) }
                            .map {
                                SearchHit(
                                    card_id = it.id,
                                    title = it.title,
                                    location = "Atlas API · Main",
                                    chat = it.scope == "chat",
                                )
                            }
                    )
            )
        else Result(done = Done())
    }

    /** Publishes the account to every lifetime slice the store observes. */
    fun publish(core: FakeMobileCore) {
        core.publish(Slice.SLICE_SESSION, update = Update(session = session))
        core.publish(Slice.SLICE_WORKSPACE, update = Update(workspace = workspace))
        core.publish(Slice.SLICE_ACTIVITY, update = Update(activity = activity))
        core.publish(Slice.SLICE_CHATS, MobileStore.CHATS_SCOPE, Update(chats = chats))
        core.publish(
            Slice.SLICE_NAVIGATION,
            update =
                Update(
                    navigation =
                        NavigationSlice(
                            projects =
                                ProjectNavigation(
                                    order = listOf("atlas", "homelab"),
                                    expanded = listOf("atlas"),
                                ),
                            caught_up = true,
                        )
                ),
        )
    }

    fun publishBoard(core: FakeMobileCore) =
        core.publish(Slice.SLICE_BOARD_VIEW, MobileStore.BOARD_SCOPE, Update(board_view = board))

    fun publishConversation(core: FakeMobileCore, id: String) =
        core.publish(Slice.SLICE_CONVERSATION, id, Update(conversation = conversation(id)))
}
