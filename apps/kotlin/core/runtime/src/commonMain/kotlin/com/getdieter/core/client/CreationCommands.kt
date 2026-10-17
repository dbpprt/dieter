package com.getdieter.core.client

import com.getdieter.api.v1.Card
import com.getdieter.api.v1.HarnessSelection
import com.getdieter.api.v1.Project
import com.getdieter.client.v1.AgentChoice
import com.getdieter.client.v1.AgentControlsState
import com.getdieter.client.v1.AgentOptionKind
import com.getdieter.client.v1.AgentPickerItem
import com.getdieter.client.v1.CreationCatalogState
import com.getdieter.client.v1.CreationIntent
import com.getdieter.client.v1.CreationPreview
import com.getdieter.client.v1.CreationPreviewCommand
import com.getdieter.client.v1.CreationSlice
import com.getdieter.core.CoreRuntime
import com.getdieter.core.composition.CatalogState
import com.getdieter.core.composition.Creation
import com.getdieter.core.composition.CreationInput
import com.getdieter.core.composition.CreationMemory
import com.getdieter.core.composition.CreationPlan
import com.getdieter.core.composition.DraftKey
import com.getdieter.core.composition.WorkspaceMode
import com.getdieter.core.conversation.ConversationView
import com.getdieter.core.metadata.MachineMetadata
import com.getdieter.core.selection.AgentControls
import com.getdieter.core.selection.ProviderOptionKind
import com.getdieter.core.selection.Selections
import com.getdieter.core.store.WorkspaceView
import com.getdieter.core.v1.CreationPreferences
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Creation choices remembered on this device, with each loaded project's board
 * ([Creation.preferredBoard]) and checkout ([Creation.preferredCheckout]) to preselect. A project
 * not loaded yet keeps the board last chosen.
 */
internal fun creationSlice(
    saved: CreationPreferences,
    workspace: WorkspaceView,
    localDaemonId: String?,
): CreationSlice {
    val boards =
        workspace.projects
            .mapNotNull { project ->
                Creation.preferredBoard(
                        saved.boards[project.id],
                        workspace.boards[project.id].orEmpty(),
                    )
                    ?.let { project.id to it.id }
            }
            .toMap()
    val checkouts =
        workspace.projects
            .mapNotNull { project ->
                Creation.preferredCheckout(project, saved.checkouts[project.id], localDaemonId)
                    ?.let { project.id to it.id }
            }
            .toMap()
    return CreationSlice(
        workspace_mode = saved.workspace_mode,
        project_id = saved.project_id,
        boards = saved.boards.filterKeys { workspace.project(it) == null } + boards,
        checkouts = checkouts,
    )
}

/**
 * [intent] for a task or [chat] with the core's defaults applied: the preferred checkout, the
 * preferred board and its default lane (a task's), the agent last chosen resolved against the
 * catalog the pickers show, and the workspace mode last chosen. A chosen agent is
 * [Selections.validated].
 */
internal fun CoreRuntime.creationInput(intent: CreationIntent, chat: Boolean): CreationInput {
    val view = workspace.state.value
    val project =
        if (intent.project_id.isNotEmpty()) view.project(intent.project_id) ?: Project()
        else
            view.project(creation.state.value.project_id)
                ?: view.projects.firstOrNull()
                ?: Project()
    val destinations = creationDestinations()
    val checkoutId =
        intent.checkout_id.ifEmpty {
            creation.preferredCheckout(project, destinations.localDaemonId)?.id.orEmpty()
        }
    val board =
        when {
            chat -> null
            intent.board_id.isNotEmpty() ->
                view.board(intent.board_id)
                    ?: view.retiredBoards.firstOrNull { it.id == intent.board_id }
            else -> creation.rememberedBoard(project, view.boards[project.id].orEmpty())
        }
    val harnesses =
        Creation.catalogMachine(
                Creation.checkout(project, checkoutId),
                destinations.projectMachines[project.id],
            )
            ?.let(destinations.catalogs::get)
            .orEmpty()
    val selection =
        intent.selection
            ?.takeIf { it.provider.isNotEmpty() }
            ?.let { Selections.validated(it, harnesses) }
            ?: creation.selection(harnesses)
            ?: HarnessSelection()
    return CreationInput(
        project = project,
        board = board,
        checkoutId = checkoutId,
        chat = chat,
        lane = if (chat) "" else intent.lane.ifEmpty { Creation.defaultLane(board) },
        title = intent.title,
        prompt = intent.prompt,
        attachments = intent.attachments,
        selection = selection,
        labelIds = if (chat) emptyList() else intent.label_ids,
        workspaceMode =
            intent.workspace_mode.ifEmpty { null }?.let(WorkspaceMode::parse)
                ?: creation.workspaceMode,
        workspaceBranch = intent.workspace_branch,
        workspaceBaseBranch = intent.workspace_base_branch,
        workspaceBaseRemote = intent.workspace_base_remote,
        remotePublishMode = intent.remote_publish_mode,
        vaultAccess = intent.vault_access,
    )
}

/**
 * Queues [intent] ([CoreRuntime.create]). An online destination whose catalog has not arrived yet
 * is given up to [Creation.CATALOG_WAIT], and the defaults (e.g. the agent last chosen, else the
 * machine's first) are applied again against it, as the form's preview would show them.
 */
internal suspend fun CoreRuntime.createFromIntent(
    intent: CreationIntent,
    chat: Boolean,
    submissionId: String?,
): Card {
    var input = creationInput(intent, chat)
    val plan = planCreation(input)
    val daemonId = plan.daemonId
    if (plan.needsCatalog && daemonId != null) {
        withTimeoutOrNull(Creation.CATALOG_WAIT) {
            metadata.machines.first { it[daemonId]?.loaded == true }
        }
        input = creationInput(intent, chat)
    }
    return create(input, submissionId = submissionId)
}

/** [input] as the intent a form sends back; attachments are left out, so the form keeps its own. */
internal fun creationIntent(input: CreationInput): CreationIntent =
    CreationIntent(
        project_id = input.project.id,
        board_id = input.board?.id.orEmpty(),
        checkout_id = input.checkoutId,
        lane = input.lane,
        title = input.title,
        prompt = input.prompt,
        selection = input.selection,
        label_ids = input.labelIds,
        workspace_mode = input.workspaceMode.wire,
        workspace_branch = input.workspaceBranch,
        workspace_base_branch = input.workspaceBaseBranch,
        workspace_base_remote = input.workspaceBaseRemote,
        remote_publish_mode = input.remotePublishMode,
        vault_access = input.vaultAccess,
    )

/**
 * One creation form's preview (SLICE_CREATION_PREVIEW): the intent the form binds, previewed again
 * whenever the workspace, a machine's catalog, presence or route, or the remembered choices change,
 * so a catalog that arrives late updates the form. Confined to the core dispatcher.
 */
internal class CreationPreviewSurface(private val runtime: CoreRuntime) {
    private data class Form(val intent: CreationIntent, val chat: Boolean)

    private val form = MutableStateFlow<Form?>(null)

    val view: Flow<CreationPreview> =
        combine(
                form.filterNotNull(),
                runtime.workspace.state,
                runtime.metadata.machines,
                runtime.connection.machines,
                combine(runtime.sessions.routes, runtime.creation.state, ::Pair),
            ) { bound, _, _, _, _ ->
                preview(bound)
            }
            .distinctUntilChanged()

    /**
     * Binds the form to [command]'s intent, after an agent picker's choice applies to its agent;
     * returns the preview. Fields the intent leaves empty keep following the core's defaults.
     */
    suspend fun bind(command: CreationPreviewCommand): CreationPreview {
        var intent = command.intent ?: CreationIntent()
        command.choice?.let { choice ->
            val input = runtime.creationInput(intent, command.chat)
            intent = intent.copy(selection = runtime.planCreation(input).controls.choosing(choice))
        }
        // Persist explicit form choices, even when the user closes without submitting.
        // Unset fields keep following defaults; a loading catalog must not replace them.
        runtime.creation.rememberChoices(intent, command.chat)
        val bound = Form(intent, command.chat)
        form.value = bound
        return preview(bound)
    }

    private suspend fun preview(form: Form): CreationPreview =
        creationPreview(runtime.planCreation(runtime.creationInput(form.intent, form.chat)))
}

/** Remember only chosen fields; an unresolved preview must not erase saved defaults. */
internal fun CreationMemory.rememberChoices(intent: CreationIntent, chat: Boolean) {
    remember(
        selection = intent.selection?.takeIf { it.provider.isNotEmpty() },
        workspaceMode = intent.workspace_mode.takeIf { it.isNotEmpty() }?.let(WorkspaceMode::parse),
        projectId = intent.project_id.ifEmpty { null },
        boardId = intent.board_id.takeIf { !chat && it.isNotEmpty() },
        checkoutId = intent.checkout_id.ifEmpty { null },
    )
}

/** What a creation form shows for [plan]. */
internal fun creationPreview(plan: CreationPlan): CreationPreview {
    val input = plan.input
    return CreationPreview(
        problem = plan.problem.orEmpty(),
        intent = creationIntent(input),
        catalog =
            when (plan.catalogState) {
                CatalogState.NONE -> CreationCatalogState.CREATION_CATALOG_STATE_NONE
                CatalogState.CACHED -> CreationCatalogState.CREATION_CATALOG_STATE_CACHED
                CatalogState.LIVE -> CreationCatalogState.CREATION_CATALOG_STATE_LIVE
            },
        destination_status = plan.destinationStatus,
        offline_hint = plan.offlineHint.orEmpty(),
        agent = agentControlsState(plan.controls),
        start_lanes = if (input.chat) emptyList() else Creation.startLanes(input.board),
        title = Creation.title(input),
        defers_start = Creation.defersStart(input.chat, input.lane),
        opens_after_create = Creation.opensAfterCreate(input.chat, input.lane),
        summary =
            Creation.summary(
                input.chat,
                input.lane,
                input.board,
                input.workspaceMode,
                input.selection,
                plan.harnesses,
            ),
        daemon_id = plan.daemonId.orEmpty(),
        workspace_detail = input.workspaceMode.detail,
    )
}

/**
 * Agent pickers as the client contract carries them; picker entries are named by the catalog, else
 * by their ID.
 */
internal fun agentControlsState(controls: AgentControls): AgentControlsState =
    AgentControlsState(
        selection = controls.selection,
        providers = controls.harnesses.map { AgentPickerItem(it.id, it.name.ifEmpty { it.id }) },
        models =
            controls.harness?.models.orEmpty().map {
                AgentPickerItem(it.id, it.name.ifEmpty { it.id })
            },
        provider_enabled = controls.providerEnabled,
        model_enabled = controls.modelEnabled,
        effort_enabled = controls.effortEnabled,
        provider_label = controls.providerLabel,
        model_label = controls.modelLabel,
        effort_label = controls.effortLabel,
        efforts = controls.efforts,
        options =
            controls.options.map { option ->
                option.copy(
                    choices = option.choices.map { it.copy(name = it.name.ifEmpty { it.value_ }) }
                )
            },
        option_values = controls.optionValues,
        option_enabled = controls.options.associate { it.id to controls.optionEnabled(it) },
        effort_choices = controls.effortChoices,
        effort_value = controls.effortValue,
        fast_mode = controls.fastMode,
        fast_option_id = controls.fastOptionId.orEmpty(),
        option_kinds =
            controls.options.associate {
                it.id to
                    when (Selections.optionKind(it)) {
                        ProviderOptionKind.TOGGLE -> AgentOptionKind.AGENT_OPTION_KIND_TOGGLE
                        ProviderOptionKind.CHOICE -> AgentOptionKind.AGENT_OPTION_KIND_CHOICE
                        ProviderOptionKind.TEXT -> AgentOptionKind.AGENT_OPTION_KIND_TEXT
                    }
            },
        option_on =
            controls.options
                .filter { Selections.optionKind(it) == ProviderOptionKind.TOGGLE }
                .associate { it.id to Selections.isOn(controls.optionValue(it)) },
    )

/**
 * The composer of [view] as the conversation slice shows it ([AgentControls.forComposer]) for
 * [card]: the composer's choice from [selections], else the card's agent, against the catalog of
 * the machine that runs it. Null until the card and its machine are known.
 */
internal fun composerAgent(
    view: ConversationView,
    card: Card?,
    selections: Map<DraftKey, HarnessSelection>,
    machines: Map<String, MachineMetadata>,
): AgentControlsState? {
    val daemonId = view.daemonId ?: return null
    card ?: return null
    val harnesses = machines[daemonId]?.harnesses?.harnesses.orEmpty()
    return agentControlsState(
        AgentControls.forComposer(
            selections[DraftKey(daemonId, view.cardId)],
            card,
            harnesses,
            hasMessages = view.messages.isNotEmpty(),
        )
    )
}

/**
 * The selection [choice] makes in these pickers. A choice the pickers do not allow now (a started
 * conversation's provider, a model or effort its harness keeps, an immutable option) or that names
 * nothing they offer is rejected.
 */
internal fun AgentControls.choosing(choice: AgentChoice): HarnessSelection {
    choice.provider?.let { id ->
        if (!providerEnabled) invalid("A started conversation keeps its agent.")
        val next =
            Selections.harness(harnesses, id)
                ?: invalid("That agent is not available on this machine.")
        return choosingProvider(next)
    }
    choice.model?.let { id ->
        if (!modelEnabled) invalid("This agent cannot change the model of a started conversation.")
        if (harness != null && harness?.models.orEmpty().none { it.id == id })
            invalid("That model is not available for this agent.")
        return choosingModel(id)
    }
    choice.effort?.let { id ->
        if (!effortEnabled)
            invalid("This agent cannot change the effort of a started conversation.")
        return choosingEffort(id)
    }
    choice.option?.let { setting ->
        val option =
            options.firstOrNull { it.id == setting.id }
                ?: invalid("That option does not apply to this model.")
        if (!optionEnabled(option)) invalid("This option cannot change in a started conversation.")
        return settingOption(option.id, setting.option_value)
    }
    invalid("Choose an agent setting.")
}
