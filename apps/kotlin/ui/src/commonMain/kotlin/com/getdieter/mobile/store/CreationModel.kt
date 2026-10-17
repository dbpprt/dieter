package com.getdieter.mobile.store

import com.getdieter.api.v1.HarnessSelection
import com.getdieter.client.v1.*
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch

/** The new task or chat form: the core's defaults and preview of the form's intent. */
class CreationModel
internal constructor(
    private val context: StoreContext,
    private val workspace: StateFlow<WorkspaceSlice>,
    private val boards: BoardsModel,
    /** Runs after new creation defaults arrive, e.g. to rebind a project tool's checkout. */
    private val defaultsChanged: () -> Unit,
) {
    // Explicit choices use the core's selection validation; null uses its remembered defaults.
    var agentSelection: HarnessSelection? = null
    val defaults = MutableStateFlow(CreationSlice())
    val preview = MutableStateFlow(CreationPreview())
    val intent = MutableStateFlow(CreationIntent())
    val chat = MutableStateFlow(false)
    private var previewJob: Job? = null
    private val pendingAgentChoices = mutableListOf<AgentChoice>()

    internal fun subscribe() {
        context.observeAlways(Slice.SLICE_CREATION, "") {
            it.creation?.let { value ->
                defaults.value = value
                defaultsChanged()
            }
        }
        context.observeAlways(Slice.SLICE_CREATION_PREVIEW, MobileStore.FORM_SCOPE) { update ->
            // The core previews the bound form again when catalogs, presence or routes
            // change, such as once agent models load. A request in flight answers for
            // newer input instead; the form keeps its own intent either way.
            update.creation_preview?.let { if (previewJob?.isActive != true) preview.value = it }
        }
    }

    /** Starts a new task or chat form; [initialIntent] then fills it. */
    internal fun begin(chat: Boolean) {
        pendingAgentChoices.clear()
        this.chat.value = chat
    }

    internal fun initialIntent() = CreationIntent(selection = agentSelection)

    /** Takes the form's [intent] and previews it with the core, applying [choice] once. */
    fun update(intent: CreationIntent, choice: AgentChoice? = null) {
        choice?.let { pendingAgentChoices += it }
        this.intent.value = intent
        previewJob?.cancel()
        previewJob =
            context.scope.launch {
                delay(100)
                try {
                    val choices = pendingAgentChoices.toList()
                    var resolvedIntent = intent
                    var response: CreationPreview? = null
                    for (agentChoice in if (choices.isEmpty()) listOf(null) else choices) {
                        response =
                            context.core
                                .dispatch(
                                    Command(
                                        creation_preview =
                                            CreationPreviewCommand(
                                                scope = MobileStore.FORM_SCOPE,
                                                intent = resolvedIntent,
                                                chat = chat.value,
                                                choice = agentChoice,
                                            )
                                    )
                                )
                                .creation_preview
                        ensureActive()
                        resolvedIntent = response?.intent ?: resolvedIntent
                    }
                    ensureActive()
                    if (response != null) {
                        preview.value = response
                        // Previews leave attachments out; the form keeps its own.
                        this@CreationModel.intent.value =
                            (response.intent ?: intent).copy(attachments = intent.attachments)
                        repeat(choices.size) {
                            if (pendingAgentChoices.isNotEmpty()) pendingAgentChoices.removeAt(0)
                        }
                    }
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (failure: Throwable) {
                    context.error.value = failure.message ?: "Unable to preview the task."
                }
            }
    }

    suspend fun submit(intent: CreationIntent): String {
        previewJob?.join()
        val resolved = this.intent.value.copy(lane = intent.lane)
        return context.core
            .dispatch(
                Command(
                    create_conversation = CreateConversation(chat = chat.value, intent = resolved)
                )
            )
            .card
            ?.id ?: error("The core returned no conversation.")
    }

    /** Creates a task on the selected board, or the first one. */
    suspend fun create(title: String, prompt: String, run: Boolean): String {
        val destination =
            workspace.value.boards.firstOrNull { it.id == boards.selectedBoard.value }
                ?: workspace.value.boards.firstOrNull()
                ?: error("Choose a board first.")
        val result =
            context.core.dispatch(
                Command(
                    create_conversation =
                        CreateConversation(
                            intent =
                                CreationIntent(
                                    project_id = destination.project_id,
                                    board_id = destination.id,
                                    title = title,
                                    prompt = prompt,
                                    selection = agentSelection,
                                    lane = if (run) "running" else "todo",
                                    workspace_mode = "project",
                                )
                        )
                )
            )
        return result.card?.id ?: error("The core returned no task.")
    }
}
