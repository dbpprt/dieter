import DieterAPI
import SwiftUI
import UniformTypeIdentifiers

struct ConversationTimelineRow: View {
    @Environment(ConversationContext.self) private var context
    let item: ConversationTimelineItem
    let details: [ConversationTimelineMessageDetails]
    var isLatest = false
    var expandedActivity = false
    @State private var isHovered = false

    private var footer: MessageFooterContent { MessageFooterContent(messages: item.messages) }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            VStack(alignment: .leading, spacing: 15) {
                if item.isToolCallGroup {
                    ConversationActivityPartsView(
                        steps: ConversationActivityStep.steps(
                            messages: item.messages, showReasoning: context.showReasoning),
                        expandedActivity: expandedActivity)
                } else if let message = item.messages.first {
                    MessageView(message: message, expandedActivity: expandedActivity)
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
            MessageFooter(
                content: footer, messageID: item.messages.last?.id ?? item.id,
                isLatest: isLatest, isHovered: isHovered
            )
            .frame(
                maxWidth: .infinity,
                alignment: item.messages.first?.role == "user" ? .trailing : .leading)
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityActions {
            if !footer.markdown.isEmpty {
                Button("Copy message") { footer.copy() }
            }
        }
        .smokeTarget("conversation.message.row.\(item.messages.last?.id ?? item.id)")
    }
}

struct ConversationTimeline: View {
    @Environment(ConversationContext.self) private var context
    // The native sidebar supplies its own adaptive glass behind the transcript.
    var background: Color = DieterTheme.background
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

    private var messages: [Dieter_V1_UiMessage] { context.conversationMessages }
    private var timelineItems: [ConversationTimelineItem] { projection.items }
    private var plans: [Dieter_V1_TaskPlan] { context.conversation?.conversation.taskPlans ?? [] }
    private var subagents: [Dieter_V1_Subagent] { context.conversation?.conversation.subagents ?? [] }
    private var queuedMessages: [Dieter_V1_QueuedMessage] {
        context.model.browsingEarlierHistory ? [] : context.conversation?.conversation.queue ?? []
    }
    private var timelineGroups: [ConversationTimelineDisplayGroup] { projection.displayGroups }
    private var renderRange: Range<Int> {
        ConversationRenderWindow.range(messages: messages, requestedStart: renderWindowStart)
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
                            viewportMode = .detached
                            renderWindowStart = max(0, renderRange.lowerBound - 30)
                        }.buttonStyle(.borderless).frame(maxWidth: .infinity)
                    }
                    if context.conversationHistoryLoading {
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
                            loadEarlierHistory(proxy: proxy)
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(DieterTheme.tertiary)
                        .frame(maxWidth: .infinity)
                    }

                    if messages.isEmpty && !agentIsWorking {
                        EmptyConversationView(
                            standalone: context.selectedCard?.scope == "chat",
                            prompt: draftPrompt,
                            attachments: draftAttachments
                        )
                    }

                    ForEach(timelineGroups) { group in
                        ConversationTimelineDisplayGroupView(
                            group: group, showReasoning: context.showReasoning,
                            isLatest: !context.model.browsingEarlierHistory && renderRange.upperBound == messages.count
                                && group.id == timelineGroups.last?.id
                        )
                        .id(group.id)
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
                            viewportMode = .detached
                            renderWindowStart = renderRange.upperBound
                        }.buttonStyle(.borderless).frame(maxWidth: .infinity)
                    }
                    Color.clear.frame(height: 17).id(ConversationScrollBehavior.bottomID)
                }
                .padding(.horizontal, 18).padding(.top, 17)
            }
            .textSelection(.enabled)
            .background(background)
            .smokeTarget("conversation.viewport")
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
                    .smokeTarget("conversation.jump-to-latest")
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
            let loaded = await context.loadEarlierMessages()
            if loaded {
                if let anchorMessageID,
                    let anchorIndex = messages.firstIndex(where: { $0.id == anchorMessageID })
                {
                    renderWindowStart = max(0, anchorIndex - 30)
                } else {
                    renderWindowStart = 0
                }
                await Task.yield()
                let range = renderRange
                let items = ConversationTimelineItem.group(
                    Array(messages[range]),
                    showReasoning: context.showReasoning
                )
                if let anchor = ConversationScrollBehavior.anchorItem(
                    containing: anchorMessageID, in: items)
                {
                    proxy.scrollTo(anchor, anchor: .top)
                }
            }
            historyLoadInFlight = false
        }
    }
}
