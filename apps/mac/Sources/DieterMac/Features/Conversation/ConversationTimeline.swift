import AppKit
import DieterAPI
import SwiftUI
import UniformTypeIdentifiers

private enum ConversationWindowAnchor: Equatable {
    case earlier(messageID: String)
    case later(messageID: String)

    var messageID: String {
        switch self {
        case .earlier(let messageID), .later(let messageID): messageID
        }
    }

    var edge: UnitPoint {
        switch self {
        case .earlier: .top
        case .later: .bottom
        }
    }
}

struct ConversationTimelineRow: View {
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
        // A row can gain structured details (for example, a task plan) after
        // its message has already been laid out. Preserve the available width
        // while forcing SwiftUI to publish the row's complete updated height,
        // so neither the message nor its details can paint into the next row.
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ConversationTimeline: View {
    @Environment(ConversationContext.self) private var context
    @State private var historyLoadInFlight = false
    @State private var isAtLatest = true
    @State private var userScrollInProgress = false
    @State private var viewportMode = ConversationViewportMode.awaitingInitial(conversationID: "")
    @State private var presentedFailureLog: String?
    @State private var retryingFailureLog: String?
    @State private var projection = ConversationTimelineProjection.empty
    @State private var projectionConversationID = ""
    @State private var renderWindowPosition = ConversationRenderWindow.Position.latest
    @State private var pendingWindowAnchor: ConversationWindowAnchor?
    @State private var tailScrollRequest = 0
    @State private var jumpToLatestHovered = false

    private var messages: [Dieter_V1_UiMessage] { context.conversationMessages }
    private var timelineItems: [ConversationTimelineItem] { projection.items }
    private var plans: [Dieter_V1_TaskPlan] { context.conversation?.conversation.taskPlans ?? [] }
    private var subagents: [Dieter_V1_Subagent] { context.conversation?.conversation.subagents ?? [] }
    private var queuedMessages: [Dieter_V1_QueuedMessage] {
        context.model.browsingEarlierHistory ? [] : context.conversation?.conversation.queue ?? []
    }
    private var timelineRows: [ConversationTimelineRowContent] { projection.rows }
    private var renderRange: Range<Int> {
        ConversationRenderWindow.range(messages: messages, position: renderWindowPosition)
    }
    private var projectionKey: ConversationPresentationKey {
        ConversationPresentationKey(
            conversationID: conversationID,
            revision: context.conversationPresentationRevision,
            showReasoning: context.showReasoning,
            renderStart: renderRange.lowerBound,
            renderCount: renderRange.count
        )
    }
    private var conversationID: String { context.selectedCardID ?? context.selectedChatID ?? "" }
    private var draftPrompt: String {
        let card = context.selectedCard ?? context.selectedDetail?.card
        return card?.initialPromptSentAt.isEmpty == true ? (card?.initialPrompt ?? "") : ""
    }
    private var draftAttachments: [Dieter_V1_MessagePart] {
        context.conversation?.conversation.draftAttachments ?? []
    }
    private var pendingTools: [Dieter_V1_PendingTool] {
        context.conversation?.conversation.pendingTools ?? []
    }
    private var agentIsWorking: Bool {
        let card = context.selectedCard ?? context.selectedDetail?.card
        return ConversationActivityPresentation.isActive(
            conversationStatus: context.conversation?.conversation.status ?? "",
            cardRuntime: card?.runtime ?? ""
        )
    }
    private var turnFailure: ConversationTurnFailure? {
        let card = context.selectedCard ?? context.selectedDetail?.card
        return ConversationTurnFailure.resolve(
            messages: messages,
            conversationStatus: context.conversation?.conversation.status ?? "",
            cardRuntime: card?.runtime ?? ""
        )
    }
    private var creationFailure: String? {
        context.failedCreationError(conversationID)
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
                    if context.model.browsingEarlierHistory {
                        HStack {
                            Text("Viewing earlier history")
                            Spacer()
                            Button("Return to latest") { context.model.returnToLatest() }
                        }
                        .font(.caption)
                        .accessibilityIdentifier("conversation.history-window")
                    }
                    if projectionConversationID != conversationID && !messages.isEmpty {
                        LoadFeedback(title: "Preparing conversation…", compact: true)
                            .accessibilityIdentifier("conversation.preparing")
                    }
                    if renderRange.lowerBound > 0 {
                        Button("Show earlier messages") {
                            showEarlierMessages()
                        }
                        .buttonStyle(.borderless)
                        .frame(maxWidth: .infinity)
                        .onScrollVisibilityChange(threshold: 0.8) { visible in
                            if visible, userScrollInProgress, viewportMode == .detached { showEarlierMessages() }
                        }
                    } else if context.conversationHistoryLoading {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Loading earlier messages…")
                                .font(.caption)
                                .foregroundStyle(DieterTheme.tertiary)
                        }
                        .frame(maxWidth: .infinity)
                        .id("conversation.history-loading")
                    } else if context.conversationHistoryHasMore {
                        Button(
                            "Load earlier messages · \(messages.count) of \(context.conversationHistoryTotal)"
                        ) {
                            loadEarlierHistory()
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(DieterTheme.tertiary)
                        .frame(maxWidth: .infinity)
                        .onScrollVisibilityChange(threshold: 0.8) { visible in
                            if visible, userScrollInProgress, viewportMode == .detached { loadEarlierHistory() }
                        }
                    }

                    if messages.isEmpty && !agentIsWorking {
                        EmptyConversationView(
                            standalone: context.selectedCard?.scope == "chat",
                            prompt: draftPrompt,
                            attachments: draftAttachments
                        )
                    }

                    ForEach(timelineRows) { row in
                        ConversationTimelineRow(item: row.item, details: row.details)
                            .id(row.id)
                    }

                    ForEach(projection.unattachedPlans, id: \.id) {
                        TaskPlanView(plan: $0)
                    }

                    if !pendingTools.isEmpty {
                        PendingToolGroupView(tools: pendingTools)
                    }
                    if agentIsWorking {
                        ConversationAgentWorkingIndicator(
                            label: ConversationActivityPresentation.liveLabel(pendingTools: pendingTools, plans: plans),
                            startedAt: ConversationActivityPresentation.turnStart(
                                messages: messages,
                                runtimeUpdatedAt: (context.selectedCard ?? context.selectedDetail?.card)?
                                    .runtimeUpdatedAt ?? "")
                        )
                        .id("conversation.agent-working")
                    }
                    if let creationFailure {
                        CreationFailureBanner(
                            failure: creationFailure,
                            onRetry: { Task { await context.retryOutboxItem(conversationID) } },
                            onDiscard: { Task { await context.discardOutboxItem(conversationID) } }
                        )
                        .id("conversation.creation-failure")
                    } else if let turnFailure {
                        TurnFailureBanner(
                            failure: turnFailure,
                            retrying: retryingFailureLog == turnFailure.log,
                            onViewLog: { presentedFailureLog = turnFailure.log },
                            onRetry: {
                                guard retryingFailureLog == nil else { return }
                                retryingFailureLog = turnFailure.log
                                Task { @MainActor in
                                    if !(await context.retryFailedTurn(turnFailure)) {
                                        retryingFailureLog = nil
                                    }
                                }
                            }
                        )
                        .id("conversation.turn-failure")
                    }
                    if renderRange.upperBound < messages.count {
                        Button("Show later messages") {
                            showLaterMessages()
                        }
                        .buttonStyle(.borderless)
                        .frame(maxWidth: .infinity)
                        .onScrollVisibilityChange(threshold: 0.8) { visible in
                            if visible, userScrollInProgress, viewportMode == .detached { showLaterMessages() }
                        }
                    }
                    Color.clear.frame(height: 17).id(ConversationScrollBehavior.bottomID)
                }
                .padding(.horizontal, 18).padding(.top, 17)
            }
            .textSelection(.enabled)
            .background(DieterTheme.background)
            .smokeTarget("conversation.viewport")
            .onScrollGeometryChange(for: Bool.self) { geometry in
                ConversationScrollBehavior.isAtLatest(
                    visibleMaxY: geometry.visibleRect.maxY,
                    contentHeight: geometry.contentSize.height,
                    renderedThroughLatest: renderRange.upperBound == messages.count
                        && !context.model.browsingEarlierHistory
                )
            } action: { _, atLatest in
                isAtLatest = atLatest
                if userScrollInProgress {
                    viewportMode = ConversationScrollBehavior.afterUserScroll(isAtLatest: atLatest)
                    if atLatest { renderWindowPosition = .latest }
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
                    .smokeTarget("conversation.jump-to-latest")
                    .onHover(perform: updateJumpToLatestCursor)
                    .onDisappear { updateJumpToLatestCursor(false) }
                }
            }
            .onChange(of: showsJumpToLatest) { _, visible in
                #if DIETER_UI_SMOKE
                    ConversationUISmokeRunner.recordJumpToLatestVisibility(visible, conversationID: conversationID)
                #endif
            }
            .onChange(of: viewportObservation, initial: true) { _, observation in
                #if DIETER_UI_SMOKE
                    ConversationUISmokeRunner.recordViewportObservation(
                        conversationID: observation.conversationID,
                        isAtLatest: observation.isAtLatest,
                        followsLatest: observation.followsLatest,
                        initialPositionComplete: observation.initialPositionComplete
                    )
                #endif
            }
            .onChange(of: turnFailure?.log) { _, log in
                if log == nil { retryingFailureLog = nil }
            }
            .onChange(of: conversationID, initial: true) { _, selectedID in
                renderWindowPosition = .latest
                pendingWindowAnchor = nil
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
                let showReasoning = context.showReasoning
                guard
                    let next = try? await BackgroundPreparation.run({
                        for message in source {
                            for part in message.parts where !part.text.isEmpty {
                                try Task.checkCancellation()
                                _ = try ConversationRenderCache.prepare(ConversationRenderCache.preview(part.text))
                            }
                        }
                        return ConversationTimelineProjection.build(
                            messages: source,
                            allMessageIDs: allMessageIDs,
                            plans: plans,
                            subagents: subagents,
                            queue: queue,
                            showReasoning: showReasoning
                        )
                    })
                else { return }
                guard !Task.isCancelled,
                    key == projectionKey,
                    key.conversationID == conversationID
                else { return }
                projection = next
                projectionConversationID = key.conversationID
                if let request = pendingWindowAnchor {
                    pendingWindowAnchor = nil
                    guard
                        let anchor = ConversationScrollBehavior.anchorItem(
                            containing: request.messageID,
                            in: next.items
                        )
                    else { return }
                    await Task.yield()
                    guard key == projectionKey, key.conversationID == conversationID else { return }
                    proxy.scrollTo(anchor, anchor: request.edge)
                }
                if ConversationScrollBehavior.followsLatest(viewportMode) {
                    requestTailScroll()
                }
            }
            .task(
                id: ConversationTailScrollKey(
                    conversationID: conversationID,
                    request: tailScrollRequest
                )
            ) {
                guard tailScrollRequest > 0,
                    projectionConversationID == conversationID,
                    ConversationScrollBehavior.followsLatest(viewportMode)
                else { return }
                await Task.yield()
                guard projectionConversationID == conversationID,
                    ConversationScrollBehavior.followsLatest(viewportMode),
                    !userScrollInProgress
                else { return }
                scrollToLatest(proxy)
                if viewportMode == .awaitingInitial(conversationID: conversationID) {
                    viewportMode = .followingLatest
                }
            }
        }
        .sheet(
            isPresented: Binding(
                get: { presentedFailureLog != nil },
                set: { if !$0 { presentedFailureLog = nil } }
            )
        ) {
            TurnFailureLogSheet(log: presentedFailureLog ?? "")
        }
    }

    private func scrollToLatest(_ proxy: ScrollViewProxy) {
        renderWindowPosition = .latest
        pendingWindowAnchor = nil
        proxy.scrollTo(ConversationScrollBehavior.bottomID, anchor: .bottom)
    }

    private func requestTailScroll() {
        tailScrollRequest &+= 1
    }

    private func showEarlierMessages() {
        guard pendingWindowAnchor == nil, !historyLoadInFlight,
            let anchorMessageID = timelineItems.first?.messages.first?.id,
            let anchorIndex = messages.firstIndex(where: { $0.id == anchorMessageID })
        else { return }
        let nextPosition = ConversationRenderWindow.Position.pagingEarlier(from: anchorIndex)
        guard ConversationRenderWindow.range(messages: messages, position: nextPosition) != renderRange else { return }
        viewportMode = .detached
        pendingWindowAnchor = .earlier(messageID: anchorMessageID)
        renderWindowPosition = nextPosition
    }

    private func showLaterMessages() {
        guard pendingWindowAnchor == nil, !historyLoadInFlight,
            let anchorMessageID = timelineItems.last?.messages.last?.id,
            let anchorIndex = messages.firstIndex(where: { $0.id == anchorMessageID })
        else { return }
        let nextPosition = ConversationRenderWindow.Position.pagingLater(from: anchorIndex)
        guard ConversationRenderWindow.range(messages: messages, position: nextPosition) != renderRange else { return }
        viewportMode = .detached
        pendingWindowAnchor = .later(messageID: anchorMessageID)
        renderWindowPosition = nextPosition
    }

    private func loadEarlierHistory() {
        guard !historyLoadInFlight, pendingWindowAnchor == nil else { return }
        historyLoadInFlight = true
        viewportMode = .detached
        // Anchor by message id, not timeline-item id: prepending a page can
        // merge the current first item into a differently-identified tool
        // group, and a missed scroll restore leaves the viewport at offset
        // zero, which would chain-load the entire history.
        let anchorMessageID = timelineItems.first?.messages.first?.id
        Task { @MainActor in
            let loaded = await context.loadEarlierMessages()
            if loaded {
                if let anchorMessageID,
                    let anchorIndex = messages.firstIndex(where: { $0.id == anchorMessageID })
                {
                    pendingWindowAnchor = .earlier(messageID: anchorMessageID)
                    renderWindowPosition = .pagingEarlier(from: anchorIndex)
                } else {
                    renderWindowPosition = .startingAt(0)
                }
            }
            historyLoadInFlight = false
        }
    }

    private func updateJumpToLatestCursor(_ hovering: Bool) {
        guard jumpToLatestHovered != hovering else { return }
        jumpToLatestHovered = hovering
        if hovering {
            NSCursor.pointingHand.push()
        } else {
            NSCursor.pop()
        }
    }
}
