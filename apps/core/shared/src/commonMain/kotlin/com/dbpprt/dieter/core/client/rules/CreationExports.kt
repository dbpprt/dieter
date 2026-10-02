package com.dbpprt.dieter.core.client.rules

import com.dbpprt.dieter.api.v1.HarnessCatalog
import com.dbpprt.dieter.api.v1.HarnessSelection
import com.dbpprt.dieter.client.v1.AgentChoice
import com.dbpprt.dieter.client.v1.AgentControlsState
import com.dbpprt.dieter.core.client.agentControlsState
import com.dbpprt.dieter.core.client.choosing
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
    /** "Worktree" or "Project directory"; anything but "worktree" is the project mode. */
    fun workspaceModeTitle(mode: String): String = WorkspaceMode.parse(mode).title

    /** "Worktree" or "Project". */
    fun workspaceModeShortTitle(mode: String): String = WorkspaceMode.parse(mode).shortTitle

    /** What the mode does, e.g. "Create a new isolated Git worktree and branch for this conversation." */
    fun workspaceModeDetail(mode: String): String = WorkspaceMode.parse(mode).detail

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
