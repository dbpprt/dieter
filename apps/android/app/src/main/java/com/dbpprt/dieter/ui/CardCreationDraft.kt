package com.dbpprt.dieter.ui

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.dbpprt.dieter.v1.Harness
import com.dbpprt.dieter.v1.MessagePart

/** One board-scoped draft, owned by the Activity ViewModel, not either editor. */
internal class CardCreationDraft(val id: String = java.util.UUID.randomUUID().toString()) {
    var accountId by mutableStateOf("")
    var projectId by mutableStateOf("")
    var boardId by mutableStateOf("")
    var checkoutId by mutableStateOf("")
    var submittedRequest by mutableStateOf<com.dbpprt.dieter.v1.CreateConversationRequest?>(null)
    var submissionId by mutableStateOf("")
    var importing by mutableStateOf(false)
    var persistenceError by mutableStateOf<String?>(null)
    val importFailures = mutableStateListOf<TaskImportFailure>()
    val creationTitle get() = title.trim().ifBlank {
        optimisticQuickTaskTitle(prompt).ifBlank { attachments.firstOrNull()?.filename?.takeIf(String::isNotBlank) ?: "New task" }
    }
    val generatesTitle get() = title.isBlank() && prompt.isNotBlank()
    val hasContent get() = prompt.isNotBlank() || title.isNotBlank() || attachments.isNotEmpty() || importFailures.isNotEmpty()
    val ready get() = !importing && importFailures.isEmpty() && persistenceError == null

    fun snapshot(): com.dbpprt.dieter.v1.CreateConversationRequest = submittedRequest ?: com.dbpprt.dieter.v1.CreateConversationRequest.newBuilder()
        .setTitle(title).setPrompt(prompt).setProvider(provider).setModel(model).setEffort(effort)
        .putAllProviderOptions(providerOptions).setLane(lane).setWorkspaceMode(workspaceMode.wire)
        .addAllLabelIds(labelIds).addAllAttachments(attachments).build()

    fun restore(request: com.dbpprt.dieter.v1.CreateConversationRequest) {
        title = request.title; prompt = request.prompt; provider = request.provider; model = request.model
        effort = request.effort; providerOptions = request.providerOptionsMap; lane = request.lane
        workspaceMode = ConversationWorkspaceMode.resolve(request.workspaceMode)
        labelIds.addAll(request.labelIdsList); attachments.addAll(request.attachmentsList)
        initialized = provider.isNotBlank(); initializedDestination = lane.isNotBlank()
    }

    val titleState = mutableStateOf("")
    var title by titleState
    val promptState = mutableStateOf("")
    var prompt by promptState
    val providerState = mutableStateOf("")
    var provider by providerState
    val modelState = mutableStateOf("")
    var model by modelState
    val effortState = mutableStateOf("")
    var effort by effortState
    val providerOptionsState = mutableStateOf<Map<String, String>>(emptyMap())
    var providerOptions by providerOptionsState
    val laneState = mutableStateOf("")
    var lane by laneState
    val workspaceModeState = mutableStateOf(ConversationWorkspaceMode.WORKTREE)
    var workspaceMode by workspaceModeState
    val labelIds = mutableStateListOf<String>()
    val attachments = mutableStateListOf<MessagePart>()
    var quickTaskOpen by mutableStateOf(false)
    private var initialized = false
    private var initializedDestination = false
    private var expanded = false

    // A catalog refresh or a temporary route outage must never reapply defaults
    // over an edited draft. Unsupported selections remain visible and block Save.
    fun initialize(defaults: ResolvedConversationCreationPreferences, harnesses: List<Harness>, initialLane: String) {
        if (!initializedDestination) {
            workspaceMode = defaults.workspaceMode
            lane = initialLane
            initializedDestination = true
        }
        if (initialized || !harnessCatalogSupportsSelection(harnesses, defaults.provider, defaults.model)) return
        provider = defaults.provider
        model = defaults.model
        effort = defaults.effort
        providerOptions = providerOptionValues(harnesses.first { it.id == provider }, model = model)
        initialized = true
    }

    fun markFullEditorOpened() {
        expanded = true
    }

    fun openOptions() {
        expanded = true
        quickTaskOpen = false
    }

    fun selectProvider(value: String, harnesses: List<Harness>) {
        provider = value
        selectModel(harnesses.firstOrNull { it.id == value }?.defaultModel.orEmpty(), harnesses)
    }

    fun selectModel(value: String, harnesses: List<Harness>) {
        model = value
        effort = ""
        providerOptions = providerOptionValues(harnesses.firstOrNull { it.id == provider }, model = model)
    }

    fun preferences() = ResolvedConversationCreationPreferences(provider, model, effort, workspaceMode)
}
