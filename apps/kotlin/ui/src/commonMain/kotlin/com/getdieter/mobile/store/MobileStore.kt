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
    val layout: LayoutModel = LayoutModel(preferences)
    val session: SessionModel = SessionModel(context)
    val workspace: WorkspaceModel =
        WorkspaceModel(
            context,
            changed = { sharing.deliver() },
            resolved = { conversation.follow(it) },
        )
    val boards: BoardsModel = BoardsModel(context)
    val conversation: ConversationModel = ConversationModel(context, workspace.outbox)
    val creation: CreationModel =
        CreationModel(context, workspace.slice, boards, ::rebindProjectTool)
    val sharing: SharingModel = SharingModel(context, workspace.slice, creation, navigator)
    val files: FilesModel = FilesModel(context, workspace.slice, creation.defaults, ::available)
    val schedules: SchedulesModel = SchedulesModel(context)
    val review: ReviewModel = ReviewModel(context, workspace.slice, creation.defaults, ::available)
    val machines: MachinesModel = MachinesModel(context)
    val terminals: TerminalsModel =
        TerminalsModel(context) {
            when (val top = routes.value.top) {
                is MobileRoute.TerminalSession -> top.cardId.isNotEmpty()
                is MobileRoute.Pane -> top.pane == CardPane.TERMINAL
                else -> false
            }
        }
    val screens: ScreensModel = ScreensModel(context)
    val devices: DevicesModel = DevicesModel(context)
    val channels: ChannelsModel = ChannelsModel(context)
    val mail: MailModel = MailModel(context)

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
        channels.subscribe()
        mail.subscribe()
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

    /**
     * Opens [route] in More, above the More page, as choosing it from the More sheet or page does.
     */
    fun openMore(route: MobileRoute) {
        val current = routes.value
        val stack = listOf(MobileRoute.Root(MobileTab.MORE), route)
        if (current.tab == MobileTab.MORE && current.stack == stack) return
        routes.value = current.copy(tab = MobileTab.MORE).with(MobileTab.MORE, stack)
        syncNavigation()
    }

    /**
     * Opens [projectId]'s channel above what is shown, e.g. from a channel message in a turn, so
     * back returns to it.
     */
    fun openChannel(projectId: String) = push(MobileRoute.Channel(projectId))

    /** The checkout a project tool route shows; see [toolCheckout]. */
    fun toolCheckout(route: MobileRoute.Tool): com.getdieter.api.v1.Checkout? =
        workspace.slice.value.projects
            .firstOrNull { it.id == route.projectId }
            ?.toolCheckout(
                route.checkoutId,
                creation.defaults.value.checkouts[route.projectId].orEmpty(),
                ::available,
            )

    private fun available(daemonId: String) =
        session.slice.value.machines.any { it.id == daemonId && it.available }

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

    private var foreground: Boolean? = null

    /**
     * The app came to or left the screen. Only a change counts: a repeated foreground signal would
     * make the core start over on new connections, as after a sleep.
     */
    fun setForeground(active: Boolean) {
        if (foreground == active) return
        foreground = active
        applyForeground(active)
    }

    private fun applyForeground(active: Boolean) = action {
        if (!active) conversation.flushDrafts()
        core.dispatch(Command(set_foreground = SetForeground(active)))
        screens.foreground(active)
        if (
            (routes.value.top as? MobileRoute.Tool)?.page == ToolPage.TERMINALS ||
                routes.value.top is MobileRoute.Machine ||
                routes.value.top is MobileRoute.TerminalSession ||
                conversation.showsTerminal
        )
            terminals.foreground(active)
    }

    fun close() {
        if (context.closed) return
        context.closed = true
        conversation.release()
        devices.release()
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
        channels.show((state.top as? MobileRoute.Channel)?.projectId)
        // The message open in Mail stays selected beneath a conversation it opened.
        val more = state.stacks.getValue(MobileTab.MORE)
        mail.show(
            more
                .lastOrNull { it is MobileRoute.MailMessage }
                ?.let { it as MobileRoute.MailMessage }
                ?.let { MailMessageRef(daemon_id = it.daemonId, id = it.id) }
        )
        mail.setActive(state.tab == MobileTab.MORE && MobileRoute.Mailbox in more)
        val top = state.modal ?: state.top
        if (top.key == activeTop) return
        activeTop = top.key
        when (top) {
            is MobileRoute.Root ->
                when (top.tab) {
                    // Inbox and More show the lowest provider quota.
                    MobileTab.INBOX,
                    MobileTab.MORE -> machines.loadQuotas()
                    else -> Unit
                }
            is MobileRoute.Channels -> channels.refresh()
            // A machine's page lists its terminals.
            is MobileRoute.Machine -> terminals.loadOverview()
            is MobileRoute.Tool -> {
                if (top.page == ToolPage.FILES && files.slice.value.directory.isNotEmpty())
                    files.command(FilesCommand(navigate = FilesPath("")))
                activateTool(top)
            }
            is MobileRoute.Pane ->
                if (top.pane == CardPane.FILES && files.slice.value.directory.isNotEmpty())
                    files.command(FilesCommand(navigate = FilesPath("")))
            is MobileRoute.FilePath -> {
                if (top.checkoutId.isNotEmpty())
                    files.bindCheckout(top.daemonId, top.projectId, top.checkoutId)
                files.command(
                    if (top.file) FilesCommand(open_ = FilesPath(top.path))
                    else FilesCommand(navigate = FilesPath(top.path))
                )
            }
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
        if (value == "Processes") review.bindProcesses(open.daemon_id, projectId, cardId)
        if (value == "Changes") review.bindCard(cardId, open.daemon_id)
        if (value == "Files") files.bindCard(open.daemon_id, projectId, cardId)
        if (value == "Terminal") terminals.bindCard(open.daemon_id, projectId, cardId)
    }

    /** Binds a tool page to the scope its route carries. */
    private fun activateTool(route: MobileRoute.Tool) {
        when (route.page) {
            ToolPage.FILES -> files.bindProject(route.projectId, route.checkoutId)
            ToolPage.CHANGES -> review.bindProjectChanges(route.projectId, route.checkoutId)
            ToolPage.SCHEDULES -> schedules.load(route.projectId)
            ToolPage.TERMINALS -> terminals.loadOverview()
            ToolPage.USAGE -> machines.loadQuotas()
            else -> Unit
        }
    }

    /**
     * New creation defaults can change the checkout a visible project tool shows when its route
     * names none.
     */
    private fun rebindProjectTool() {
        val route = (routes.value.modal ?: routes.value.top) as? MobileRoute.Tool ?: return
        if (route.checkoutId.isNotEmpty()) return
        when (route.page) {
            ToolPage.FILES -> files.bindProject(route.projectId)
            ToolPage.CHANGES -> review.bindProjectChanges(route.projectId)
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
        const val TERMINAL_OVERVIEW_SCOPE = "mobile-terminal-overview"
        const val PROJECT_CHANGES_SCOPE = "mobile-project-changes"
        const val PROCESSES_SCOPE = "mobile-processes"
        const val SCREEN_SCOPE = "mobile-screen"
        const val CHANNELS_SCOPE = "mobile-channels"
        const val MAIL_SCOPE = "mobile-mail"
    }
}
