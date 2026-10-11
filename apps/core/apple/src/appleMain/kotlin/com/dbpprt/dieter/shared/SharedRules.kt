package com.dbpprt.dieter.shared

import com.dbpprt.dieter.api.v1.Board
import com.dbpprt.dieter.api.v1.Card
import com.dbpprt.dieter.api.v1.HarnessCatalog
import com.dbpprt.dieter.api.v1.HarnessSelection
import com.dbpprt.dieter.api.v1.MessagePart
import com.dbpprt.dieter.api.v1.Project
import com.dbpprt.dieter.api.v1.QueuedMessage
import com.dbpprt.dieter.api.v1.RemoteDesktopSessionBinding
import com.dbpprt.dieter.api.v1.StartRemoteDesktopRequest
import com.dbpprt.dieter.api.v1.Subagent
import com.dbpprt.dieter.api.v1.TaskPlan
import com.dbpprt.dieter.api.v1.ValidationCommand
import com.dbpprt.dieter.client.v1.ActivityTimelineBar
import com.dbpprt.dieter.client.v1.AdminOptions
import com.dbpprt.dieter.client.v1.AgentChoice
import com.dbpprt.dieter.client.v1.AgentControlsState
import com.dbpprt.dieter.client.v1.BoardCardFlags
import com.dbpprt.dieter.client.v1.BoardViewSlice
import com.dbpprt.dieter.client.v1.BoardViewTarget
import com.dbpprt.dieter.client.v1.Cards
import com.dbpprt.dieter.client.v1.ChangedFileLabel
import com.dbpprt.dieter.client.v1.ChatDestination
import com.dbpprt.dieter.client.v1.ChatDestinationGroups
import com.dbpprt.dieter.client.v1.ChatDestinationInput
import com.dbpprt.dieter.client.v1.ChatsSlice
import com.dbpprt.dieter.client.v1.Checkouts
import com.dbpprt.dieter.client.v1.ContentLinkResolution
import com.dbpprt.dieter.client.v1.DetectedLinks
import com.dbpprt.dieter.client.v1.GitOperationForm
import com.dbpprt.dieter.client.v1.GitOperationFormSpec
import com.dbpprt.dieter.client.v1.HostnameSets
import com.dbpprt.dieter.client.v1.LabelPalette
import com.dbpprt.dieter.client.v1.MachineOperationCopy
import com.dbpprt.dieter.client.v1.NavigationSlice
import com.dbpprt.dieter.client.v1.ProjectNavigation
import com.dbpprt.dieter.client.v1.Projects
import com.dbpprt.dieter.client.v1.QuotaGroupList
import com.dbpprt.dieter.client.v1.QuotaGroupRows
import com.dbpprt.dieter.client.v1.ScheduleCadence
import com.dbpprt.dieter.client.v1.ScheduleEditorOptions
import com.dbpprt.dieter.client.v1.ScreenStreamOptions
import com.dbpprt.dieter.client.v1.ScreenToolbarKeys
import com.dbpprt.dieter.client.v1.SubagentSummary
import com.dbpprt.dieter.client.v1.SyntaxHighlights
import com.dbpprt.dieter.client.v1.TaskPlanSummary
import com.dbpprt.dieter.client.v1.TimelineMessages
import com.dbpprt.dieter.client.v1.TimelineRows
import com.dbpprt.dieter.client.v1.ValidationDraft
import com.dbpprt.dieter.client.v1.ValidationDrafts
import com.dbpprt.dieter.client.v1.WorkspaceBadgeView
import com.dbpprt.dieter.core.client.rules.ActivityExports
import com.dbpprt.dieter.core.client.rules.AdminExports
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
import com.dbpprt.dieter.core.client.rules.ScreenExports
import com.dbpprt.dieter.core.client.rules.TerminalExports
import com.dbpprt.dieter.core.client.rules.WorkspaceExports
import com.dbpprt.dieter.core.platform.SignatureVerifier
import com.dbpprt.dieter.core.screens.ScreenTrust
import com.dbpprt.dieter.core.screens.ScreenTrustException
import kotlin.time.Instant
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

    /** "1 board", "3 boards": [noun] when [count] is 1, else [plural], or [noun] plus "s" when [plural] is empty. */
    fun count(count: Int, noun: String, plural: String): String = FormatExports.count(count, noun, plural)

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

    fun attachmentFilename(raw: String, mediaType: String): String = FormatExports.attachmentFilename(raw, mediaType)

    fun attachmentDetails(filename: String, mediaType: String, bytes: Long): String = FormatExports.attachmentDetails(filename, mediaType, bytes)

    fun attachmentLimits(): String = FormatExports.attachmentLimits()

    /** The encoded `dieter.v1.MessagePart` a file the platform has read is sent as; empty [declaredMediaType] guesses from [filename]. */
    fun attachmentPart(filename: String, declaredMediaType: String, bytes: NSData): NSData =
        MessagePart.ADAPTER.encode(FormatExports.attachmentPart(filename, declaredMediaType, bytes.toByteArray())).toNSData()

    /** How many more files may join [count] attached ones. */
    fun attachmentSlots(count: Int): Int = FormatExports.attachmentSlots(count)

    // --- Labels -------------------------------------------------------------------

    /** An encoded `LabelPalette`. */
    fun labelPalette(): NSData = LabelPalette.ADAPTER.encode(LabelExports.palette()).toNSData()

    fun randomLabelColor(exclude: String): String = LabelExports.randomColor(exclude)

    fun labelProblem(name: String, color: String): String = LabelExports.problem(name, color)

    // --- Quotas -------------------------------------------------------------------

    fun quotaResetText(resetsAt: String, nowMillis: Long, fine: Boolean): String = QuotaExports.resetText(resetsAt, nowMillis, fine)

    fun quotaWarning(unavailable: String, freshUntilMillis: Long, nowMillis: Long): String = QuotaExports.warning(unavailable, freshUntilMillis, nowMillis)

    fun quotaResetTitle(): String = QuotaExports.resetTitle()

    fun quotaResetMessage(): String = QuotaExports.resetMessage()

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

    fun fileEditable(path: String, mimeType: String, binary: Boolean): Boolean = FileExports.editable(path, mimeType, binary)

    /** A `FileIconKind` value. */
    fun fileIconKind(name: String, directory: Boolean): Int = FileExports.iconKind(name, directory).value

    /** The `dieter-preview:` URL a sandboxed HTML preview loads [documentPath] from. */
    fun htmlPreviewDocumentUrl(documentPath: String): String = FileExports.htmlPreviewDocumentUrl(documentPath)

    /** The workspace file an HTML preview request reads; "" when it must fail. */
    fun htmlPreviewResource(url: String): String = FileExports.htmlPreviewResource(url)

    fun htmlPreviewMimeType(path: String, reported: String): String = FileExports.htmlPreviewMimeType(path, reported)

    /** The Content-Security-Policy every HTML preview response carries: no network, frames, or form posts. */
    fun htmlPreviewContentSecurityPolicy(): String = FileExports.HTML_PREVIEW_CONTENT_SECURITY_POLICY

    /** Requests one HTML preview may serve, the document included. */
    fun htmlPreviewMaxResources(): Int = FileExports.HTML_PREVIEW_MAX_RESOURCES

    // --- Screens ------------------------------------------------------------------

    /** An encoded `ScreenToolbarKeys`: the modifier toggles and special keys a touch screen's toolbar offers. */
    fun screenToolbarKeys(): NSData = ScreenToolbarKeys.ADAPTER.encode(ScreenExports.toolbarKeys()).toNSData()

    /** An encoded `ScreenStreamOptions`: the quality and codec choices, in menu order. */
    fun screenStreamOptions(): NSData = ScreenStreamOptions.ADAPTER.encode(ScreenExports.streamOptions()).toNSData()

    /** A frame-rate choice: "Up to 60 fps". */
    fun screenFrameRate(fps: Int): String = ScreenExports.frameRate(fps)

    /** "Take Control", or "Release Control" while [controlActive]. */
    fun screenControlAction(controlActive: Boolean): String = ScreenExports.controlAction(controlActive)

    fun screenCodecUnavailable(): String = ScreenExports.codecUnavailable()

    /**
     * Why a screen session's daemon-signed [binding] (an encoded
     * `RemoteDesktopSessionBinding`) does not belong to [request] (an encoded
     * `StartRemoteDesktopRequest`), the host's [answerSdp], and the enrolled
     * machine's [certificatePem]; "" when it does. [signatures] checks the
     * Ed25519 signature.
     */
    fun screenBindingProblem(
        binding: NSData, sessionId: String, request: NSData, answerSdp: String, certificatePem: String, nowMillis: Long,
        signatures: NativeSignatures,
    ): String = try {
        ScreenTrust.verify(
            RemoteDesktopSessionBinding.ADAPTER.decode(binding.toByteArray()), sessionId,
            StartRemoteDesktopRequest.ADAPTER.decode(request.toByteArray()), answerSdp, certificatePem,
            Instant.fromEpochMilliseconds(nowMillis),
            object : SignatureVerifier {
                override fun verifyEd25519(publicKey: ByteArray, message: ByteArray, signature: ByteArray) =
                    signatures.verifyEd25519(publicKey.toNSData(), message.toNSData(), signature.toNSData())
            },
        )
        ""
    } catch (failure: ScreenTrustException) {
        failure.message.orEmpty()
    }

    /**
     * What a screen view says while not streaming; [phase] and [problem] are
     * the screen slice's, [hostReady] and [hostReason] the machine's
     * `remote_desktop_ready` and `remote_desktop_reason`.
     */
    fun screenWaitingMessage(phase: String, problem: String, hostReady: Boolean, hostReason: String): String =
        ScreenExports.waitingMessage(phase, problem, hostReady, hostReason)

    // --- Terminals ----------------------------------------------------------------

    /** The bytes [key] (a `TerminalKey` value) sends; empty when unknown. [applicationCursor] is the terminal's cursor key mode. */
    fun terminalKey(key: Int, shift: Boolean, alt: Boolean, control: Boolean, applicationCursor: Boolean): NSData =
        TerminalExports.key(key, shift, alt, control, applicationCursor).toNSData()

    /** A `TerminalKey` value for F[number]; 0 outside F1 to F12. */
    fun terminalFunctionKey(number: Int): Int = TerminalExports.functionKey(number)

    /** What an armed Control turns one typed key into; nil when Control does not apply. */
    fun terminalControl(bytes: NSData): NSData? = TerminalExports.control(bytes.toByteArray())?.toNSData()

    /** "Connected", "Reconnecting", "Exited 1", or "Exited"; [status] is the terminal's, e.g. "running". */
    fun terminalStatus(status: String, exitCode: Int, hasExitCode: Boolean, streamConnected: Boolean): String =
        TerminalExports.status(status, exitCode, hasExitCode, streamConnected)

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

    /** Why [url] always opens in the system browser, e.g. Claude Design; "" when the embedded browser may show it. */
    fun systemBrowserNotice(url: String): String = LinkExports.systemBrowserNotice(url)

    /** Whether [url] is a Claude artifact or design, shown in the claude.ai browser session. */
    fun isClaudeDesign(url: String): Boolean = LinkExports.isClaudeDesign(url)

    /** Whether [url] is a claude.ai page the claude.ai browser session may navigate to. */
    fun isClaudeAccountPage(url: String): Boolean = LinkExports.isClaudeAccountPage(url)

    /** Whether an image link may name a workspace file; the files surface's `open` resolves it. */
    fun isWorkspaceImage(destination: String): Boolean = LinkExports.isWorkspaceImage(destination)


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

    /** A gateway address's origin as `UseGateway` accepts it; empty when invalid or remote plaintext. */
    fun gatewayOrigin(address: String): String = MachineExports.gatewayOrigin(address)

    fun defaultGatewayName(): String = MachineExports.defaultGatewayName()

    fun defaultGatewayOrigin(): String = MachineExports.defaultGatewayOrigin()

    fun machineLastSeen(lastSeenAt: String, nowMillis: Long): String = MachineExports.lastSeen(lastSeenAt, nowMillis)

    fun lastConnected(atMillis: Long, nowMillis: Long): String = MachineExports.lastConnected(atMillis, nowMillis)

    fun workspaceUpdated(atMillis: Long, nowMillis: Long): String = MachineExports.updated(atMillis, nowMillis)

    fun machinePercentage(value: Double): String = MachineExports.percentage(value)

    fun machineLoad(cores: Int, load1: Double, load5: Double, load15: Double): String = MachineExports.load(cores, load1, load5, load15)

    fun machineSubtitle(hardwareModel: String, processor: String, osName: String, osVersion: String, uptimeSeconds: Long): String =
        MachineExports.subtitle(hardwareModel, processor, osName, osVersion, uptimeSeconds)

    fun machinePresence(online: Boolean): String = MachineExports.presence(online)

    /** Why a machine the account no longer lists cannot be used. */
    fun unenrolledMachineMessage(): String = MachineExports.unenrolledMessage()

    fun machineMemory(totalBytes: Long, cachedBytes: Long, swapBytes: Long): String = MachineExports.memory(totalBytes, cachedBytes, swapBytes)

    fun operatingSystem(osName: String, osVersion: String): String = MachineExports.operatingSystem(osName, osVersion)

    fun gpuName(name: String): String = MachineExports.gpuName(name)

    /** [vendor] is a `GPUVendor` value. */
    fun gpuDetail(vendor: Int, id: String, driverVersion: String): String = MachineExports.gpuDetail(vendor, id, driverVersion)

    fun gpuUtilization(percent: Double, reported: Boolean): String = MachineExports.gpuUtilization(percent, reported)

    fun gpuUnavailable(reason: String): String = MachineExports.gpuUnavailable(reason)

    /** Why a machine's information is missing; [error] is the read's, empty for none. */
    fun machineInformationUnavailable(online: Boolean, detail: String, error: String): String = MachineExports.informationUnavailable(online, detail, error)

    fun isAgentProcess(kind: String): Boolean = MachineExports.isAgentProcess(kind)

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

    /** False for the local ID of a conversation whose creation is still in the outbox. */
    fun isServerBacked(conversationId: String): Boolean = ConversationExports.isServerBacked(conversationId)

    /** The first step group a long message shows; empty [fromId] means none was pinned yet. */
    fun timelineVisibleStart(groupIds: List<String>, fromId: String): Int = ConversationExports.visibleStart(groupIds, fromId)

    fun timelineInitialGroups(): Int = ConversationExports.initialGroups()

    /** [messages] is an encoded `TimelineMessages`; returns an encoded `TimelineRows`. */
    fun timelineRows(messages: NSData, queuedIds: List<String>, showReasoning: Boolean): NSData =
        TimelineRows.ADAPTER.encode(ConversationExports.timelineRows(TimelineMessages.ADAPTER.decode(messages.toByteArray()), queuedIds, showReasoning)).toNSData()

    /** [messages] is an encoded `TimelineMessages`. */
    fun copyText(messages: NSData): String = ConversationExports.copyText(TimelineMessages.ADAPTER.decode(messages.toByteArray()))

    /** [message] is the encoded `dieter.v1.QueuedMessage` an edit removed; returns the composer's restored text and attachments as one. */
    fun restoredDraft(message: NSData, currentText: String): NSData =
        QueuedMessage.ADAPTER.encode(ConversationExports.restoredDraft(QueuedMessage.ADAPTER.decode(message.toByteArray()), currentText)).toNSData()

    /** [message] is an encoded `dieter.v1.QueuedMessage`; its text, else "2 attachments". */
    fun queuedSummary(message: NSData): String = ConversationExports.queuedSummary(QueuedMessage.ADAPTER.decode(message.toByteArray()))

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

    /** [form] is an encoded `GitOperationForm`, [input] a `GitOperationFormSpec.Input` value. */
    fun gitOperationShows(form: NSData, input: Int): Boolean = WorkspaceExports.gitOperationShows(
        GitOperationForm.ADAPTER.decode(form.toByteArray()), GitOperationFormSpec.Input.fromValue(input) ?: GitOperationFormSpec.Input.INPUT_SUBJECT,
    )

    /** [form] is an encoded `GitOperationForm`. */
    fun gitOperationReady(form: NSData): Boolean = WorkspaceExports.gitOperationReady(GitOperationForm.ADAPTER.decode(form.toByteArray()))

    fun shortSha(shortSha: String, sha: String): String = WorkspaceExports.shortSha(shortSha, sha)

    // --- Board --------------------------------------------------------------------

    fun isChat(scope: String, boardId: String): Boolean = BoardExports.isChat(scope, boardId)

    /** [card] is an encoded `dieter.v1.Card`; its machine produced a reply the user has not seen. */
    fun isUnread(card: NSData): Boolean = BoardExports.isUnread(Card.ADAPTER.decode(card.toByteArray()))

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

    /** A conversation's title, or "Untitled chat" / "Untitled card" when blank. */
    fun conversationTitle(title: String, scope: String, boardId: String): String = ActivityExports.conversationTitle(title, scope, boardId)

    fun timelineHours(): List<Int> = ActivityExports.timelineHours()

    fun timelineRangeTitle(hours: Int): String = ActivityExports.timelineRangeTitle(hours)

    fun timelineEmpty(hours: Int): String = ActivityExports.timelineEmpty(hours)

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

    // --- Administration -----------------------------------------------------------

    /** An encoded `AdminOptions`: workflows, publish modes, and archive policies with each form's defaults. */
    fun adminOptions(): NSData = AdminOptions.ADAPTER.encode(AdminExports.options()).toNSData()

    /** [command] is an encoded `dieter.v1.ValidationCommand`; returns the encoded `ValidationDraft` its form edits. */
    fun validationDraft(command: NSData): NSData =
        ValidationDraft.ADAPTER.encode(AdminExports.validationDraft(ValidationCommand.ADAPTER.decode(command.toByteArray()))).toNSData()

    /** [draft] is an encoded `ValidationDraft`; returns the encoded `dieter.v1.ValidationCommand` it saves as. */
    fun validationCommand(draft: NSData): NSData =
        ValidationCommand.ADAPTER.encode(AdminExports.validationCommand(ValidationDraft.ADAPTER.decode(draft.toByteArray()))).toNSData()

    /** [drafts] is an encoded `ValidationDrafts`; "" when they can save. */
    fun validationProblem(drafts: NSData): String = AdminExports.validationProblem(ValidationDrafts.ADAPTER.decode(drafts.toByteArray()).drafts)

    /** [drafts] is an encoded `ValidationDrafts`. */
    fun canCreateProject(path: String, baseBranch: String, drafts: NSData): Boolean =
        AdminExports.canCreateProject(path, baseBranch, ValidationDrafts.ADAPTER.decode(drafts.toByteArray()).drafts)

    /** [drafts] is an encoded `ValidationDrafts`. */
    fun canSaveProject(name: String, baseBranch: String, drafts: NSData): Boolean =
        AdminExports.canSaveProject(name, baseBranch, ValidationDrafts.ADAPTER.decode(drafts.toByteArray()).drafts)

    // --- Creation -----------------------------------------------------------------

    /** [input] is an encoded `ChatDestinationInput`; returns encoded `ChatDestinationGroups`. */
    fun chatDestinations(input: NSData): NSData =
        ChatDestinationGroups.ADAPTER.encode(CreationExports.chatDestinations(ChatDestinationInput.ADAPTER.decode(input.toByteArray()))).toNSData()

    /** [groups] is encoded `ChatDestinationGroups`; returns the encoded `ChatDestination` to show first, empty when none. */
    fun preferredChatDestination(groups: NSData, machineId: String, projectId: String, checkoutId: String): NSData = ChatDestination.ADAPTER.encode(
        CreationExports.preferredChatDestination(ChatDestinationGroups.ADAPTER.decode(groups.toByteArray()), machineId, projectId, checkoutId),
    ).toNSData()

    /** [value] trimmed when it is an http(s) page a capture may record, else "". */
    fun capturePage(value: String): String = CreationExports.capturePage(value)

    /** The page's "host" or "host:port" as hostnames store it, else "". */
    fun captureHostname(value: String): String = CreationExports.captureHostname(value)

    /** [candidates] is an encoded `HostnameSets`; the indices of those that route the page at [url]. */
    fun captureMatches(url: String, candidates: NSData): List<Int> =
        CreationExports.captureMatches(url, HostnameSets.ADAPTER.decode(candidates.toByteArray()))

    /** [project] is an encoded `dieter.v1.Project`; returns the encoded `Checkouts` a destination picker offers. */
    fun checkoutChoices(project: NSData): NSData =
        Checkouts.ADAPTER.encode(CreationExports.checkoutChoices(Project.ADAPTER.decode(project.toByteArray()))).toNSData()

    /** A checkout as destination pickers name it: its name, else "Project checkout", ending " · Offline" while its machine is offline. */
    fun checkoutTitle(name: String, machineOnline: Boolean): String = CreationExports.checkoutTitle(name, machineOnline)

    fun workspaceModeTitle(mode: String): String = CreationExports.workspaceModeTitle(mode)

    fun workspaceModeShortTitle(mode: String): String = CreationExports.workspaceModeShortTitle(mode)

    fun workspaceModeDetail(mode: String): String = CreationExports.workspaceModeDetail(mode)

    /** The modes a picker offers, in order: "worktree", then "project". */
    fun workspaceModes(): List<String> = CreationExports.workspaceModes()

    /** "New worktree" or "Project directory", as a picker offers the mode for a new conversation. */
    fun workspaceModeChoiceTitle(mode: String): String = CreationExports.workspaceModeChoiceTitle(mode)

    fun opensAfterCreate(chat: Boolean, lane: String): Boolean = CreationExports.opensAfterCreate(chat, lane)

    /** The value a toggle provider option takes when switched [on] or off. */
    fun toggleOptionValue(on: Boolean): String = CreationExports.toggleOptionValue(on)

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
