import DieterAPI
import SwiftUI
import UniformTypeIdentifiers

enum ComposerReturnPolicy {
    static func sendsMessage(shiftPressed: Bool) -> Bool { !shiftPressed }
}

enum ConversationRefreshText {
    static func label(lastRefreshedAt: Date?, syncing: Bool, now: Date = Date()) -> String {
        guard let lastRefreshedAt else { return syncing ? "Refreshing…" : "Not refreshed yet" }
        let seconds = max(0, now.timeIntervalSince(lastRefreshedAt))
        let freshness: String
        switch seconds {
        case ..<60:
            freshness = "just now"
        case ..<3_600:
            freshness = "\(Int(seconds / 60))m ago"
        case ..<86_400:
            freshness = "\(Int(seconds / 3_600))h ago"
        default:
            freshness = lastRefreshedAt.formatted(date: .abbreviated, time: .shortened)
        }
        return "Last refreshed \(freshness)" + (syncing ? " · Refreshing…" : "")
    }
}

enum ConversationActivityPresentation {
    private static let activeStatuses = Set(["starting", "running", "working", "streaming", "cancelling"])

    static func isActive(conversationStatus: String, cardRuntime: String) -> Bool {
        activeStatuses.contains(conversationStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            || activeStatuses.contains(cardRuntime.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    static func label(hasPendingTool: Bool) -> String {
        hasPendingTool ? "Working…" : "Thinking…"
    }
}

struct ConversationView: View {
    @Environment(DieterStore.self) private var store
    var compact = false
    @State private var tab = "Conversation"
    @State private var fileImporterPresented = false

    private var standalone: Bool {
        (store.selectedCard ?? store.selectedDetail?.card)?.scope == "chat"
    }

    var body: some View {
        VStack(spacing: 0) {
            ConversationChrome(compact: compact, standalone: standalone, tab: $tab)

            Group {
                if store.conversationLoading {
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Loading conversation…").font(.caption).foregroundStyle(DieterTheme.tertiary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if tab == "Subagents" {
                    SubagentsView()
                } else if tab == "Comments" {
                    CommentsView()
                } else if tab == "Changes" {
                    WorkspaceChangesView()
                } else {
                    ConversationTimeline()
                        .id(store.selectedCardID ?? store.selectedChatID ?? "")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if tab == "Conversation" {
                ConversationComposer(fileImporterPresented: $fileImporterPresented)
            }
        }
        .background(DieterTheme.background)
        .overlay(alignment: .bottom) {
            if let toast = store.workspaceToast {
                WorkspaceToastView(toast: toast)
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(toast.id)
            }
        }
        .animation(.spring(duration: 0.3), value: store.workspaceToast)
        .onChange(of: store.selectedCardID) { _, _ in tab = "Conversation" }
        .onChange(of: store.selectedChatID) { _, _ in tab = "Conversation" }
        .onReceive(NotificationCenter.default.publisher(for: WorkspaceUISmokeRunner.selectTabNotification)) { note in
            if let name = note.object as? String { tab = name }
        }
        .fileImporter(isPresented: $fileImporterPresented, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case let .success(urls) = result { store.addAttachments(urls) }
            else if case let .failure(error) = result { store.show(error) }
        }
        // AttachmentPasteMonitor is the single owner of ⌘V. Registering an
        // onPasteCommand here too can append the same clipboard image twice.
        .attachmentPasteCatcher { pasteboard in
            store.attachPasteboard(pasteboard)
        }
    }
}

private struct ConversationChrome: View {
    @Environment(DieterStore.self) private var store
    let compact: Bool
    let standalone: Bool
    @Binding var tab: String
    @State private var editCardPresented = false
    @State private var workspaceSettingsPresented = false

    private var card: Dieter_V1_Card? { store.selectedCard ?? store.selectedDetail?.card }
    private var status: String { store.conversation?.conversation.status ?? card?.runtime ?? "idle" }
    private var subagentCount: Int { store.conversation?.conversation.subagents.count ?? 0 }

    var body: some View {
        FluidPaneChrome(background: DieterTheme.background, spacing: 8) {
            HStack(spacing: 10) {
                if compact {
                    Button { store.closeConversation() } label: { Image(systemName: "xmark") }
                        .buttonStyle(DieterIconButtonStyle()).help("Close conversation")
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(card?.title.isEmpty == false ? card!.title : "Conversation")
                        .font(DieterFont.paneTitle).lineLimit(1)
                    HStack(spacing: 4) {
                        if let detail = store.selectedDetail {
                            Text(detail.project.name).lineLimit(1)
                            Text(standalone ? "· Standalone chat" : "/ \(detail.board.name)").lineLimit(1)
                        }
                        if let id = card?.id, !id.isEmpty { Text("· \(id.prefix(8))").font(.system(size: 10).monospaced()).lineLimit(1) }
                        if card != nil {
                            Text("·")
                            Text(ConversationRefreshText.label(
                                lastRefreshedAt: store.conversationLastRefreshedAt,
                                syncing: store.conversationSyncing,
                                now: .now
                            ))
                            .lineLimit(1)
                            .accessibilityIdentifier("conversation-last-refreshed")
                            if store.conversationSyncing {
                                ProgressView().controlSize(.mini)
                                    .accessibilityLabel("Refreshing conversation")
                            }
                        }
                    }
                    .font(DieterFont.subtitle).foregroundStyle(DieterTheme.tertiary)
                }
                Spacer(minLength: 10)
                if let card, !card.workspaceMode.isEmpty {
                    Button { tab = "Changes" } label: { WorkspaceSummaryBadge(card: card) }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Open workspace changes")
                }
                StatusPill(text: status, color: runtimeColor(status))
                if let card {
                    Menu {
                        if store.isFailedOutboxItem(card.id) {
                            Button("Retry queued creation") { Task { await store.retryOutboxItem(card.id) } }
                            Button("Discard queued creation", role: .destructive) { Task { await store.discardOutboxItem(card.id) } }
                            Divider()
                        }
                        if standalone { Button(card.pinned ? "Unpin chat" : "Pin chat") { Task { await store.pin(card, pinned: !card.pinned) } } }
                        Button("Fork as new chat", systemImage: "arrow.triangle.branch") { Task { await store.fork(card) } }
                        if !standalone, BoardCardEditingPolicy.canEditDraft(card) {
                            Button("Edit card…") { editCardPresented = true }
                        }
                        if card.initialPromptSentAt.isEmpty && card.workspace.revision.isEmpty {
                            Button("Workspace settings…", systemImage: "slider.horizontal.3") { workspaceSettingsPresented = true }
                        }
                        Button("Open workspace in Files", systemImage: "folder") { Task { await store.openWorkspaceFiles(card: card) } }
                        Button("New terminal in workspace", systemImage: "terminal") { Task { await store.openWorkspaceTerminal(card: card) } }
                        if ["running", "starting", "waiting_for_user"].contains(status) {
                            Button("Interrupt agent", role: .destructive) { Task { await store.cancel(card) } }
                        }
                        Divider()
                        Button("Archive \(standalone ? "chat" : "card")", role: .destructive) { Task { await store.archive(card, archived: true) } }
                    } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .buttonStyle(DieterIconButtonStyle())
                }
            }
        } secondary: {
            ConversationTabBar(
                items: standalone ? [("Conversation", 0), ("Changes", Int(card?.workspace.changedFiles ?? 0)), ("Subagents", subagentCount)] : [
                    ("Conversation", 0),
                    ("Changes", Int(card?.workspace.changedFiles ?? 0)),
                    ("Comments", Int(store.selectedDetail?.card.commentCount ?? 0)),
                    ("Subagents", subagentCount),
                ],
                selection: $tab
            )
        }
        .sheet(isPresented: $editCardPresented) {
            if let card {
                EditCardSheet(card: card).environment(store)
            }
        }
        .sheet(isPresented: $workspaceSettingsPresented) {
            if let card { ConversationWorkspaceSettingsSheet(card: card).environment(store) }
        }
    }
}

private struct ConversationTabBar: View {
    let items: [(String, Int)]
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 16) {
            ForEach(items, id: \.0) { item in
                Button { selection = item.0 } label: {
                    VStack(spacing: 5) {
                        HStack(spacing: 5) {
                            Text(item.0).lineLimit(1)
                            if item.1 > 0 {
                                ConversationTabCountBadge(count: item.1, selected: selection == item.0)
                            }
                        }
                        .font(.system(size: 12, weight: selection == item.0 ? .semibold : .medium))
                        .foregroundStyle(selection == item.0 ? DieterTheme.text : DieterTheme.subtle)
                        Capsule().fill(selection == item.0 ? DieterTheme.primary : .clear).frame(height: 2)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }.buttonStyle(.plain)
                    .accessibilityLabel(item.1 > 0 ? "\(item.0), \(item.1)" : item.0)
                    .accessibilityIdentifier("conversation-tab-\(item.0.lowercased())")
            }
            Spacer()
        }
    }
}

private struct ConversationTabCountBadge: View {
    let count: Int
    let selected: Bool

    var body: some View {
        Text(count, format: .number)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(selected ? DieterTheme.text : DieterTheme.tertiary)
            .padding(.horizontal, 6)
            .frame(minWidth: 18, minHeight: 18)
            .background(selected ? DieterTheme.selection : DieterTheme.raised, in: Capsule())
            .overlay(Capsule().stroke(selected ? DieterTheme.strongBorder : DieterTheme.border))
            .contentTransition(.numericText())
            .accessibilityHidden(true)
    }
}

private struct ConversationTimelineRow: View {
    let item: ConversationTimelineItem
    let details: [ConversationTimelineMessageDetails]

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            if item.isToolCallGroup {
                ToolCallGroupView(items: item.toolCalls)
            } else if let message = item.messages.first {
                MessageView(message: message)
            }
            ForEach(details) { detail in
                ForEach(detail.plans, id: \.id) {
                    TaskPlanView(plan: $0)
                }
                if !detail.subagents.isEmpty {
                    SubagentTimelineGroup(agents: detail.subagents)
                }
            }
        }
    }
}

struct ConversationTimeline: View {
    @Environment(DieterStore.self) private var store
    @State private var historyLoadInFlight = false
    @State private var isAtLatest = true
    @State private var userScrollInProgress = false
    @State private var viewportMode = ConversationViewportMode.awaitingInitial(conversationID: "")
    @State private var presentedFailureLog: String?
    @State private var retryingFailureLog: String?
    @State private var projection = ConversationTimelineProjection.empty
    @State private var projectionConversationID = ""
    @State private var renderWindowStart: Int?
    @State private var tailScrollRequest = 0

    private var messages: [Dieter_V1_UiMessage] { store.conversationMessages }
    private var timelineItems: [ConversationTimelineItem] { projection.items }
    private var plans: [Dieter_V1_TaskPlan] { store.conversation?.conversation.taskPlans ?? [] }
    private var subagents: [Dieter_V1_Subagent] { store.conversation?.conversation.subagents ?? [] }
    private var queuedMessages: [Dieter_V1_QueuedMessage] { store.conversation?.conversation.queue ?? [] }
    private var timelineRows: [ConversationTimelineRowContent] { projection.rows }
    private var renderRange: Range<Int> {
        ConversationRenderWindow.range(messageCount: messages.count, requestedStart: renderWindowStart)
    }
    private var projectionKey: ConversationPresentationKey {
        ConversationPresentationKey(
            conversationID: conversationID,
            revision: store.conversationPresentationRevision,
            showReasoning: store.showReasoning,
            renderStart: renderRange.lowerBound,
            renderCount: renderRange.count
        )
    }
    private var conversationID: String { store.selectedCardID ?? store.selectedChatID ?? "" }
    private var draftPrompt: String {
        let card = store.selectedCard ?? store.selectedDetail?.card
        return card?.initialPromptSentAt.isEmpty == true ? (card?.initialPrompt ?? "") : ""
    }
    private var draftAttachments: [Dieter_V1_MessagePart] {
        store.conversation?.conversation.draftAttachments ?? []
    }
    private var pendingTools: [Dieter_V1_PendingTool] {
        store.conversation?.conversation.pendingTools ?? []
    }
    private var agentIsWorking: Bool {
        let card = store.selectedCard ?? store.selectedDetail?.card
        return ConversationActivityPresentation.isActive(
            conversationStatus: store.conversation?.conversation.status ?? "",
            cardRuntime: card?.runtime ?? ""
        )
    }
    private var turnFailure: ConversationTurnFailure? {
        let card = store.selectedCard ?? store.selectedDetail?.card
        return ConversationTurnFailure.resolve(
            messages: messages,
            conversationStatus: store.conversation?.conversation.status ?? "",
            cardRuntime: card?.runtime ?? ""
        )
    }
    private var showsJumpToLatest: Bool {
        ConversationScrollBehavior.showsJumpToLatest(viewportMode: viewportMode)
    }
    private var viewportObservation: ConversationViewportObservation {
        ConversationViewportObservation(
            conversationID: conversationID,
            isAtLatest: isAtLatest,
            followsLatest: ConversationScrollBehavior.followsLatest(viewportMode),
            initialPositionComplete: viewportMode != .awaitingInitial(conversationID: conversationID)
        )
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // The server delivers a bounded page, so eager layout is both
                // affordable and avoids the macOS LazyVStack/SelectionOverlay
                // anchor-translation cycle that can trap AttributeGraph in one
                // transaction indefinitely.
                VStack(alignment: .leading, spacing: 15) {
                    if store.conversationHistoryLoading {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Loading earlier messages…")
                                .font(.caption)
                                .foregroundStyle(DieterTheme.tertiary)
                        }
                        .frame(maxWidth: .infinity)
                        .id("conversation.history-loading")
                    } else if store.conversationHistoryHasMore {
                        Button("Load earlier messages · \(messages.count) of \(store.conversationHistoryTotal)") {
                            loadEarlierHistory(proxy: proxy)
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(DieterTheme.tertiary)
                        .frame(maxWidth: .infinity)
                    }

                    if messages.isEmpty && !agentIsWorking {
                        EmptyConversationView(
                            standalone: store.selectedCard?.scope == "chat",
                            prompt: draftPrompt,
                            attachments: draftAttachments
                        )
                    }

                    ForEach(timelineRows) { row in
                        ConversationTimelineRow(item: row.item, details: row.details)
                            .id(row.id)
                    }

                    ForEach(queuedMessages, id: \.id) { message in
                        QueuedMessageView(
                            message: message,
                            canInterrupt: ConversationQueuePresentation.canInterrupt(
                                messageID: message.id,
                                queue: queuedMessages,
                                agentIsWorking: agentIsWorking
                            )
                        )
                            .id("queued:\(message.id)")
                    }

                    ForEach(projection.unattachedPlans, id: \.id) {
                        TaskPlanView(plan: $0)
                    }

                    if !pendingTools.isEmpty {
                        PendingToolGroupView(tools: pendingTools)
                    }
                    if agentIsWorking {
                        ConversationAgentWorkingIndicator(hasPendingTool: !pendingTools.isEmpty)
                            .id("conversation.agent-working")
                    }
                    if let turnFailure {
                        TurnFailureBanner(
                            failure: turnFailure,
                            retrying: retryingFailureLog == turnFailure.log,
                            onViewLog: { presentedFailureLog = turnFailure.log },
                            onRetry: {
                                guard retryingFailureLog == nil else { return }
                                retryingFailureLog = turnFailure.log
                                Task { @MainActor in
                                    if !(await store.retryFailedTurn(turnFailure)) {
                                        retryingFailureLog = nil
                                    }
                                }
                            }
                        )
                        .id("conversation.turn-failure")
                    }
                    Color.clear.frame(height: 17).id(ConversationScrollBehavior.bottomID)
                }
                .padding(.horizontal, 18).padding(.top, 17)
            }
            .textSelection(.enabled)
            .background(DieterTheme.background)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                ConversationScrollBehavior.isAtLatest(
                    visibleMaxY: geometry.visibleRect.maxY,
                    contentHeight: geometry.contentSize.height
                )
            } action: { _, atLatest in
                isAtLatest = atLatest
                if userScrollInProgress {
                    viewportMode = ConversationScrollBehavior.afterUserScroll(isAtLatest: atLatest)
                } else if !atLatest, ConversationScrollBehavior.followsLatest(viewportMode) {
                    requestTailScroll()
                }
            }
            .onScrollPhaseChange { oldPhase, newPhase in
                let wasUserDriven = ConversationScrollBehavior.isUserDriven(oldPhase)
                let isUserDriven = ConversationScrollBehavior.isUserDriven(newPhase)
                userScrollInProgress = isUserDriven
                if isUserDriven, !isAtLatest {
                    viewportMode = .detached
                } else if wasUserDriven, !isUserDriven {
                    viewportMode = ConversationScrollBehavior.afterUserScroll(isAtLatest: isAtLatest)
                }
            }
            .overlay(alignment: .bottom) {
                if showsJumpToLatest {
                    Button {
                        viewportMode = .followingLatest
                        scrollToLatest(proxy)
                        requestTailScroll()
                    } label: {
                        Label("Jump to latest", systemImage: "arrow.down")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 13)
                            .frame(height: 34)
                            .background(DieterTheme.elevated, in: Capsule())
                            .overlay(Capsule().stroke(DieterTheme.border))
                            .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 12)
                    .accessibilityIdentifier("conversation.jump-to-latest")
                }
            }
            .onChange(of: showsJumpToLatest) { _, visible in
                ConversationUISmokeRunner.recordJumpToLatestVisibility(visible)
            }
            .onChange(of: viewportObservation, initial: true) { _, observation in
                ConversationUISmokeRunner.recordViewportObservation(
                    conversationID: observation.conversationID,
                    isAtLatest: observation.isAtLatest,
                    followsLatest: observation.followsLatest,
                    initialPositionComplete: observation.initialPositionComplete
                )
            }
            .onChange(of: turnFailure?.log) { _, log in
                if log == nil { retryingFailureLog = nil }
            }
            .onChange(of: conversationID, initial: true) { _, selectedID in
                renderWindowStart = nil
                historyLoadInFlight = false
                projection = .empty
                projectionConversationID = ""
                viewportMode = .awaitingInitial(conversationID: selectedID)
                isAtLatest = false
                userScrollInProgress = false
            }
            .task(id: projectionKey) {
                let key = projectionKey
                let range = renderRange
                let source = Array(messages[range])
                let allMessageIDs = Set(messages.lazy.map(\.id).filter { !$0.isEmpty })
                let plans = plans
                let subagents = subagents
                let queue = queuedMessages
                let showReasoning = store.showReasoning
                let next = await Task.detached(priority: .userInitiated) {
                    ConversationTimelineProjection.build(
                        messages: source,
                        allMessageIDs: allMessageIDs,
                        plans: plans,
                        subagents: subagents,
                        queue: queue,
                        showReasoning: showReasoning
                    )
                }.value
                guard !Task.isCancelled,
                      key == projectionKey,
                      key.conversationID == conversationID else { return }
                projection = next
                projectionConversationID = key.conversationID
                if ConversationScrollBehavior.followsLatest(viewportMode) {
                    requestTailScroll()
                }
            }
            .task(id: ConversationTailScrollKey(
                conversationID: conversationID,
                request: tailScrollRequest
            )) {
                guard tailScrollRequest > 0,
                      projectionConversationID == conversationID,
                      ConversationScrollBehavior.followsLatest(viewportMode) else { return }
                await Task.yield()
                guard projectionConversationID == conversationID,
                      ConversationScrollBehavior.followsLatest(viewportMode),
                      !userScrollInProgress else { return }
                scrollToLatest(proxy)
                if viewportMode == .awaitingInitial(conversationID: conversationID) {
                    viewportMode = .followingLatest
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { presentedFailureLog != nil },
            set: { if !$0 { presentedFailureLog = nil } }
        )) {
            TurnFailureLogSheet(log: presentedFailureLog ?? "")
        }
    }

    private func scrollToLatest(_ proxy: ScrollViewProxy) {
        renderWindowStart = nil
        proxy.scrollTo(ConversationScrollBehavior.bottomID, anchor: .bottom)
    }

    private func requestTailScroll() {
        tailScrollRequest &+= 1
    }

    private func loadEarlierHistory(proxy: ScrollViewProxy) {
        guard !historyLoadInFlight else { return }
        historyLoadInFlight = true
        viewportMode = .detached
        // Anchor by message id, not timeline-item id: prepending a page can
        // merge the current first item into a differently-identified tool
        // group, and a missed scroll restore leaves the viewport at offset
        // zero, which would chain-load the entire history.
        let anchorMessageID = timelineItems.first?.messages.first?.id
        Task { @MainActor in
            let loaded = await store.loadEarlierMessages()
            if loaded {
                if let anchorMessageID,
                   let anchorIndex = messages.firstIndex(where: { $0.id == anchorMessageID }) {
                    renderWindowStart = max(0, anchorIndex - 30)
                } else {
                    renderWindowStart = 0
                }
                await Task.yield()
                let range = renderRange
                let items = ConversationTimelineItem.group(
                    Array(messages[range]),
                    showReasoning: store.showReasoning
                )
                if let anchor = ConversationScrollBehavior.anchorItem(containing: anchorMessageID, in: items) {
                    proxy.scrollTo(anchor, anchor: .top)
                }
            }
            historyLoadInFlight = false
        }
    }
}

struct TurnFailureBanner: View {
    let failure: ConversationTurnFailure
    let retrying: Bool
    let onViewLog: () -> Void
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Turn failed")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(DieterTheme.text)
                    Text("Turn failed — \(failure.summary)")
                        .font(.callout)
                        .foregroundStyle(DieterTheme.coral.opacity(0.9))
                        .textSelection(.enabled)
                }
                Spacer(minLength: 8)
                Image(systemName: "xmark.circle")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(DieterTheme.coral)
                    .accessibilityHidden(true)
            }
            HStack(spacing: 10) {
                Label("Failed", systemImage: "circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(DieterTheme.coral)
                    .padding(.horizontal, 11)
                    .frame(height: 29)
                    .background(DieterTheme.coral.opacity(0.13), in: Capsule())
                Spacer(minLength: 10)
                Button("View log", action: onViewLog)
                    .buttonStyle(.plain)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(DieterTheme.primary)
                    .accessibilityIdentifier("conversation.failure.view-log")
                Button(action: onRetry) {
                    HStack(spacing: 6) {
                        if retrying { ProgressView().controlSize(.mini) }
                        Text(retrying ? "Retry queued…" : "Retry turn")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(DieterTheme.elevated)
                .foregroundStyle(DieterTheme.text)
                .disabled(retrying || failure.retryParts.isEmpty)
                .accessibilityIdentifier("conversation.failure.retry")
            }
        }
        .padding(16)
        .background(DieterTheme.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(DieterTheme.coral.opacity(0.45), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("conversation.turn-failure")
    }
}

private struct TurnFailureLogSheet: View {
    @Environment(\.dismiss) private var dismiss
    let log: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Turn failure log").font(.title3.weight(.semibold))
                    Text("Complete output captured from the local harness worker.")
                        .font(.caption).foregroundStyle(DieterTheme.tertiary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            ScrollView([.horizontal, .vertical]) {
                Text(log)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(DieterTheme.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(12)
            }
            .background(DieterTheme.background, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(DieterTheme.border))
            HStack {
                Button("Copy log") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(log, forType: .string)
                }
                Spacer()
            }
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 440)
        .background(DieterTheme.surface)
        .accessibilityIdentifier("conversation.failure.log-sheet")
    }
}

enum ConversationQueuePresentation {
    static func deliveredMessages(
        _ messages: [Dieter_V1_UiMessage],
        whileQueued queue: [Dieter_V1_QueuedMessage]
    ) -> [Dieter_V1_UiMessage] {
        let queuedIDs = Set(queue.lazy.map(\.id).filter { !$0.isEmpty })
        return messages.filter { !queuedIDs.contains($0.id) }
    }

    static func canInterrupt(
        messageID: String,
        queue: [Dieter_V1_QueuedMessage],
        agentIsWorking: Bool
    ) -> Bool {
        agentIsWorking && !messageID.isEmpty && queue.first?.id == messageID
    }
}

private struct ConversationAgentWorkingIndicator: View {
    let hasPendingTool: Bool

    var body: some View {
        HStack(spacing: 8) {
            DieterActivityIndicator(size: 12)
                .accessibilityHidden(true)
            Text(ConversationActivityPresentation.label(hasPendingTool: hasPendingTool))
                .font(.caption.weight(.medium))
                .foregroundStyle(DieterTheme.subtle)
        }
        .padding(.horizontal, 11)
        .frame(height: 34)
        .background(DieterTheme.surface.opacity(0.85), in: Capsule())
        .overlay(Capsule().stroke(DieterTheme.primary.opacity(0.18)))
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(ConversationActivityPresentation.label(hasPendingTool: hasPendingTool))
        .accessibilityIdentifier("conversation.agent-working")
    }
}

enum ConversationScrollBehavior {
    static let bottomID = "conversation.bottom"
    private static let latestTolerance: CGFloat = 2

    static func isAtLatest(visibleMaxY: CGFloat, contentHeight: CGFloat) -> Bool {
        visibleMaxY >= contentHeight - latestTolerance
    }

    static func followsLatest(_ viewportMode: ConversationViewportMode) -> Bool {
        switch viewportMode {
        case .awaitingInitial, .followingLatest:
            true
        case .detached:
            false
        }
    }

    static func showsJumpToLatest(viewportMode: ConversationViewportMode) -> Bool {
        viewportMode == .detached
    }

    static func afterUserScroll(isAtLatest: Bool) -> ConversationViewportMode {
        isAtLatest ? .followingLatest : .detached
    }

    static func isUserDriven(_ phase: ScrollPhase) -> Bool {
        phase.isScrolling && phase != .animating
    }

    static func anchorItem(containing messageID: String?, in items: [ConversationTimelineItem]) -> String? {
        guard let messageID, !messageID.isEmpty else { return nil }
        return items.first { item in item.messages.contains { $0.id == messageID } }?.id
    }
}

enum ConversationViewportMode: Equatable {
    case awaitingInitial(conversationID: String)
    case followingLatest
    case detached
}

private struct ConversationViewportObservation: Equatable {
    let conversationID: String
    let isAtLatest: Bool
    let followsLatest: Bool
    let initialPositionComplete: Bool
}

private struct ConversationTailScrollKey: Equatable {
    let conversationID: String
    let request: Int
}

private struct EmptyConversationView: View {
    let standalone: Bool
    let prompt: String
    let attachments: [Dieter_V1_MessagePart]
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left").font(.system(size: 24)).foregroundStyle(DieterTheme.shell)
            Text("Ready when you are").font(.headline)
            Text(standalone ? "Start a focused conversation in this project." : "Send this card's brief to start its local harness session.")
                .font(.caption).foregroundStyle(DieterTheme.tertiary).multilineTextAlignment(.center)
            if !prompt.isEmpty || !attachments.isEmpty {
                VStack(alignment: .leading, spacing: 9) {
                    if !prompt.isEmpty { Text(prompt).font(.callout) }
                    if !attachments.isEmpty {
                        HStack(spacing: 8) {
                            ForEach(Array(attachments.enumerated()), id: \.offset) { _, part in
                                AttachmentPreviewTile(part: part)
                            }
                        }
                    }
                }
                .padding(12).frame(maxWidth: 520, alignment: .leading)
                .background(DieterTheme.elevated, in: RoundedRectangle(cornerRadius: 10))
            }
        }.frame(maxWidth: .infinity).padding(.vertical, 55)
    }
}

struct MessageView: View {
    @Environment(DieterStore.self) private var store
    let message: Dieter_V1_UiMessage

    private var deliveryState: MessageDeliveryState {
        MessageDeliveryState(
            pending: store.isPendingMessage(message.id),
            accepted: store.isAcceptedOutboxItem(message.id),
            failed: store.isFailedOutboxItem(message.id),
            queued: store.conversation?.conversation.queue.contains { $0.id == message.id } == true
        )
    }

    var body: some View {
        if message.role == "user" {
            HStack {
                Spacer(minLength: 70)
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(message.parts.enumerated()), id: \.offset) { _, part in
                        MessagePartView(messageID: message.id, part: part, inUserBubble: true)
                    }
                }
                .padding(.leading, 13).padding(.trailing, 18).padding(.vertical, 10)
                .background(DieterTheme.shellDeep.opacity(0.9), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .frame(maxWidth: 620, alignment: .trailing)
            }
            .opacity(store.isPendingMessage(message.id) ? 0.52 : 1)
            .overlay(alignment: .bottomTrailing) {
                MessageDeliveryReceipt(state: deliveryState)
                    .padding(.trailing, 4)
                    .padding(.bottom, 4)
            }
            .contextMenu {
                if deliveryState == .failed {
                    Button("Retry queued message") { Task { await store.retryOutboxItem(message.id) } }
                    Button("Discard queued message", role: .destructive) { Task { await store.discardOutboxItem(message.id) } }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(ConversationMessagePartGroup.group(message.parts, showReasoning: store.showReasoning).enumerated()), id: \.offset) { _, group in
                    if group.isToolCallGroup {
                        ToolCallGroupView(items: group.parts.map {
                            ConversationToolCall(messageID: message.id, part: $0)
                        })
                    } else if let part = group.parts.first {
                        MessagePartView(messageID: message.id, part: part, inUserBubble: false)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct QueuedMessageView: View {
    @Environment(DieterStore.self) private var store
    let message: Dieter_V1_QueuedMessage
    let canInterrupt: Bool
    @State private var interrupting = false

    private var parts: [Dieter_V1_MessagePart] {
        if !message.parts.isEmpty { return message.parts }
        guard !message.text.isEmpty else { return [] }
        var part = Dieter_V1_MessagePart()
        part.type = "text"
        part.text = message.text
        return [part]
    }

    var body: some View {
        HStack {
            Spacer(minLength: 70)
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    MessagePartView(messageID: message.id, part: part, inUserBubble: true)
                }
                if canInterrupt {
                    HStack {
                        Spacer(minLength: 0)
                        Button {
                            interrupting = true
                            Task { @MainActor in
                                if let card = store.selectedCard ?? store.selectedDetail?.card {
                                    await store.cancel(card)
                                }
                                interrupting = false
                            }
                        } label: {
                            HStack(spacing: 5) {
                                if interrupting {
                                    ProgressView().controlSize(.mini)
                                } else {
                                    Image(systemName: "stop.fill")
                                        .font(.system(size: 8, weight: .bold))
                                }
                                Text(interrupting ? "Interrupting…" : "Interrupt")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            .foregroundStyle(DieterTheme.coral)
                            .padding(.horizontal, 9)
                            .frame(height: 25)
                            .background(DieterTheme.coral.opacity(0.1), in: Capsule())
                            .overlay(Capsule().stroke(DieterTheme.coral.opacity(0.24)))
                        }
                        .buttonStyle(.plain)
                        .disabled(interrupting)
                        .help("Interrupt the current turn and send this message now")
                        .accessibilityLabel("Interrupt current turn and send this message now")
                        .accessibilityIdentifier("conversation.queued-message.interrupt.\(message.id)")
                    }
                }
            }
            .padding(.leading, 13).padding(.trailing, 18).padding(.vertical, 10)
            .background(DieterTheme.shellDeep.opacity(0.72), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(DieterTheme.amber.opacity(0.45))
            }
            .frame(maxWidth: 620, alignment: .trailing)
        }
        .overlay(alignment: .bottomTrailing) {
            MessageDeliveryReceipt(state: .queued)
                .padding(.trailing, 4)
                .padding(.bottom, 4)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("conversation.queued-message.\(message.id)")
    }
}

enum MessageDeliveryState: Equatable {
    case local
    case accepted
    case queued
    case synced
    case failed

    init(pending: Bool, accepted: Bool, failed: Bool, queued: Bool = false) {
        if failed { self = .failed }
        else if queued { self = .queued }
        else if !pending { self = .synced }
        else if accepted { self = .accepted }
        else { self = .local }
    }
}

private struct MessageDeliveryReceipt: View {
    let state: MessageDeliveryState

    var body: some View {
        Group {
            switch state {
            case .local:
                Image(systemName: "clock")
            case .accepted:
                Image(systemName: "checkmark")
            case .queued:
                Image(systemName: "clock.badge.checkmark")
            case .synced:
                ZStack {
                    Image(systemName: "checkmark")
                        .offset(x: -2)
                    Image(systemName: "checkmark")
                        .offset(x: 2)
                }
                .frame(width: 14, height: 10)
            case .failed:
                Image(systemName: "exclamationmark.circle.fill")
            }
        }
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(state == .failed ? DieterTheme.coral : (state == .queued ? DieterTheme.amber : DieterTheme.tertiary))
        .accessibilityLabel(accessibilityLabel)
        .help(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        switch state {
        case .local: "Waiting to send"
        case .accepted: "Accepted by daemon"
        case .queued: "Queued for the next turn"
        case .synced: "Synced"
        case .failed: "Send failed; use the context menu to retry or discard"
        }
    }
}

struct ConversationMessagePartGroup {
    var parts: [Dieter_V1_MessagePart]
    let isToolCallGroup: Bool

    static func group(_ parts: [Dieter_V1_MessagePart], showReasoning: Bool = true) -> [ConversationMessagePartGroup] {
        var groups: [ConversationMessagePartGroup] = []
        for part in parts {
            if isHidden(part, showReasoning: showReasoning) { continue }
            let isToolCall = isToolCall(part)
            if isToolCall, groups.last?.isToolCallGroup == true {
                groups[groups.count - 1].parts.append(part)
            } else {
                groups.append(.init(parts: [part], isToolCallGroup: isToolCall))
            }
        }
        return groups
    }

    static func isToolCall(_ part: Dieter_V1_MessagePart) -> Bool {
        let type = part.type.lowercased()
        return toolTypes.contains(type) || type.hasPrefix("tool-")
    }

    // Hidden parts must not split adjacent tool calls into separate groups,
    // matching the Android timeline behavior.
    static func isHidden(_ part: Dieter_V1_MessagePart, showReasoning: Bool) -> Bool {
        if isToolCall(part) { return false }
        if ConversationTurnFailure.isFailurePart(part) { return true }
        switch part.type.lowercased() {
        case "reasoning", "thinking":
            return !showReasoning || part.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case "step-start":
            return true
        case "image":
            return part.url.isEmpty && part.data.isEmpty
        case "file", "attachment":
            return false
        default:
            return part.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private static let toolTypes: Set<String> = ["tool", "tool_call", "dynamic-tool"]
}

extension Dieter_V1_MessagePart {
    // AI SDK static tool parts are typed "tool-<Name>" and may omit toolName.
    var effectiveToolName: String {
        if !toolName.isEmpty { return toolName }
        if type.lowercased().hasPrefix("tool-") { return String(type.dropFirst("tool-".count)) }
        return ""
    }
}

struct ToolCallGroupSummary: Equatable {
    let edits: Int
    let commands: Int
    let otherTools: Int

    init(toolNames: [String]) {
        var edits = 0
        var commands = 0
        var otherTools = 0
        for toolName in toolNames {
            switch Self.category(for: toolName) {
            case .edit: edits += 1
            case .command: commands += 1
            case .other: otherTools += 1
            }
        }
        self.edits = edits
        self.commands = commands
        self.otherTools = otherTools
    }

    var title: String {
        var components: [String] = []
        if edits > 0 { components.append("\(edits) edit\(edits == 1 ? "" : "s")") }
        if commands > 0 { components.append("\(commands) command\(commands == 1 ? "" : "s")") }
        if otherTools > 0 { components.append("\(otherTools) tool call\(otherTools == 1 ? "" : "s")") }
        return components.isEmpty ? "Tool calls" : components.joined(separator: ", ")
    }

    private enum Category { case edit, command, other }

    private static func category(for toolName: String) -> Category {
        let normalized = toolName
            .lowercased()
            .split(whereSeparator: { $0 == "." || $0 == "/" })
            .last
            .map(String.init) ?? ""
        if ["edit", "apply_patch", "patch", "write_file", "multi_edit", "str_replace_editor"].contains(normalized) {
            return .edit
        }
        if ["bash", "shell", "command", "exec", "exec_command", "write_stdin", "terminal"].contains(normalized) {
            return .command
        }
        return .other
    }
}

struct MessagePartView: View {
    @Environment(DieterStore.self) private var store
    let messageID: String
    let part: Dieter_V1_MessagePart
    let inUserBubble: Bool
    @State private var reasoningExpanded = false

    var body: some View {
        switch part.type.lowercased() {
        case "reasoning", "thinking":
            if store.showReasoning {
                Button { withAnimation(.easeInOut(duration: 0.16)) { reasoningExpanded.toggle() } } label: {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 7) {
                            Image(systemName: reasoningExpanded ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .bold))
                            Text("Reasoning").font(.caption.weight(.medium))
                        }.foregroundStyle(DieterTheme.tertiary)
                        if reasoningExpanded {
                            Text(part.text).font(.caption).foregroundStyle(DieterTheme.subtle).lineSpacing(3)
                                .padding(.leading, 15)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain)
            }
        case "tool", "tool-call", "tool_call", "dynamic-tool":
            ToolCallView(messageID: messageID, part: part)
        case "image":
            if let image = attachmentImage {
                previewableAttachmentImage(image)
            } else if let url = URL(string: part.url), !part.url.isEmpty {
                AsyncImage(url: url) { $0.resizable().scaledToFit() } placeholder: { ProgressView() }
                    .frame(maxHeight: 340).clipShape(RoundedRectangle(cornerRadius: 9))
            }
        case "file", "attachment":
            if part.mediaType.hasPrefix("image/"), let image = attachmentImage {
                previewableAttachmentImage(image)
            } else {
                HStack(spacing: 9) {
                    Image(systemName: "doc.fill").foregroundStyle(DieterTheme.shell)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(part.filename.isEmpty ? "Attachment" : part.filename).font(.caption.weight(.semibold))
                        Text(part.mediaType).font(.caption2).foregroundStyle(DieterTheme.tertiary)
                    }
                }
                .padding(10).background(DieterTheme.surface, in: RoundedRectangle(cornerRadius: 8))
            }
        default:
            if !part.text.isEmpty {
                Text(ConversationRenderCache.markdown(part.text))
                    .font(.system(size: 13))
                    .foregroundStyle(inUserBubble ? Color.white : DieterTheme.text)
                    .lineSpacing(4)
            }
        }
    }

    private var attachmentImage: NSImage? {
        AttachmentImagePayload.image(from: part)
    }

    private func previewableAttachmentImage(_ image: NSImage) -> some View {
        AttachmentImageButton(part: part, image: image, maximumHeight: 340)
    }
}

private struct AttachmentImageButton: View {
    let part: Dieter_V1_MessagePart
    let image: NSImage
    let maximumHeight: CGFloat
    @State private var previewPresented = false

    var body: some View {
        Button { previewPresented = true } label: {
            Image(nsImage: image)
                .resizable().scaledToFit().frame(maxHeight: maximumHeight)
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(.white)
                        .padding(7).background(Color.black.opacity(0.55), in: Circle()).padding(7)
                }
        }
        .buttonStyle(.plain)
        .help("Preview \(part.filename.isEmpty ? "image" : part.filename)")
        .accessibilityLabel("Preview \(part.filename.isEmpty ? "image attachment" : part.filename)")
        .sheet(isPresented: $previewPresented) {
            AttachmentImagePreview(part: part, image: image)
        }
    }
}

struct ToolCallView: View {
    @Environment(DieterStore.self) private var store
    let messageID: String
    let part: Dieter_V1_MessagePart
    @State private var expanded = false
    @State private var output: Dieter_V1_ToolOutput?
    @State private var loading = false

    private var completed: Bool { ["completed", "success", "done"].contains(part.state.lowercased()) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(DieterTheme.tertiary)
                    Image(systemName: completed ? "checkmark.circle" : "terminal").font(.system(size: 11, weight: .medium)).foregroundStyle(completed ? DieterTheme.eyes : DieterTheme.shell)
                    Text(part.effectiveToolName.isEmpty ? "Command" : part.effectiveToolName).font(.caption.monospaced().weight(.medium)).lineLimit(1)
                    Spacer()
                    if loading { ProgressView().controlSize(.mini) }
                    else { Text(part.state.isEmpty ? (part.hasOutput_p ? "output available" : "tool") : part.state.replacingOccurrences(of: "_", with: " ")).font(.caption2).foregroundStyle(DieterTheme.tertiary) }
                }
                .padding(.horizontal, 10).frame(height: 34)
                .contentShape(Rectangle())
            }.buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 9) {
                    let input = output.map { String(decoding: $0.inputJson, as: UTF8.self) } ?? part.inputPreview
                    let result = output.map { String(decoding: $0.outputJson, as: UTF8.self) } ?? part.outputPreview
                    if !input.isEmpty { CodeBlock(title: "Input", value: input) }
                    if !result.isEmpty { CodeBlock(title: "Output", value: result) }
                    let error = output?.errorText ?? part.errorText
                    if !error.isEmpty { Text(error).font(.caption.monospaced()).foregroundStyle(DieterTheme.coral) }
                }
                .padding(.horizontal, 10).padding(.bottom, 10)
            }
        }
        .background(DieterTheme.surface.opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
        .onChange(of: expanded) { _, value in if value && output == nil { Task { await load() } } }
    }

    private func load() async {
        guard !part.toolCallID.isEmpty else { return }
        loading = true
        do {
            output = try await store.toolOutput(
                messageID: messageID,
                toolCallID: part.toolCallID,
                revision: part.payloadRevision
            )
        } catch { store.show(error) }
        loading = false
    }
}

private struct ToolCallGroupView: View {
    let items: [ConversationToolCall]
    @State private var expanded = false

    private var title: String { ToolCallGroupSummary(toolNames: items.map(\.part.effectiveToolName)).title }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button { withAnimation(.easeInOut(duration: 0.16)) { expanded.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(DieterTheme.tertiary)
                    Text(title)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(DieterTheme.subtle)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(expanded ? "Collapse" : "Expand") \(title)")

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(items) { item in
                        ToolCallView(messageID: item.messageID, part: item.part)
                    }
                }
                .padding(.leading, 14)
            }
        }
    }
}

struct CodeBlock: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.system(size: 9, weight: .bold)).tracking(0.7).foregroundStyle(DieterTheme.tertiary)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(value).font(.system(size: 11, design: .monospaced)).foregroundStyle(DieterTheme.subtle).lineSpacing(3)
            }
        }
        .padding(10).background(DieterTheme.input, in: RoundedRectangle(cornerRadius: 7))
    }
}

private struct PendingToolRow: View {
    let tool: Dieter_V1_PendingTool
    var body: some View {
        HStack(spacing: 9) {
            ProgressView().controlSize(.mini)
            Text(tool.toolName.isEmpty ? "Running command" : tool.toolName).font(.caption.monospaced())
            Spacer(); Text("Running…").font(.caption2).foregroundStyle(DieterTheme.primary)
        }
        .padding(.horizontal, 11).frame(height: 36)
        .background(DieterTheme.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(DieterTheme.primary.opacity(0.18)))
    }
}

private struct PendingToolGroupView: View {
    let tools: [Dieter_V1_PendingTool]
    @State private var expanded = false

    private var title: String { ToolCallGroupSummary(toolNames: tools.map(\.toolName)).title }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button { withAnimation(.easeInOut(duration: 0.16)) { expanded.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(DieterTheme.tertiary)
                    Text(title).font(.caption.weight(.medium)).foregroundStyle(DieterTheme.subtle)
                    ProgressView().controlSize(.mini)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(expanded ? "Collapse" : "Expand") running \(title)")

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(tools, id: \.id) { tool in
                        PendingToolRow(tool: tool)
                    }
                }
                .padding(.leading, 14)
            }
        }
    }
}

struct TaskPlanView: View {
    let plan: Dieter_V1_TaskPlan
    @State private var expanded = true

    private var tasks: [Dieter_V1_TaskPlanItem] { plan.phases.flatMap(\.tasks) }
    private var completed: Int { tasks.filter { $0.status == "completed" }.count }

    var body: some View {
        VStack(spacing: 0) {
            Button { withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: "checklist").font(.system(size: 11)).foregroundStyle(DieterTheme.shell)
                    Text("Progress").font(.caption.weight(.semibold))
                    Spacer()
                    Text("\(completed) of \(tasks.count)").font(.caption2).foregroundStyle(DieterTheme.tertiary)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(DieterTheme.tertiary)
                }.padding(.horizontal, 12).frame(height: 38)
            }.buttonStyle(.plain)

            if expanded {
                if !plan.explanation.isEmpty {
                    Text(plan.explanation).font(.caption).foregroundStyle(DieterTheme.subtle)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.bottom, 9)
                }
                ForEach(Array(tasks.enumerated()), id: \.offset) { _, task in
                    Divider().overlay(DieterTheme.border)
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: planIcon(task.status))
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(planColor(task.status)).frame(width: 14)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(task.status == "in_progress" && !task.activeForm.isEmpty ? task.activeForm : task.content)
                                .font(.caption).foregroundStyle(task.status == "pending" ? DieterTheme.subtle : DieterTheme.text)
                            if !task.blocker.isEmpty { Text(task.blocker).font(.caption2).foregroundStyle(DieterTheme.coral) }
                        }
                        Spacer()
                    }.padding(.horizontal, 12).padding(.vertical, 10)
                }
            }
        }
        .background(DieterTheme.surface.opacity(0.72), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(DieterTheme.border))
    }

    private func planIcon(_ status: String) -> String {
        status == "completed" ? "checkmark.circle.fill" : status == "in_progress" ? "circle.dotted.circle.fill" : "circle"
    }
    private func planColor(_ status: String) -> Color {
        status == "completed" ? DieterTheme.eyes : status == "in_progress" ? DieterTheme.primary : DieterTheme.tertiary
    }
}

private struct SubagentTimelineGroup: View {
    let agents: [Dieter_V1_Subagent]
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button { withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() } } label: {
                HStack(spacing: 7) {
                    Image(systemName: "person.2.fill").font(.system(size: 10)).foregroundStyle(DieterTheme.shell)
                    Text("\(agents.count) subagent\(agents.count == 1 ? "" : "s")").font(.caption.weight(.semibold))
                    Spacer(); Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 8)).foregroundStyle(DieterTheme.tertiary)
                }
                .padding(.horizontal, 10).frame(height: 31)
                .background(DieterTheme.raised, in: RoundedRectangle(cornerRadius: 7))
            }.buttonStyle(.plain)
            if expanded {
                VStack(spacing: 7) { ForEach(agents, id: \.id) { SubagentTimelineCard(agent: $0) } }.padding(.leading, 14)
            }
        }
    }
}

private struct SubagentTimelineCard: View {
    let agent: Dieter_V1_Subagent
    @State private var expanded = false

    var body: some View {
        VStack(spacing: 0) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 9) {
                    Image(systemName: agent.status == "completed" ? "checkmark" : "circle.dotted")
                        .foregroundStyle(runtimeColor(agent.status)).frame(width: 13)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(agent.name.isEmpty ? (agent.agentType.isEmpty ? "Subagent" : agent.agentType) : agent.name).font(.caption.weight(.semibold)).lineLimit(1)
                        Text([agent.provider, agent.model].filter { !$0.isEmpty }.joined(separator: "/")).font(.caption2).foregroundStyle(DieterTheme.tertiary)
                    }
                    Spacer(); Text(agent.status.uppercased()).font(.system(size: 9, weight: .bold)).tracking(0.8).foregroundStyle(runtimeColor(agent.status))
                    Image(systemName: expanded ? "chevron.up" : "chevron.right").font(.system(size: 8)).foregroundStyle(DieterTheme.tertiary)
                }.padding(11)
            }.buttonStyle(.plain)
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    Text(agent.assignment.isEmpty ? agent.task : agent.assignment).font(.caption).foregroundStyle(DieterTheme.subtle)
                    if !agent.recentOutput.isEmpty { CodeBlock(title: "Recent output", value: agent.recentOutput.joined(separator: "\n")) }
                }.padding(.horizontal, 11).padding(.bottom, 11)
            }
        }
        .background(DieterTheme.surface, in: RoundedRectangle(cornerRadius: 9))
    }
}

struct SubagentsView: View {
    @Environment(DieterStore.self) private var store
    private var agents: [Dieter_V1_Subagent] { store.conversation?.conversation.subagents ?? [] }
    private var running: Int { agents.filter { ["running", "pending"].contains($0.status) }.count }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 11) {
                HStack {
                    Text("\(agents.count) subagent\(agents.count == 1 ? "" : "s")").font(.headline)
                    if running > 0 { Text("• \(running) running").font(.caption.weight(.semibold)).foregroundStyle(DieterTheme.primary) }
                    Spacer()
                    if running > 0, let card = store.selectedCard {
                        Button { Task { await store.cancel(card) } } label: { Label("Stop all", systemImage: "stop.fill") }
                            .buttonStyle(.bordered).tint(DieterTheme.coral)
                    }
                }.padding(.bottom, 4)

                if agents.isEmpty {
                    ContentUnavailableView("No subagents", systemImage: "person.2", description: Text("Delegated work will appear here in real time."))
                        .padding(.vertical, 40)
                }
                ForEach(agents, id: \.id) { SubagentDetailCard(agent: $0) }
                if !agents.isEmpty { Text("Updates stream while connected").font(.caption2).foregroundStyle(DieterTheme.tertiary).padding(.top, 3) }
            }.padding(18)
        }.background(DieterTheme.background)
    }
}

private struct SubagentDetailCard: View {
    let agent: Dieter_V1_Subagent
    private var fraction: Double {
        guard agent.contextWindow > 0 else { return agent.status == "completed" ? 1 : 0 }
        return min(1, Double(agent.contextTokens) / Double(agent.contextWindow))
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: agent.status == "completed" ? "checkmark.circle" : "circle.dotted")
                        .foregroundStyle(runtimeColor(agent.status))
                    Text(agent.name.isEmpty ? (agent.agentType.isEmpty ? "Subagent" : agent.agentType) : agent.name).font(.subheadline.weight(.semibold))
                    Spacer(); Text(duration(agent.durationMs)).font(.caption2).foregroundStyle(DieterTheme.tertiary)
                }
                Text(agent.activity.isEmpty ? (agent.assignment.isEmpty ? agent.task : agent.assignment) : agent.activity)
                    .font(.caption).foregroundStyle(DieterTheme.subtle).lineLimit(2)
                let usage = SubagentUsagePresentation.resolve(tokens: agent.tokens, contextTokens: agent.contextTokens, contextWindow: agent.contextWindow)
                if !usage.metrics.isEmpty {
                    Text(usage.metrics.joined(separator: " · ")).font(.caption2).foregroundStyle(DieterTheme.tertiary)
                }
                if agent.status == "running" {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(DieterTheme.raised).frame(height: 3)
                            Capsule().fill(DieterTheme.primary).frame(width: max(16, geometry.size.width * fraction), height: 3)
                        }
                    }.frame(height: 3)
                }
            }.padding(13)
            Divider().overlay(DieterTheme.border)
            HStack {
                Text(agent.name.isEmpty ? String(agent.id.prefix(8)) : agent.name).font(.caption.weight(.semibold))
                Text([agent.provider, agent.model].filter { !$0.isEmpty }.joined(separator: "/")).font(.caption2).foregroundStyle(DieterTheme.tertiary)
                Spacer(); StatusPill(text: agent.status, color: runtimeColor(agent.status))
            }.padding(.horizontal, 13).frame(height: 36)
        }
        .background(DieterTheme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(agent.status == "running" ? DieterTheme.primary.opacity(0.5) : .clear))
    }

    private func duration(_ milliseconds: Int64) -> String {
        guard milliseconds > 0 else { return "" }
        let seconds = milliseconds / 1_000
        return seconds >= 60 ? "\(seconds / 60)m \(seconds % 60)s" : "\(seconds)s"
    }
}

struct CommentsView: View {
    @Environment(DieterStore.self) private var store
    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if (store.selectedDetail?.comments ?? []).isEmpty {
                        ContentUnavailableView("No Dieter comments yet", systemImage: "text.bubble", description: Text("Comments are non-triggering annotations and never resume the harness session."))
                            .padding(.vertical, 45)
                    }
                    ForEach(store.selectedDetail?.comments ?? [], id: \.id) { comment in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(comment.author.name.isEmpty ? comment.author.kind.capitalized : comment.author.name).font(.caption.weight(.semibold))
                                Spacer(); Text(comment.createdAt).font(.caption2).foregroundStyle(DieterTheme.tertiary)
                            }
                            Text(comment.body).font(.system(size: 13)).textSelection(.enabled).lineSpacing(3)
                        }
                        .padding(12).background(DieterTheme.surface, in: RoundedRectangle(cornerRadius: 9))
                    }
                }.padding(18)
            }
            Divider().overlay(DieterTheme.border)
            HStack(spacing: 9) {
                TextField("Add a non-triggering comment…", text: $store.commentText).textFieldStyle(.plain)
                    .padding(.horizontal, 11).frame(height: 36).background(DieterTheme.input, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(DieterTheme.border))
                Button("Comment") { Task { await store.addComment() } }.buttonStyle(DieterPrimaryButtonStyle()).disabled(store.commentText.isEmpty)
            }.padding(12).background(DieterTheme.sidebar)
        }
    }
}


private struct ConversationComposer: View {
    @Environment(DieterStore.self) private var store
    @Binding var fileImporterPresented: Bool
    @FocusState private var composerFocused: Bool
    @State private var attachmentDropTargeted = false

    private var harness: Dieter_V1_Harness? { store.harnessCatalog.harnesses.first { $0.id == store.composerProvider } }
    private var model: Dieter_V1_HarnessModel? { harness?.models.first { $0.id == store.composerModel } }
    private var working: Bool {
        ConversationActivityPresentation.isActive(
            conversationStatus: store.conversation?.conversation.status ?? "",
            cardRuntime: (store.selectedCard ?? store.selectedDetail?.card)?.runtime ?? ""
        )
    }
    private var hasDraft: Bool {
        !store.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !store.composerAttachments.isEmpty
    }
    var body: some View {
        @Bindable var store = store
        VStack(spacing: 8) {
            if let queue = store.conversation?.conversation.queue, !queue.isEmpty {
                HStack(spacing: 7) {
                    Image(systemName: "clock").font(.caption)
                    Text("\(queue.count) queued message\(queue.count == 1 ? "" : "s")").font(.caption)
                    Spacer(); Text("Delivered after this turn").font(.caption2)
                }.foregroundStyle(DieterTheme.amber)
            }
            VStack(alignment: .leading, spacing: 0) {
                TextField("Message the local agent…", text: $store.composerText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .lineLimit(1...5)
                    .focused($composerFocused)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .accessibilityIdentifier("conversation.composer")
                    .onKeyPress(.return, phases: .down) { press in
                        if !ComposerReturnPolicy.sendsMessage(shiftPressed: press.modifiers.contains(.shift)) {
                            return .ignored
                        }
                        if hasDraft { Task { await store.sendComposer() } }
                        return .handled
                    }
                    .frame(minHeight: 54, alignment: .topLeading)

                if !store.composerAttachments.isEmpty {
                    AttachmentPreviewStrip(attachments: $store.composerAttachments)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 6)
                }

                HStack(alignment: .center, spacing: 9) {
                    ViewThatFits(in: .horizontal) {
                        composerSettings(showContext: true)
                        composerSettings(showContext: false)
                    }
                    .frame(maxWidth: .infinity)

                    if working {
                        Button {
                            if let card = store.selectedCard ?? store.selectedDetail?.card {
                                Task { await store.cancel(card) }
                            }
                        } label: {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Color.white)
                                .frame(width: 30, height: 30)
                                .background(DieterTheme.coral, in: Circle())
                                .overlay(Circle().stroke(Color.white.opacity(0.14)))
                        }
                        .buttonStyle(.plain)
                        .help("Stop agent")
                        .accessibilityIdentifier("conversation.stop")
                    }

                    Button {
                        Task { await store.sendComposer() }
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(hasDraft ? Color.white : DieterTheme.tertiary)
                            .frame(width: 36, height: 36)
                            .background(
                                hasDraft ? DieterTheme.primary : DieterTheme.elevated,
                                in: Circle()
                            )
                            .overlay(Circle().stroke(Color.white.opacity(hasDraft ? 0.14 : 0.055)))
                            .shadow(color: DieterTheme.shellDeep.opacity(hasDraft ? 0.3 : 0), radius: 9, y: 3)
                    }
                    .buttonStyle(.plain)
                    .disabled(!hasDraft)
                    .help(working ? "Queue message" : "Send message")
                    .accessibilityIdentifier("conversation.send")
                }
                .padding(.leading, 10)
                .padding(.trailing, 9)
                .padding(.bottom, 9)

            }
            .background(attachmentDropTargeted ? DieterTheme.shellDeep.opacity(0.12) : DieterTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(attachmentDropTargeted ? DieterTheme.shell : (composerFocused ? DieterTheme.shellDeep.opacity(0.55) : DieterTheme.border), lineWidth: attachmentDropTargeted ? 1.5 : 1)
            }
            .shadow(color: Color.black.opacity(0.24), radius: 12, y: 5)
            .animation(.easeOut(duration: 0.16), value: composerFocused)
            .animation(.easeOut(duration: 0.12), value: attachmentDropTargeted)
            .attachmentDropTarget(isTargeted: $attachmentDropTargeted) { providers in
                store.addPastedAttachments(providers)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(DieterTheme.sidebar)
    }

    private func composerSettings(showContext: Bool) -> some View {
        HStack(spacing: 7) {
            Button { fileImporterPresented = true } label: { Image(systemName: "paperclip") }
                .buttonStyle(DieterIconButtonStyle())
                .help("Attach files")

            Menu {
                ForEach(store.harnessCatalog.harnesses, id: \.id) { item in
                    Button(item.name) {
                        store.composerProvider = item.id
                        store.composerModel = item.defaultModel
                        store.composerEffort = item.models.first(where: { $0.id == item.defaultModel })?.defaultEffort ?? ""
                        store.composerProviderOptions = ProviderOptionValues.defaults(for: item)
                    }
                }
            } label: {
                DieterChipLabel(title: harness?.name ?? store.composerProvider, symbol: "cpu")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Menu {
                ForEach(harness?.models ?? [], id: \.id) { item in
                    Button(item.name) {
                        store.composerModel = item.id
                        store.composerEffort = item.defaultEffort
                    }
                }
            } label: {
                DieterChipLabel(title: model?.name ?? store.composerModel, symbol: "terminal", maximumTitleWidth: 190)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            if let efforts = model?.efforts, !efforts.isEmpty {
                Menu {
                    ForEach(efforts, id: \.self) { value in
                        Button(value.capitalized) { store.composerEffort = value }
                    }
                } label: {
                    DieterChipLabel(title: store.composerEffort.isEmpty ? "Default" : store.composerEffort.capitalized, symbol: "sparkles")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            ProviderOptionChips(options: harness?.options ?? [], values: Binding(
                get: { store.composerProviderOptions },
                set: { store.composerProviderOptions = $0 }
            ))

            Spacer(minLength: 0)
            if showContext, let usage = ConversationContextUsage.latest(
                messages: store.conversation?.conversation.messages ?? [],
                fallbackWindow: Int64(model?.contextWindow ?? 0)
            ) {
                ContextUsageIndicator(usage: usage)
            }
        }
    }
}

struct ConversationContextUsage: Equatable {
    let used: Int64
    let window: Int64

    var fraction: Double { window > 0 ? min(1, max(0, Double(used) / Double(window))) : 0 }
    var percentage: Int { Int((fraction * 100).rounded()) }

    static func latest(messages: [Dieter_V1_UiMessage], fallbackWindow: Int64) -> ConversationContextUsage? {
        guard let metadata = messages.reversed().lazy.map(\.metadataJson).first(where: { !$0.isEmpty }) else {
            return nil
        }
        return ConversationContextUsageCache.value(metadata: metadata, fallbackWindow: fallbackWindow)
    }

    private static func integer(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        if let text = value as? String { return Int64(text) }
        return nil
    }
}

private enum ConversationContextUsageCache {
    private final class Box: NSObject {
        let value: ConversationContextUsage?
        init(_ value: ConversationContextUsage?) { self.value = value }
    }

    private final class Cache: @unchecked Sendable {
        let values: NSCache<NSString, Box> = {
            let cache = NSCache<NSString, Box>()
            cache.countLimit = 128
            return cache
        }()
    }

    private static let cache = Cache()

    static func value(metadata: Data, fallbackWindow: Int64) -> ConversationContextUsage? {
        let key = "\(fallbackWindow):\(metadata.base64EncodedString())" as NSString
        if let cached = cache.values.object(forKey: key) { return cached.value }
        guard let root = try? JSONSerialization.jsonObject(with: metadata) as? [String: Any] else {
            cache.values.setObject(Box(nil), forKey: key)
            return nil
        }
        let usage = root["usage"] as? [String: Any]
        let used = integer(usage?["totalTokens"]) ?? integer(usage?["inputTokens"])
        let window = integer(root["contextWindowTokens"]) ?? (fallbackWindow > 0 ? fallbackWindow : nil)
        let result = used.flatMap { used in
            window.flatMap { $0 > 0 ? ConversationContextUsage(used: used, window: $0) : nil }
        }
        cache.values.setObject(Box(result), forKey: key)
        return result
    }

    private static func integer(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        if let text = value as? String { return Int64(text) }
        return nil
    }
}

private struct ContextUsageIndicator: View {
    let usage: ConversationContextUsage

    var body: some View {
        ZStack {
            Circle().stroke(DieterTheme.raised, lineWidth: 3)
            Circle().trim(from: 0, to: usage.fraction)
                .stroke(usage.fraction > 0.85 ? DieterTheme.amber : DieterTheme.shell, style: .init(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(usage.percentage)").font(.system(size: 8, weight: .bold, design: .rounded)).foregroundStyle(DieterTheme.subtle)
        }
        .frame(width: 28, height: 28)
        .help("Context used: \(compact(usage.used)) of \(compact(usage.window)) tokens (\(usage.percentage)%)")
        .accessibilityLabel("Context used \(usage.percentage) percent")
    }

    private func compact(_ value: Int64) -> String {
        value >= 1_000_000 ? String(format: "%.1fM", Double(value) / 1_000_000) : value >= 1_000 ? "\(value / 1_000)k" : "\(value)"
    }
}
