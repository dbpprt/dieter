package com.getdieter.mobile.store

import com.getdieter.client.v1.*
import com.getdieter.core.terminals.TerminalScreen
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow

/** Terminals: every machine's overview, a conversation's terminals, and the shown screen. */
class TerminalsModel
internal constructor(
    private val context: StoreContext,
    /** True while an open conversation shows its terminals instead of the overview. */
    private val showsCard: () -> Boolean,
) {
    val overview = MutableStateFlow(TerminalOverviewSlice())
    val card = MutableStateFlow(TerminalsSlice())
    val visible = MutableStateFlow("")
    val acceptsInput = MutableStateFlow(false)
    internal val keys = MutableSharedFlow<TerminalKey>(extraBufferCapacity = 8)
    val screens = MutableStateFlow<Map<String, TerminalScreen>>(emptyMap())

    private fun scope(inCard: Boolean = showsCard()) =
        if (inCard) MobileStore.TERMINAL_SCOPE else MobileStore.TERMINAL_OVERVIEW_SCOPE

    /** Capture the owning surface before queuing, including when a departing view deactivates. */
    fun command(value: TerminalsCommand, inCard: Boolean = showsCard()) =
        context.command(Command(terminals = value.copy(scope = scope(inCard))))

    internal fun subscribe() {
        context.observeAlways(Slice.SLICE_TERMINALS, MobileStore.TERMINAL_SCOPE) { update ->
            update.terminals?.let { value ->
                if (showsCard()) {
                    retainOutput(value.output, value.terminals.map { it.id })
                    visible.value = value.selected_id
                    acceptsInput.value =
                        value.rows.firstOrNull { it.id == value.selected_id }?.accepts_input == true
                }
                card.value = value.copy(output = emptyList())
            }
        }
        context.observeAlways(Slice.SLICE_TERMINAL_OVERVIEW, MobileStore.TERMINAL_OVERVIEW_SCOPE) {
            update ->
            update.terminal_overview?.let { value ->
                if (!showsCard()) {
                    // Reduce every output delta before publishing conflatable snapshots.
                    val next = screens.value.toMutableMap()
                    value.terminals?.output.orEmpty().forEach { output ->
                        val key =
                            value.entries.firstOrNull { it.terminal?.id == output.terminal_id }?.id
                                ?: output.terminal_id
                        val previous = next[key] ?: TerminalScreen.EMPTY
                        next[key] =
                            if (output.reset) previous.reset(output.data_)
                            else previous.append(output.data_)
                    }
                    next.keys.retainAll(value.entries.map { it.id }.toSet())
                    screens.value = next
                    visible.value = value.selected_id
                    acceptsInput.value =
                        value.entries
                            .firstOrNull { it.id == value.selected_id }
                            ?.row
                            ?.accepts_input == true
                }
                overview.value = value.copy(terminals = value.terminals?.copy(output = emptyList()))
            }
        }
    }

    fun input(data: ByteArray) =
        context.input(
            Command(
                terminals =
                    TerminalsCommand(
                        scope = scope(),
                        input = TerminalInput(okio.ByteString.of(*data)),
                    )
            )
        )

    fun grid(columns: Int, rows: Int) =
        context.input(
            Command(
                terminals =
                    TerminalsCommand(
                        scope = scope(),
                        grid = TerminalGrid(columns, rows),
                    )
            )
        )

    internal fun loadOverview() =
        context.command(
            Command(
                terminal_overview =
                    TerminalOverviewCommand(
                        scope = MobileStore.TERMINAL_OVERVIEW_SCOPE,
                        load = TerminalOverviewLoad(),
                    )
            )
        )

    /** Shows [terminalId] of the open conversation ([inCard]) or of the overview. */
    internal fun select(terminalId: String, inCard: Boolean) =
        context.command(
            if (inCard)
                Command(
                    terminals =
                        TerminalsCommand(
                            scope = MobileStore.TERMINAL_SCOPE,
                            select = TerminalId(terminalId),
                        )
                )
            else
                Command(
                    terminal_overview =
                        TerminalOverviewCommand(
                            scope = MobileStore.TERMINAL_OVERVIEW_SCOPE,
                            select = TerminalId(terminalId),
                        )
                )
        )

    internal fun bindCard(daemonId: String, projectId: String, cardId: String) = context.action {
        context.core.dispatch(
            Command(
                terminals =
                    TerminalsCommand(
                        scope = MobileStore.TERMINAL_SCOPE,
                        bind =
                            TerminalTarget(
                                daemon_id = daemonId,
                                kind = TerminalTarget.Kind.KIND_CARD,
                                project_id = projectId,
                                card_id = cardId,
                            ),
                    )
            )
        )
        context.core.dispatch(
            Command(terminals = TerminalsCommand(scope = MobileStore.TERMINAL_SCOPE, load = Step()))
        )
    }

    internal suspend fun foreground(active: Boolean) {
        context.core.dispatch(
            Command(terminals = TerminalsCommand(scope = scope(), active = Toggle(active)))
        )
    }

    private fun retainOutput(output: List<TerminalOutput>, ids: List<String>) {
        val next = screens.value.toMutableMap()
        output.forEach { event ->
            val old = next[event.terminal_id] ?: TerminalScreen.EMPTY
            next[event.terminal_id] =
                if (event.reset) old.reset(event.data_) else old.append(event.data_)
        }
        next.keys.retainAll(ids.toSet())
        screens.value = next
    }
}
