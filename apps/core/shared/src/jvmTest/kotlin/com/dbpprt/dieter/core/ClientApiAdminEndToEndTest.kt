package com.dbpprt.dieter.core

import com.dbpprt.dieter.api.v1.CreateConversationRequest
import com.dbpprt.dieter.api.v1.MachineOperationAction
import com.dbpprt.dieter.client.v1.AdminArchivePolicy
import com.dbpprt.dieter.client.v1.AdminBoardRetired
import com.dbpprt.dieter.client.v1.AdminCard
import com.dbpprt.dieter.client.v1.AdminCommand
import com.dbpprt.dieter.client.v1.AdminCreateBoard
import com.dbpprt.dieter.client.v1.AdminCreateProject
import com.dbpprt.dieter.client.v1.AdminDirectories
import com.dbpprt.dieter.client.v1.AdminLabel
import com.dbpprt.dieter.client.v1.AdminMachine
import com.dbpprt.dieter.client.v1.AdminPreviewPrompt
import com.dbpprt.dieter.client.v1.AdminReadFile
import com.dbpprt.dieter.client.v1.AdminRenameBoard
import com.dbpprt.dieter.client.v1.AdminUpdateProject
import com.dbpprt.dieter.client.v1.Command
import com.dbpprt.dieter.client.v1.QuotasCommand
import com.dbpprt.dieter.client.v1.QuotasLoad
import com.dbpprt.dieter.client.v1.Slice
import com.dbpprt.dieter.client.v1.Step
import com.dbpprt.dieter.client.v1.TelemetryCommand
import com.dbpprt.dieter.client.v1.TelemetrySelect
import com.dbpprt.dieter.client.v1.TelemetrySlice
import com.dbpprt.dieter.client.v1.Update
import com.dbpprt.dieter.client.v1.WorkspaceSlice
import com.dbpprt.dieter.core.admin.MachineOperations
import com.dbpprt.dieter.core.client.ClientApi
import com.dbpprt.dieter.core.client.ClientFailure
import com.dbpprt.dieter.core.testing.EndToEnd
import com.dbpprt.dieter.core.testing.SliceFolds
import com.dbpprt.dieter.core.testing.await
import java.io.File
import java.nio.file.Files
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.flow.MutableStateFlow

/**
 * Administration as the Mac drives it through the client API: boards and labels on the project's
 * replica, prompts on a named machine, a conversation's workspace on its owner, and files read for
 * download.
 */
class ClientApiAdminEndToEndTest : EndToEnd() {
    @AfterTest fun tearDown() = tearDownRuntimes()

    @Test
    fun theMacAdministersProjectsBoardsAndPromptsThroughTheCore() = e2e {
        val fixture = fixture()
        val runtime = runtime(fixture)
        runtime.awaitConnected()
        runtime.awaitLoaded(fixture)
        val api = ClientApi(runtime)
        suspend fun admin(name: String, command: AdminCommand) =
            try {
                api.dispatch(Command(admin = command))
            } catch (failure: ClientFailure) {
                throw AssertionError("$name: ${failure.message}", failure)
            }

        val board =
            admin(
                    "create board",
                    AdminCommand(
                        create_board =
                            AdminCreateBoard(
                                project_id = fixture.projectId,
                                name = "Ops",
                                workflow = "direct",
                            )
                    ),
                )
                .board!!
        runtime.workspace.state.await(describe = { "new board" }) {
            it.board(board.id)?.name == "Ops"
        }
        assertEquals(
            "Operations",
            admin(
                    "rename board",
                    AdminCommand(rename_board = AdminRenameBoard(board.id, "Operations")),
                )
                .board!!
                .name,
        )
        assertEquals(
            "after_7_days",
            admin(
                    "archive policy",
                    AdminCommand(set_archive_policy = AdminArchivePolicy(board.id, "after_7_days")),
                )
                .board!!
                .done_archive_policy,
        )
        val labelled =
            admin(
                    "create label",
                    AdminCommand(
                        create_label =
                            AdminLabel(board_id = board.id, name = " urgent ", color = "#d95c68")
                    ),
                )
                .board!!
        val label = labelled.labels.single { it.name == "urgent" }
        val renamed =
            admin(
                    "update label",
                    AdminCommand(
                        update_label = AdminLabel(board.id, label.id, "blocker", "#478dc5", "")
                    ),
                )
                .board!!
        assertEquals("blocker", renamed.labels.single().name)
        admin(
            "delete label",
            AdminCommand(delete_label = AdminLabel(board_id = board.id, label_id = label.id)),
        )
        // An empty board is retired and restored against its lifecycle revision; a finished intent
        // keeps no operation ID.
        assertTrue(
            admin(
                    "retire board",
                    AdminCommand(set_board_retired = AdminBoardRetired(board.id, true)),
                )
                .board!!
                .retired
        )
        runtime.workspace.state.await(describe = { "retired" }) { it.board(board.id) == null }
        assertTrue(
            !admin(
                    "restore board",
                    AdminCommand(set_board_retired = AdminBoardRetired(board.id, false)),
                )
                .board!!
                .retired
        )
        assertEquals(0, runtime.onCore { runtime.admin.pendingIntents })

        val project =
            admin(
                    "update project",
                    AdminCommand(
                        update_project =
                            AdminUpdateProject(
                                project_id = fixture.projectId,
                                summary = "Isolated",
                                set_hostnames = true,
                                hostnames = listOf("Localhost:3000"),
                            )
                    ),
                )
                .project!!
        assertEquals("Isolated", project.summary)
        assertEquals(listOf("localhost:3000"), project.hostnames)
        val prompts =
            admin("prompt settings", AdminCommand(prompt_settings = AdminMachine(fixture.daemonId)))
                .prompt_settings!!
        assertTrue(prompts.prompt_template.contains("{{project.instructions_block}}"))
        assertTrue(
            admin(
                    "preview prompt",
                    AdminCommand(
                        preview_prompt =
                            AdminPreviewPrompt(
                                project_id = fixture.projectId,
                                board_id = fixture.boardId,
                            )
                    ),
                )
                .prompt_preview!!
                .estimated_tokens > 0
        )
        val folders =
            admin(
                    "directories",
                    AdminCommand(directories = AdminDirectories(daemon_id = fixture.daemonId)),
                )
                .directory_listing!!
        assertTrue(
            folders.entries.isNotEmpty() || folders.path.isNotEmpty(),
            "directories: $folders",
        )
        admin("archived chats", AdminCommand(archived_chats = Step())).cards!!

        // A conversation's workspace and files are read on the machine that owns it.
        val checkout =
            runtime.workspace.state.value.project(fixture.projectId)!!.checkouts.first {
                it.daemon_id == fixture.daemonId
            }
        File(checkout.path, "admin-notes.txt").writeText("for download\n")
        val document =
            admin(
                    "read file",
                    AdminCommand(
                        read_file =
                            AdminReadFile(
                                daemon_id = fixture.daemonId,
                                project_id = fixture.projectId,
                                checkout_id = checkout.id,
                                path = "admin-notes.txt",
                            )
                    ),
                )
                .file_document!!
        assertEquals("for download\n", document.content)
        val local =
            runtime.createConversation(
                CreateConversationRequest(
                    project_id = fixture.projectId,
                    board_id = fixture.boardId,
                    lane = "todo",
                    title = "Workspace",
                    prompt = "later",
                    defer_start = true,
                    workspace_mode = "project",
                ),
                chat = false,
            )
        val cardId =
            runtime.outbox.view.await(45.seconds) { local.id in it.resolutions }.resolve(local.id)
        runtime.awaitSynced(cardId)
        val workspace =
            admin(
                    "conversation workspace",
                    AdminCommand(conversation_workspace = AdminCard(cardId)),
                )
                .workspace!!
        assertEquals(File(checkout.path).canonicalPath, File(workspace.path).canonicalPath)

        // The selected machine's telemetry streams through its slice; quotas load from the gateway.
        val telemetry = MutableStateFlow<TelemetrySlice?>(null)
        val telemetryWatch =
            api.observe(Slice.SLICE_TELEMETRY, "") {
                telemetry.value = Update.ADAPTER.decode(it.encode()).telemetry
            }
        api.dispatch(
            Command(
                telemetry =
                    TelemetryCommand(
                        select = TelemetrySelect(daemon_id = fixture.daemonId, active = true)
                    )
            )
        )
        telemetry.await(20.seconds, describe = { "telemetry: ${telemetry.value}" }) { slice ->
            (slice?.machines?.get(fixture.daemonId)?.cpu_history?.size ?: 0) >= 2
        }
        assertTrue(
            telemetry.value!!
                .machines
                .getValue(fixture.daemonId)
                .information!!
                .hostname
                .isNotEmpty()
        )
        // The actions menu follows the daemon's operation capabilities, in menu order.
        val readings = telemetry.value!!.machines.getValue(fixture.daemonId)
        val expectedActions =
            MachineOperations.ACTIONS.filter {
                it != MachineOperationAction.MACHINE_OPERATION_ACTION_PRIVACY_OFF &&
                    (it != MachineOperationAction.MACHINE_OPERATION_ACTION_PRIVACY_ON ||
                        readings.information!!.os_name == "macOS")
            }
        assertEquals(expectedActions, readings.operations.map { it.action })
        assertEquals(
            expectedActions.map { MachineOperations.available(readings.information, it) },
            readings.operations.map { it.available },
        )
        api.dispatch(
            Command(telemetry = TelemetryCommand(select = TelemetrySelect(active = false)))
        )
        telemetryWatch.close()
        api.dispatch(Command(quotas = QuotasCommand(load = QuotasLoad(refresh = false))))
    }

    /**
     * A client acts on an admin result at once (it selects the new board or project), so the
     * workspace update that shows the change reaches its observer before the result does.
     */
    @Test
    fun anAdminResultFollowsTheWorkspaceUpdateThatShowsIt() = e2e {
        val fixture = fixture()
        val runtime = runtime(fixture)
        runtime.awaitConnected()
        runtime.awaitLoaded(fixture)
        val api = ClientApi(runtime)
        // The workspace as a client folds it from the slice's updates, which arrive on the core's
        // thread.
        val observed = MutableStateFlow<WorkspaceSlice?>(null)
        val watch =
            api.observe(Slice.SLICE_WORKSPACE, "") { encoded ->
                val update = Update.ADAPTER.decode(encoded.encode())
                update.workspace?.let { observed.value = it }
                update.workspace_delta?.let { delta ->
                    observed.value = SliceFolds.apply(checkNotNull(observed.value), delta)
                }
            }
        observed.await(describe = { "workspace slice" }) { slice ->
            slice?.projects?.any { it.id == fixture.projectId } == true
        }

        // Dispatched on the core's own thread, a reply cannot overtake an update already queued
        // there.
        suspend fun admin(command: AdminCommand) = runtime.onCore {
            api.dispatch(Command(admin = command)) to checkNotNull(observed.value)
        }
        fun WorkspaceSlice.boardCount(projectId: String) =
            projects.single { it.id == projectId }.board_count

        val (created, afterCreate) =
            admin(
                AdminCommand(
                    create_board =
                        AdminCreateBoard(
                            project_id = fixture.projectId,
                            name = "Sprint",
                            workflow = "direct",
                        )
                )
            )
        val board = created.board!!
        assertEquals("Sprint", afterCreate.boards.single { it.id == board.id }.name)
        assertEquals(
            afterCreate.boards.count { it.project_id == fixture.projectId },
            afterCreate.boardCount(fixture.projectId),
        )

        val (_, afterRename) =
            admin(AdminCommand(rename_board = AdminRenameBoard(board.id, "Sprint 2")))
        assertEquals("Sprint 2", afterRename.boards.single { it.id == board.id }.name)

        // Retiring and restoring keep the board's timestamp; it moves between the lists at once all
        // the same.
        val (_, afterRetire) =
            admin(AdminCommand(set_board_retired = AdminBoardRetired(board.id, true)))
        assertTrue(afterRetire.boards.none { it.id == board.id })
        assertTrue(afterRetire.retired_boards.any { it.id == board.id })
        assertEquals(
            afterRetire.boards.count { it.project_id == fixture.projectId },
            afterRetire.boardCount(fixture.projectId),
        )
        val (_, afterRestore) =
            admin(AdminCommand(set_board_retired = AdminBoardRetired(board.id, false)))
        assertTrue(afterRestore.boards.any { it.id == board.id })
        assertTrue(afterRestore.retired_boards.none { it.id == board.id })
        assertEquals(
            afterRestore.boards.count { it.project_id == fixture.projectId },
            afterRestore.boardCount(fixture.projectId),
        )

        // A new project shows with its board and the machine that holds it before any view lists
        // it.
        val folder = Files.createTempDirectory("dieter-admin-project").toFile()
        try {
            val (result, afterProject) =
                admin(
                    AdminCommand(
                        create_project =
                            AdminCreateProject(
                                daemon_id = fixture.daemonId,
                                path = File(folder, "fresh").path,
                                name = "Fresh",
                                create = true,
                                board_name = "Main",
                                workflow = "review",
                                base_remote = "origin",
                                base_branch = "main",
                            )
                    )
                )
            val response = result.created_project!!
            val project = response.project!!
            assertEquals("Fresh", afterProject.projects.single { it.id == project.id }.name)
            assertEquals(
                fixture.daemonId,
                afterProject.projects.single { it.id == project.id }.checkouts.single().daemon_id,
            )
            assertEquals(
                listOf(response.board!!.id),
                afterProject.boards.filter { it.project_id == project.id }.map { it.id },
            )
            assertEquals(1, afterProject.boardCount(project.id))
        } finally {
            watch.close()
            folder.deleteRecursively()
        }
    }
}
