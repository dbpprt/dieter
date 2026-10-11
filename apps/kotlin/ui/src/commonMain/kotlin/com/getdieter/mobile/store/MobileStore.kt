package com.getdieter.mobile.store

import com.getdieter.client.v1.*
import com.getdieter.mobile.navigation.*
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch

/**
 * View lifetime and navigation only; the existing core decides all task behavior. Each feature's
 * state lives in its own holder; the store binds core scopes to the visible routes.
 */
class MobileStore(
    val core: MobileCore,
    dispatcher: CoroutineDispatcher = Dispatchers.Main,
    preferences: MobilePreferences = MobilePreferences(),
) {
    private val context = StoreContext(core, CoroutineScope(SupervisorJob() + dispatcher))
    private val navigator =
        object : StoreNavigator {
            override fun present(route: MobileRoute) = this@MobileStore.present(route)

            override fun dismiss() = this@MobileStore.dismiss()

            override fun openConversation(cardId: String) =
                this@MobileStore.openConversation(cardId)

            override fun newConversation(chat: Boolean) = this@MobileStore.newConversation(chat)
        }
    val busy = context.busy
    val error = context.error
    val routes = MutableStateFlow(MobileNavigation())
    val theme: ThemeModel = ThemeModel(preferences)
    val session: SessionModel = SessionModel(context)
    val workspace: WorkspaceModel =
        WorkspaceModel(
            context,
            changed = { sharing.deliver() },
            resolved = { conversation.follow(it) },
        )
    val boards: BoardsModel = BoardsModel(context, workspace.slice)
    val conversation: ConversationModel = ConversationModel(context, workspace.outbox)
    val creation: CreationModel =
        CreationModel(context, workspace.slice, boards, ::rebindProjectTool)
    val sharing: SharingModel = SharingModel(context, workspace.slice, creation, navigator)
    val files: FilesModel = FilesModel(context, workspace.slice, boards, creation.defaults)
    val schedules: SchedulesModel = SchedulesModel(context)
    val review: ReviewModel = ReviewModel(context, workspace.slice, boards, creation.defaults)
    val machines: MachinesModel = MachinesModel(context)
    val terminals: TerminalsModel = TerminalsModel(context) { conversation.showsTerminal }
    val screens: ScreensModel = ScreensModel(context)
    private var activeTop = ""

    init {
        // Every holder exists before the first update can reach one of them.
        context.startInput()
        session.subscribe()
        workspace.subscribe()
        boards.subscribe()
        creation.subscribe()
        files.subscribe()
        schedules.subscribe()
        review.subscribe()
        machines.subscribe()
        terminals.subscribe()
        screens.subscribe()
        conversation.loadDrafts()
    }

    fun action(block: suspend () -> Unit) = context.action(block)

    fun command(command: Command) = context.command(command)

    // Navigation -------------------------------------------------------------------------------

    /** Switches tabs; selecting the current tab again returns to its root, as on both platforms. */
    fun selectTab(value: MobileTab) {
        val current = routes.value
        routes.value =
            if (current.tab == value) current.with(value, listOf(MobileRoute.Root(value)))
            else current.copy(tab = value)
        syncNavigation()
    }

    fun push(route: MobileRoute) {
        val current = routes.value
        if (current.top == route) return
        routes.value = current.with(current.tab, current.stack + route)
        syncNavigation()
    }

    /**
     * Opens [route] from the list [source]: anything already open after that list is replaced, so
     * selecting another row swaps the detail pane on tablets and is a plain push on phones.
     */
    fun showFrom(source: MobileRoute, route: MobileRoute) {
        val current = routes.value
        val index = current.stack.indexOf(source)
        if (index < 0) return push(route)
        val base = current.stack.take(index + 1)
        if (base + route == current.stack) return
        routes.value = current.with(current.tab, base + route)
        syncNavigation()
    }

    /** Opens a conversation from a list, replacing any conversation already open after it. */
    fun openConversation(cardId: String) {
        val current = routes.value
        val id = conversation.resolve(cardId)
        val base = current.stack.dropLastWhile { it.isDetail }
        routes.value = current.with(current.tab, base + MobileRoute.Conversation(id))
        syncNavigation()
    }

    fun pop() {
        val current = routes.value
        if (current.stack.size > 1) {
            routes.value = current.with(current.tab, current.stack.dropLast(1))
            syncNavigation()
        }
    }

    /** Native back gestures report the remaining depth of a tab stack. */
    fun popTo(tab: MobileTab, depth: Int) {
        val current = routes.value
        val stack = current.stacks.getValue(tab)
        if (depth < 1 || depth >= stack.size) return
        routes.value = current.with(tab, stack.take(depth))
        syncNavigation()
    }

    fun present(route: MobileRoute) {
        routes.value = routes.value.copy(modal = route)
        syncNavigation()
    }

    fun dismiss() {
        if (routes.value.modal == null) return
        routes.value = routes.value.copy(modal = null)
        syncNavigation()
    }

    /** Android system back: modal, then stack, then the start tab. */
    fun handleBack(): Boolean {
        val current = routes.value
        when {
            current.modal != null -> dismiss()
            current.stack.size > 1 -> pop()
            current.tab != MobileTab.INBOX -> selectTab(MobileTab.INBOX)
            else -> return false
        }
        return true
    }

    fun replaceTop(route: MobileRoute) {
        val current = routes.value
        routes.value = current.with(current.tab, current.stack.dropLast(1) + route)
        syncNavigation()
    }

    /** Presents the new task or chat form for the current board. */
    fun newConversation(chat: Boolean = false) {
        creation.begin(chat)
        present(MobileRoute.NewTask(chat))
        creation.update(creation.initialIntent())
    }

    /** Debug builds replay navigation steps for screenshots; see [runDebugScript]. */
    fun debugScript(script: String) {
        context.scope.launch { runDebugScript(script) }
    }

    fun setForeground(active: Boolean) = action {
        if (!active) conversation.flushDrafts()
        core.dispatch(Command(set_foreground = SetForeground(active)))
        screens.foreground(active)
        if (
            (routes.value.top as? MobileRoute.Tool)?.page == ToolPage.TERMINALS ||
                conversation.showsTerminal
        )
            terminals.foreground(active)
    }

    fun close() {
        if (context.closed) return
        context.closed = true
        conversation.release()
        context.release()
    }

    /** Binds core scopes to the visible routes. Navigation itself carries no business rules. */
    private fun syncNavigation() {
        val state = routes.value
        val stack = state.stack
        val cardId = stack.lastOrNull { it.isDetail }?.cardScope
        stack
            .lastOrNull { it is MobileRoute.Board }
            ?.let { board ->
                board as MobileRoute.Board
                if (board.boardId != boards.selectedBoard.value) boards.chooseBoard(board.boardId)
            }
        stack
            .lastOrNull { it is MobileRoute.Project }
            ?.let { project ->
                project as MobileRoute.Project
                if (project.projectId != boards.selectedProject.value)
                    boards.selectProject(project.projectId)
            }
        if (cardId == null) {
            if (conversation.selectedCard.value.isNotEmpty()) conversation.unbind()
        } else {
            conversation.bind(cardId)
            val pane =
                stack
                    .lastOrNull { it is MobileRoute.Pane || it is MobileRoute.Conversation }
                    .let { (it as? MobileRoute.Pane)?.pane }
            val wanted = pane?.title ?: "Conversation"
            if (conversation.detailTab.value != wanted) selectDetail(wanted)
        }
        val screen =
            stack.lastOrNull { it is MobileRoute.ScreenSession } as? MobileRoute.ScreenSession
        if (screen == null && screens.selected.value.isNotEmpty()) screens.close()
        else if (screen != null && screen.machineId != screens.selected.value)
            screens.open(screen.machineId)
        machines.select((stack.lastOrNull() as? MobileRoute.Machine)?.machineId.orEmpty())
        val top = state.modal ?: state.top
        if (top.key == activeTop) return
        activeTop = top.key
        when (top) {
            is MobileRoute.Root -> if (top.tab == MobileTab.INBOX) machines.loadQuotas()
            is MobileRoute.Tool -> {
                if (top.projectId.isNotEmpty() && top.projectId != boards.selectedProject.value)
                    boards.selectProject(top.projectId)
                if (top.page == ToolPage.FILES && files.slice.value.directory.isNotEmpty())
                    files.command(FilesCommand(navigate = FilesPath("")))
                activateTool(top.page)
            }
            is MobileRoute.Pane ->
                if (top.pane == CardPane.FILES && files.slice.value.directory.isNotEmpty())
                    files.command(FilesCommand(navigate = FilesPath("")))
            is MobileRoute.FilePath ->
                files.command(
                    if (top.file) FilesCommand(open_ = FilesPath(top.path))
                    else FilesCommand(navigate = FilesPath(top.path))
                )
            is MobileRoute.TerminalSession ->
                terminals.select(top.terminalId, inCard = top.cardId.isNotEmpty())
            else -> Unit
        }
        // Leaving a document returns the shared files scope to its listing.
        if (top !is MobileRoute.FilePath || !top.file) {
            val document = files.slice.value.selected_path
            if (
                document.isNotEmpty() &&
                    stack.none { it is MobileRoute.FilePath && it.file && it.path == document }
            )
                files.command(FilesCommand(close = Step()))
        }
    }

    /** Shows a conversation pane and binds the scope it reads. */
    private fun selectDetail(value: String) {
        conversation.detailTab.value = value
        val open = conversation.slice.value
        val cardId = conversation.selectedCard.value
        val projectId = open.card?.project_id.orEmpty()
        if (value == "Processes")
            review.bindProcesses(open.daemon_id, boards.currentProjectId(), cardId)
        if (value == "Changes") review.bindCard(cardId, open.daemon_id)
        if (value == "Files") files.bindCard(open.daemon_id, projectId, cardId)
        if (value == "Terminal") terminals.bindCard(open.daemon_id, projectId, cardId)
    }

    private fun activateTool(page: ToolPage) {
        when (page) {
            ToolPage.FILES -> files.bindProject()
            ToolPage.CHANGES -> review.bindProjectChanges()
            ToolPage.SCHEDULES -> schedules.load(boards.currentProjectId())
            ToolPage.TERMINALS -> terminals.loadOverview()
            ToolPage.USAGE -> machines.loadQuotas()
            else -> Unit
        }
    }

    /** New creation defaults can change the checkout a visible project tool shows. */
    private fun rebindProjectTool() {
        when ((routes.value.modal ?: routes.value.top).let { it as? MobileRoute.Tool }?.page) {
            ToolPage.FILES -> files.bindProject()
            ToolPage.CHANGES -> review.bindProjectChanges()
            else -> Unit
        }
    }

    companion object {
        const val BOARD_SCOPE = "mobile-board"
        const val CHATS_SCOPE = "mobile-chats"
        const val FORM_SCOPE = "mobile-creation"
        const val FILES_SCOPE = "mobile-files"
        const val SCHEDULES_SCOPE = "mobile-schedules"
        const val REVIEW_SCOPE = "mobile-review"
        const val TERMINAL_SCOPE = "mobile-terminals"
        const val PROJECT_CHANGES_SCOPE = "mobile-project-changes"
        const val PROCESSES_SCOPE = "mobile-processes"
        const val SCREEN_SCOPE = "mobile-screen"
    }
}
