package com.dbpprt.dieter.core.client.rules

import com.dbpprt.dieter.api.v1.Checkout
import com.dbpprt.dieter.api.v1.HarnessCatalog
import com.dbpprt.dieter.api.v1.HarnessSelection
import com.dbpprt.dieter.api.v1.Project
import com.dbpprt.dieter.client.v1.AgentChoice
import com.dbpprt.dieter.client.v1.AgentControlsState
import com.dbpprt.dieter.client.v1.ChatDestination
import com.dbpprt.dieter.client.v1.ChatDestinationGroups
import com.dbpprt.dieter.client.v1.ChatDestinationInput
import com.dbpprt.dieter.client.v1.Checkouts
import com.dbpprt.dieter.client.v1.HostnameSets
import com.dbpprt.dieter.core.client.agentControlsState
import com.dbpprt.dieter.core.client.choosing
import com.dbpprt.dieter.core.composition.CapturePages
import com.dbpprt.dieter.core.composition.ChatDestinations
import com.dbpprt.dieter.core.composition.Creation
import com.dbpprt.dieter.core.composition.WorkspaceMode
import com.dbpprt.dieter.core.selection.AgentControls
import com.dbpprt.dieter.core.selection.Selections

/**
 * Agent pickers for a form that keeps its own selection outside a
 * conversation or creation preview, e.g. a never-started card's editor, and
 * the workspace modes' wording for forms without a creation preview.
 */
object CreationExports {
    /** Where a new chat can run: every attached checkout of the input's projects, grouped by machine. */
    fun chatDestinations(input: ChatDestinationInput): ChatDestinationGroups =
        ChatDestinationGroups(ChatDestinations.groups(input.projects, input.machines))

    /** The destination to show first; empty when there is none. */
    fun preferredChatDestination(groups: ChatDestinationGroups, machineId: String, projectId: String, checkoutId: String): ChatDestination =
        ChatDestinations.preferred(groups.groups, machineId, projectId, checkoutId) ?: ChatDestination()

    /** [value] trimmed when it is an http(s) page a capture may record, else "". */
    fun capturePage(value: String): String = CapturePages.page(value).orEmpty()

    /** The page's "host" or "host:port" as hostnames store it, else "". */
    fun captureHostname(value: String): String = CapturePages.hostname(value).orEmpty()

    /** The indices of [candidates] whose hostnames route the page at [url], the most specific first. */
    fun captureMatches(url: String, candidates: HostnameSets): List<Int> = CapturePages.matches(url, candidates.sets.map { it.hostnames })

    /** The value a toggle provider option takes when switched [on] or off. */
    fun toggleOptionValue(on: Boolean): String = Selections.toggleValue(on)

    /** The checkouts a destination picker offers for [project]: every attached one, in order. */
    fun checkoutChoices(project: Project): Checkouts = Checkouts(Creation.choices(project))

    /** A checkout as destination pickers name it: its name, else "Project checkout", ending " · Offline" while its machine is offline. */
    fun checkoutTitle(name: String, machineOnline: Boolean): String = Creation.checkoutTitle(Checkout(name = name), machineOnline)

    /** "Worktree" or "Project directory"; anything but "worktree" is the project mode. */
    fun workspaceModeTitle(mode: String): String = WorkspaceMode.parse(mode).title

    /** "Worktree" or "Project". */
    fun workspaceModeShortTitle(mode: String): String = WorkspaceMode.parse(mode).shortTitle

    /** What the mode does, e.g. "Create a new isolated Git worktree and branch for this conversation." */
    fun workspaceModeDetail(mode: String): String = WorkspaceMode.parse(mode).detail

    /** The modes a picker offers, in order: "worktree", then "project". */
    fun workspaceModes(): List<String> = WorkspaceMode.choices.map { it.wire }

    /** How a picker offers the mode for a new conversation: "New worktree" or "Project directory". */
    fun workspaceModeChoiceTitle(mode: String): String = WorkspaceMode.parse(mode).choiceTitle

    /** A created conversation opens: a chat, or a task created outside Todo, which starts at once. */
    fun opensAfterCreate(chat: Boolean, lane: String): Boolean = Creation.opensAfterCreate(chat, lane)

    /**
     * The pickers for [selection] against [catalog] (the machine's agents);
     * [locked] for a started conversation. A blank provider takes the
     * catalog's first agent and its defaults; a chosen one is
     * [Selections.validated]. A [choice] (one without a member means none)
     * applies first when the pickers allow it, so the state shows the next
     * selection.
     */
    fun agentControls(selection: HarnessSelection, catalog: HarnessCatalog, locked: Boolean, choice: AgentChoice): AgentControlsState {
        val harnesses = catalog.harnesses
        val start = if (selection.provider.isEmpty()) Selections.resolve(selection, harnesses) ?: selection else Selections.validated(selection, harnesses)
        val controls = AgentControls(start, harnesses, locked = locked)
        val chosen = choice.provider != null || choice.model != null || choice.effort != null || choice.option != null
        val next = if (chosen) runCatching { controls.choosing(choice) }.getOrDefault(start) else start
        return agentControlsState(controls.copy(selection = next))
    }
}
