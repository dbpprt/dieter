package com.dbpprt.dieter.shared

import com.dbpprt.dieter.api.v1.Board
import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.HarnessCatalog
import com.dbpprt.dieter.api.v1.HarnessSelection
import com.dbpprt.dieter.api.v1.Subagent
import com.dbpprt.dieter.api.v1.TaskPlan
import com.dbpprt.dieter.client.v1.ActivityTimelineBar
import com.dbpprt.dieter.client.v1.AgentChoice
import com.dbpprt.dieter.client.v1.AgentControlsState
import com.dbpprt.dieter.client.v1.BoardCardFlags
import com.dbpprt.dieter.client.v1.BoardViewSlice
import com.dbpprt.dieter.client.v1.BoardViewTarget
import com.dbpprt.dieter.client.v1.Cards
import com.dbpprt.dieter.client.v1.ChangedFileLabel
import com.dbpprt.dieter.client.v1.ChatsSlice
import com.dbpprt.dieter.client.v1.ContentLinkResolution
import com.dbpprt.dieter.client.v1.DetectedLinks
import com.dbpprt.dieter.client.v1.GitOperationForm
import com.dbpprt.dieter.client.v1.GitOperationFormSpec
import com.dbpprt.dieter.client.v1.LabelPalette
import com.dbpprt.dieter.client.v1.MachineOperationCopy
import com.dbpprt.dieter.client.v1.NavigationSlice
import com.dbpprt.dieter.client.v1.ProjectNavigation
import com.dbpprt.dieter.client.v1.Projects
import com.dbpprt.dieter.client.v1.QuotaGroupList
import com.dbpprt.dieter.client.v1.QuotaGroupRows
import com.dbpprt.dieter.client.v1.ScheduleCadence
import com.dbpprt.dieter.client.v1.ScheduleEditorOptions
import com.dbpprt.dieter.client.v1.SubagentSummary
import com.dbpprt.dieter.client.v1.SyntaxHighlights
import com.dbpprt.dieter.client.v1.TaskPlanSummary
import com.dbpprt.dieter.client.v1.TimelineMessages
import com.dbpprt.dieter.client.v1.TimelineRows
import com.dbpprt.dieter.client.v1.WorkspaceBadgeView
import com.dbpprt.dieter.core.client.rules.ActivityExports
import com.dbpprt.dieter.core.client.rules.BoardExports
import com.dbpprt.dieter.core.client.rules.ConversationExports
import com.dbpprt.dieter.core.client.rules.CreationExports
import com.dbpprt.dieter.core.client.rules.FileExports
import com.dbpprt.dieter.core.client.rules.FormatExports
import com.dbpprt.dieter.core.client.rules.LabelExports
import com.dbpprt.dieter.core.client.rules.LinkExports
import com.dbpprt.dieter.core.client.rules.MachineExports
import com.dbpprt.dieter.core.client.rules.NavigationExports
import com.dbpprt.dieter.core.client.rules.QuotaExports
import com.dbpprt.dieter.core.client.rules.ScheduleExports
import com.dbpprt.dieter.core.client.rules.WorkspaceExports
import platform.Foundation.NSData

/**
 * Pure presentation rules that views call while rendering, synchronously and
 * on any thread: primitive inputs, primitive or encoded `dieter.client.v1`
 * outputs. Each forwards to a stateless `*Exports` object of the shared core,
 * whose tests cover it; nothing here touches the core's dispatcher or state.
 */
object SharedRules {
    // --- Formatting ---------------------------------------------------------------

    fun bytes(count: Long): String = FormatExports.bytes(count)

    fun compactAge(sinceMillis: Long, nowMillis: Long): String = FormatExports.compactAge(sinceMillis, nowMillis)

    fun compactAge(sinceMillis: Long, nowMillis: Long, weeks: Boolean): String = FormatExports.compactAge(sinceMillis, nowMillis, weeks)

    fun ago(atMillis: Long, nowMillis: Long): String = FormatExports.ago(atMillis, nowMillis)

    fun agoSince(value: String, nowMillis: Long): String = FormatExports.agoSince(value, nowMillis)

    fun activityAge(atMillis: Long, nowMillis: Long, suffix: Boolean): String = FormatExports.activityAge(atMillis, nowMillis, suffix)

    fun cardAge(updatedAt: String, lastActivityAt: String, nowMillis: Long): String = FormatExports.cardAge(updatedAt, lastActivityAt, nowMillis)

    fun refreshed(atMillis: Long, syncing: Boolean, nowMillis: Long, dateTime: String): String = FormatExports.refreshed(atMillis, syncing, nowMillis, dateTime)

    fun epochMillis(value: String): Long = FormatExports.epochMillis(value)

    fun compactTokens(value: Long): String = FormatExports.compactTokens(value)

    fun tokenUsageLabel(totalTokens: Long, reportedMessages: Long, partial: Boolean): String = FormatExports.tokenUsageLabel(totalTokens, reportedMessages, partial)

    fun compactPath(path: String): String = FormatExports.compactPath(path)

    fun attachmentLimitError(names: List<String>, sizes: List<Long>): String = FormatExports.attachmentLimitError(names, sizes)

    fun attachmentMediaType(declared: String, filename: String): String = FormatExports.attachmentMediaType(declared, filename)

    fun attachmentDetails(filename: String, mediaType: String, bytes: Long): String = FormatExports.attachmentDetails(filename, mediaType, bytes)

    fun attachmentLimits(): String = FormatExports.attachmentLimits()

    // --- Labels -------------------------------------------------------------------

    /** An encoded `LabelPalette`. */
    fun labelPalette(): NSData = LabelPalette.ADAPTER.encode(LabelExports.palette()).toNSData()

    fun randomLabelColor(exclude: String): String = LabelExports.randomColor(exclude)

    fun labelProblem(name: String, color: String): String = LabelExports.problem(name, color)

    // --- Quotas -------------------------------------------------------------------

    fun quotaResetText(resetsAt: String, nowMillis: Long, fine: Boolean): String = QuotaExports.resetText(resetsAt, nowMillis, fine)

    fun quotaWarning(unavailable: String, freshUntilMillis: Long, nowMillis: Long): String = QuotaExports.warning(unavailable, freshUntilMillis, nowMillis)

    /** [groups] is an encoded `QuotaGroupList`; returns an encoded `QuotaGroupRows`. */
    fun quotaRows(groups: NSData): NSData = QuotaGroupRows.ADAPTER.encode(QuotaExports.rows(QuotaGroupList.ADAPTER.decode(groups.toByteArray()))).toNSData()

    // --- Files --------------------------------------------------------------------

    /** An encoded `SyntaxHighlights`: (start, length, `SyntaxKind`) triples, UTF-16, starts shifted by [offset]. */
    fun syntaxHighlights(text: String, path: String, offset: Int): NSData = SyntaxHighlights.ADAPTER.encode(FileExports.syntaxHighlights(text, path, offset)).toNSData()

    /** `start shl 32 or length` in UTF-16 units. */
    fun fileLineRange(text: String, line: Int): Long = FileExports.lineRange(text, line)

    fun fileLineCount(text: String): Int = FileExports.lineCount(text)

    /** A `FileRenderer` value. */
    fun fileRenderer(path: String, mimeType: String, binary: Boolean): Int = FileExports.renderer(path, mimeType, binary).value

    /** A `FileIconKind` value. */
    fun fileIconKind(name: String, directory: Boolean): Int = FileExports.iconKind(name, directory).value

    // --- Links --------------------------------------------------------------------

    /** An encoded `ContentLinkResolution`; empty [workspaceRoot] or [relativeTo] means none. */
    fun resolveContentLink(url: String, workspaceRoot: String, relativeTo: String): NSData =
        ContentLinkResolution.ADAPTER.encode(LinkExports.resolveContentLink(url, workspaceRoot, relativeTo)).toNSData()

    /** An encoded `DetectedLinks` with UTF-16 ranges. */
    fun detectLinks(text: String): NSData = DetectedLinks.ADAPTER.encode(LinkExports.detectLinks(text)).toNSData()

    fun externalBrowserRuleMatches(url: String, rules: List<String>): Boolean = LinkExports.externalBrowserRuleMatches(url, rules)

    /** The rule to store; "" when the input is invalid. */
    fun normalizeExternalBrowserRule(input: String): String = LinkExports.normalizeExternalBrowserRule(input)

    fun isLoopbackBrowserHost(host: String): Boolean = LinkExports.isLoopbackBrowserHost(host)

    // --- Schedules ----------------------------------------------------------------

    /** An encoded `ScheduleCadence` for a schedule's cron. */
    fun scheduleCadence(cron: String): NSData = ScheduleCadence.ADAPTER.encode(ScheduleExports.cadence(cron)).toNSData()

    /** An encoded `ScheduleCadence`; [kind] is a `ScheduleCadence.Kind` value, [weekday] a cron day (0 = Sunday). */
    fun scheduleCadenceOf(kind: Int, hour: Int, minute: Int, weekday: Int, custom: String): NSData =
        ScheduleCadence.ADAPTER.encode(ScheduleExports.cadenceOf(kind, hour, minute, weekday, custom)).toNSData()

    /** An encoded `ScheduleCadence` switched to the `ScheduleCadence.Kind` value [toKind]. */
    fun scheduleCadenceSwitched(kind: Int, hour: Int, minute: Int, weekday: Int, custom: String, toKind: Int): NSData =
        ScheduleCadence.ADAPTER.encode(ScheduleExports.cadenceSwitched(kind, hour, minute, weekday, custom, toKind)).toNSData()

    fun scheduleTiming(cron: String, timezone: String): String = ScheduleExports.timing(cron, timezone)

    fun scheduleTimezones(selected: String, device: String, all: List<String>): List<String> = ScheduleExports.timezones(selected, device, all)

    /** An encoded `ScheduleEditorOptions`. */
    fun scheduleEditorOptions(): NSData = ScheduleEditorOptions.ADAPTER.encode(ScheduleExports.editorOptions()).toNSData()

    fun scheduleInsertVariable(field: String, variable: String): String = ScheduleExports.insertVariable(field, variable)

    fun scheduleTemplateExample(template: String, empty: String, date: String, scheduledAt: String, project: String, board: String, schedule: String): String =
        ScheduleExports.templateExample(template, empty, date, scheduledAt, project, board, schedule)

    fun scheduleCanSave(name: String, titleTemplate: String, promptTemplate: String, cron: String, timezone: String, boardId: String, workspaceMode: String): Boolean =
        ScheduleExports.canSave(name, titleTemplate, promptTemplate, cron, timezone, boardId, workspaceMode)

    // --- Machines -----------------------------------------------------------------

    fun machineLastSeen(lastSeenAt: String, nowMillis: Long): String = MachineExports.lastSeen(lastSeenAt, nowMillis)

    fun lastConnected(atMillis: Long, nowMillis: Long): String = MachineExports.lastConnected(atMillis, nowMillis)

    fun workspaceUpdated(atMillis: Long, nowMillis: Long): String = MachineExports.updated(atMillis, nowMillis)

    fun machinePercentage(value: Double): String = MachineExports.percentage(value)

    fun machineLoad(cores: Int, load1: Double, load5: Double, load15: Double): String = MachineExports.load(cores, load1, load5, load15)

    fun machineSubtitle(hardwareModel: String, processor: String, osName: String, osVersion: String, uptimeSeconds: Long): String =
        MachineExports.subtitle(hardwareModel, processor, osName, osVersion, uptimeSeconds)

    fun machineCount(count: Int, noun: String, plural: String): String = MachineExports.count(count, noun, plural)

    fun machineActiveAgents(agents: Int): String = MachineExports.activeAgents(agents)

    /** A negative [usedBytes] or [totalBytes] is unknown. */
    fun gpuMemory(unified: Boolean, usedBytes: Long, totalBytes: Long): String = MachineExports.gpuMemory(unified, usedBytes, totalBytes)

    /** [vendor] is a `GPUVendor` value; "" when unknown. */
    fun gpuVendor(vendor: Int): String = MachineExports.gpuVendor(vendor)

    fun machineTemperature(celsius: Double): String = MachineExports.temperature(celsius)

    fun machinePower(watts: Double): String = MachineExports.power(watts)

    fun machineDisk(freeBytes: Long): String = MachineExports.disk(freeBytes)

    fun machineNetwork(receiveBytesPerSecond: Double, sendBytesPerSecond: Double): String = MachineExports.network(receiveBytesPerSecond, sendBytesPerSecond)

    fun machineProcessDetail(pid: Int, detail: String): String = MachineExports.processDetail(pid, detail)

    fun softwareVersion(version: String, revision: String): String = MachineExports.version(version, revision)

    fun daemonVersion(buildVersion: String, releaseVersion: String, revision: String): String = MachineExports.daemonVersion(buildVersion, releaseVersion, revision)

    /** An encoded `MachineOperationCopy`; [action] is a `MachineOperationAction` value. */
    fun machineOperationCopy(action: Int): NSData = MachineOperationCopy.ADAPTER.encode(MachineExports.operationCopy(action)).toNSData()

    // --- Conversation -------------------------------------------------------------

    /** The first step group a long message shows; empty [fromId] means none was pinned yet. */
    fun timelineVisibleStart(groupIds: List<String>, fromId: String): Int = ConversationExports.visibleStart(groupIds, fromId)

    fun timelineInitialGroups(): Int = ConversationExports.initialGroups()

    /** [messages] is an encoded `TimelineMessages`; returns an encoded `TimelineRows`. */
    fun timelineRows(messages: NSData, queuedIds: List<String>, showReasoning: Boolean): NSData =
        TimelineRows.ADAPTER.encode(ConversationExports.timelineRows(TimelineMessages.ADAPTER.decode(messages.toByteArray()), queuedIds, showReasoning)).toNSData()

    /** [messages] is an encoded `TimelineMessages`. */
    fun copyText(messages: NSData): String = ConversationExports.copyText(TimelineMessages.ADAPTER.decode(messages.toByteArray()))

    /** [plan] is an encoded `dieter.v1.TaskPlan`; returns an encoded `TaskPlanSummary`. */
    fun taskPlanSummary(plan: NSData): NSData = TaskPlanSummary.ADAPTER.encode(ConversationExports.taskPlan(TaskPlan.ADAPTER.decode(plan.toByteArray()))).toNSData()

    /** [agent] is an encoded `dieter.v1.Subagent`; returns an encoded `SubagentSummary`. */
    fun subagentSummary(agent: NSData, nowMillis: Long): NSData =
        SubagentSummary.ADAPTER.encode(ConversationExports.subagent(Subagent.ADAPTER.decode(agent.toByteArray()), nowMillis)).toNSData()

    // --- Workspace ----------------------------------------------------------------

    /** An encoded `WorkspaceBadgeView`; [pullRequest] is the pull request number, 0 for none. */
    fun workspaceBadge(
        mode: String, state: String, branch: String, changedFiles: Int, ahead: Int, behind: Int,
        cardMode: String, cardBranch: String, pullRequest: Int,
    ): NSData = WorkspaceBadgeView.ADAPTER.encode(WorkspaceExports.workspaceBadge(mode, state, branch, changedFiles, ahead, behind, cardMode, cardBranch, pullRequest)).toNSData()

    /** An encoded `ChangedFileLabel`. */
    fun changedFile(path: String, status: String, conflicted: Boolean, untracked: Boolean): NSData =
        ChangedFileLabel.ADAPTER.encode(WorkspaceExports.changedFile(path, status, conflicted, untracked)).toNSData()

    /** An encoded `GitOperationFormSpec`. */
    fun gitOperationForm(kind: String, cardTitle: String, cardPrompt: String, pullRequestHeadSha: String, baseBranch: String): NSData =
        GitOperationFormSpec.ADAPTER.encode(WorkspaceExports.gitOperationForm(kind, cardTitle, cardPrompt, pullRequestHeadSha, baseBranch)).toNSData()

    /** [form] is an encoded `GitOperationForm`. */
    fun gitOperationReady(form: NSData): Boolean = WorkspaceExports.gitOperationReady(GitOperationForm.ADAPTER.decode(form.toByteArray()))

    // --- Board --------------------------------------------------------------------

    fun isChat(scope: String, boardId: String): Boolean = BoardExports.isChat(scope, boardId)

    /** A `RuntimeTone` value. */
    fun runtimeTone(runtime: String): Int = BoardExports.runtimeTone(runtime).value

    fun runtimeLabel(runtime: String): String = BoardExports.runtimeLabel(runtime)

    fun runtimeActive(runtime: String): Boolean = BoardExports.runtimeActive(runtime)

    /** A `BoardLaneKind` value. */
    fun laneKind(laneId: String, laneName: String): Int = BoardExports.laneKind(laneId, laneName).value

    /** [card] is an encoded `dieter.v1.Card`, [board] an encoded `dieter.v1.Board` (empty when unknown); returns an encoded `BoardCardFlags`. */
    fun cardFlags(card: NSData, board: NSData, operation: String, pending: Boolean, failed: Boolean): NSData =
        BoardCardFlags.ADAPTER.encode(BoardExports.cardFlags(Card.ADAPTER.decode(card.toByteArray()), Board.ADAPTER.decode(board.toByteArray()), operation, pending, failed)).toNSData()

    /** [card] is an encoded `dieter.v1.Card`, [selection] the encoded `dieter.v1.HarnessSelection` the form shows; "" when the form can save. */
    fun cardDraftProblem(card: NSData, title: String, task: String, selection: NSData): String =
        BoardExports.cardDraftProblem(Card.ADAPTER.decode(card.toByteArray()), title, task, HarnessSelection.ADAPTER.decode(selection.toByteArray()))

    /** [board] is an encoded `dieter.v1.Board`, [cards] encoded `Cards`, [target] an encoded `BoardViewTarget`; returns an encoded `BoardViewSlice`. */
    fun boardView(board: NSData, cards: NSData, target: NSData): NSData = BoardViewSlice.ADAPTER.encode(
        BoardExports.boardView(Board.ADAPTER.decode(board.toByteArray()), Cards.ADAPTER.decode(cards.toByteArray()), BoardViewTarget.ADAPTER.decode(target.toByteArray())),
    ).toNSData()

    // --- Activity -----------------------------------------------------------------

    fun activityMatches(query: String, title: String, projectName: String, boardName: String): Boolean = ActivityExports.activityMatches(query, title, projectName, boardName)

    /** An encoded `ActivityTimelineBar`. */
    fun timelineBar(startMillis: Long, atMillis: Long, running: Boolean, nowMillis: Long, hours: Int): NSData =
        ActivityTimelineBar.ADAPTER.encode(ActivityExports.timelineBar(startMillis, atMillis, running, nowMillis, hours)).toNSData()

    // --- Navigation ---------------------------------------------------------------

    /** "" when [name] can name a folder beside [existingNames] (the scope's other folders). */
    fun folderNameProblem(name: String, existingNames: List<String>): String = NavigationExports.folderNameProblem(name, existingNames)

    /** [navigation] is an encoded `NavigationSlice`, [projects] encoded `Projects`; returns an encoded `ProjectNavigation`. */
    fun sidebarProjects(navigation: NSData, projects: NSData): NSData = ProjectNavigation.ADAPTER.encode(
        NavigationExports.sidebarProjects(NavigationSlice.ADAPTER.decode(navigation.toByteArray()), Projects.ADAPTER.decode(projects.toByteArray())),
    ).toNSData()

    /** [chats] is encoded `Cards`, [projects] encoded `Projects`, [navigation] an encoded `NavigationSlice`; returns an encoded `ChatsSlice`. */
    fun chatList(chats: NSData, projects: NSData, navigation: NSData, query: String, archived: Boolean): NSData = ChatsSlice.ADAPTER.encode(
        NavigationExports.chatList(
            Cards.ADAPTER.decode(chats.toByteArray()), Projects.ADAPTER.decode(projects.toByteArray()), NavigationSlice.ADAPTER.decode(navigation.toByteArray()),
            query, archived,
        ),
    ).toNSData()

    // --- Creation -----------------------------------------------------------------

    fun workspaceModeTitle(mode: String): String = CreationExports.workspaceModeTitle(mode)

    fun workspaceModeShortTitle(mode: String): String = CreationExports.workspaceModeShortTitle(mode)

    fun workspaceModeDetail(mode: String): String = CreationExports.workspaceModeDetail(mode)

    fun opensAfterCreate(chat: Boolean, lane: String): Boolean = CreationExports.opensAfterCreate(chat, lane)

    /**
     * [selection] is an encoded `dieter.v1.HarnessSelection`, [catalog] an
     * encoded `dieter.v1.HarnessCatalog`, [choice] an encoded `AgentChoice`
     * (empty for none); returns an encoded `AgentControlsState`.
     */
    fun agentControls(selection: NSData, catalog: NSData, locked: Boolean, choice: NSData): NSData = AgentControlsState.ADAPTER.encode(
        CreationExports.agentControls(
            HarnessSelection.ADAPTER.decode(selection.toByteArray()), HarnessCatalog.ADAPTER.decode(catalog.toByteArray()), locked,
            AgentChoice.ADAPTER.decode(choice.toByteArray()),
        ),
    ).toNSData()
}
