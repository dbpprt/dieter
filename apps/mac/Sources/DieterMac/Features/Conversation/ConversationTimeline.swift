import AppKit
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
        // A row can gain structured details (for example, a task plan) after
        // its message has already been laid out. Preserve the available width
        // while forcing SwiftUI to publish the row's complete updated height,
        // so neither the message nor its details can paint into the next row.
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .smokeTarget("conversation.message.row.\(item.messages.last?.id ?? item.id)")
    }
}

struct ConversationTimeline: View {
    @Environment(ConversationContext.self) private var context
    // The native sidebar supplies its own adaptive glass behind the transcript.
    var background: Color = DieterTheme.background
    @State private var historyLoadInFlight = false
    @State private var loadingEarlier = true
    @State private var contentCanScroll = true
    @State private var blockedHistoryEdge: Bool?
    @State private var restoringOffset: CGFloat?
    @State private var isAtRenderedEnd = true
    @State private var userScrollInProgress = false
    @State private var viewportMode = ConversationViewportMode.awaitingInitial(conversationID: "")
    @State private var presentedFailureLog: String?
    @State private var retryingFailureLog: String?
    @State private var projection = ConversationTimelineProjection.empty
    @State private var projectionConversationID = ""
    @State private var renderWindowPosition = ConversationRenderWindow.Position.latest
    @State private var pendingWindowAnchor: ConversationScrollAnchorController.Anchor?
    @State private var scrollAnchors = ConversationScrollAnchorController()
    @State private var windowChangeInFlight = false
    @State private var historyRequestID: UUID?
    @State private var tailScrollRequest = 0
    @State private var jumpToLatestHovered = false

    private var messages: [Dieter_V1_UiMessage] { context.conversationMessages }
    private var liveMessages: [Dieter_V1_UiMessage] { context.liveActivityMessages }
    private var plans: [Dieter_V1_TaskPlan] { context.conversation?.conversation.taskPlans ?? [] }
    private var subagents: [Dieter_V1_Subagent] { context.conversation?.conversation.subagents ?? [] }
    private var queuedMessages: [Dieter_V1_QueuedMessage] {
        context.model.browsingEarlierHistory ? [] : context.conversation?.conversation.queue ?? []
    }
    private var timelineGroups: [ConversationTimelineDisplayGroup] { projection.displayGroups }
    private var renderRange: Range<Int> {
        ConversationRenderWindow.range(messages: messages, position: renderWindowPosition)
    }
    private var isAtLatest: Bool {
        isAtRenderedEnd && renderRange.upperBound == messages.count && !context.model.browsingEarlierHistory
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
                    if projectionConversationID != conversationID && !messages.isEmpty {
                        LoadFeedback(title: "Preparing conversation…", compact: true)
                            .accessibilityIdentifier("conversation.preparing")
                    }
                    if renderRange.lowerBound > 0 || context.conversationHistoryHasMore {
                        historyEdge(loading: historyLoadInFlight && loadingEarlier, earlier: true)
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
                                && group.id == timelineGroups.last?.id,
                            scrollAnchors: scrollAnchors
                        )
                        .id(group.id)
                        .background {
                            ConversationScrollAnchorProbe(
                                controller: scrollAnchors,
                                messageIDs: group.rows.flatMap(\.item.messages).map(\.id))
                        }
                    }

                    ForEach(projection.unattachedPlans, id: \.id) {
                        TaskPlanView(plan: $0)
                    }

                    if !pendingTools.isEmpty {
                        PendingToolGroupView(tools: pendingTools)
                    }
                    if agentIsWorking {
                        ConversationAgentWorkingIndicator(
                            label: ConversationActivityPresentation.liveLabel(
                                messages: liveMessages, pendingTools: pendingTools, plans: plans,
                                showReasoning: context.showReasoning,
                                conversationStatus: context.conversation?.conversation.status ?? "",
                                cardRuntime: (context.selectedCard ?? context.selectedDetail?.card)?.runtime ?? ""),
                            startedAt: ConversationActivityPresentation.turnStart(
                                messages: liveMessages,
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
                    if renderRange.upperBound < messages.count || context.model.browsingEarlierHistory {
                        historyEdge(loading: historyLoadInFlight && !loadingEarlier, earlier: false)
                    }
                    Color.clear.frame(height: 17).id(ConversationScrollBehavior.bottomID)
                }
                .padding(.horizontal, 18).padding(.top, 17)
            }
            // Growing messages must not move the reading position after a user
            // scrolls away. Live following is driven explicitly by tail requests.
            .defaultScrollAnchor(.top, for: .sizeChanges)
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            .textSelection(.enabled)
            .background(background)
            .background {
                ConversationScrollIntentProbe(controller: scrollAnchors, onScrollIntent: handleUserScrollIntent)
            }
            .smokeTarget("conversation.viewport")
            .onScrollGeometryChange(for: ConversationScrollSample.self) { geometry in
                ConversationScrollSample(geometry)
            } action: { previous, current in
                isAtRenderedEnd = current.atEnd
                contentCanScroll = current.canScroll
                if let restoringOffset {
                    if abs(current.offset - restoringOffset) < 2 { self.restoringOffset = nil }
                    return
                }
                guard !windowChangeInFlight, !historyLoadInFlight else { return }
                if userScrollInProgress {
                    updateViewportAfterUserScroll()
                    if current.offset < previous.offset, current.nearStart {
                        showEarlierMessages()
                    } else if current.offset > previous.offset, current.nearEnd {
                        showLaterMessages()
                    }
                } else if !current.atEnd, ConversationScrollBehavior.followsLatest(viewportMode) {
                    requestTailScroll()
                }
            }
            .onScrollPhaseChange { oldPhase, newPhase in
                let wasUserDriven = ConversationScrollBehavior.isUserDriven(oldPhase)
                let isUserDriven = ConversationScrollBehavior.isUserDriven(newPhase)
                userScrollInProgress = isUserDriven
                if !isUserDriven || !wasUserDriven { restoringOffset = nil }
                guard !windowChangeInFlight, !historyLoadInFlight else { return }
                if isUserDriven, !isAtLatest {
                    updateViewportAfterUserScroll()
                } else if wasUserDriven, !isUserDriven {
                    updateViewportAfterUserScroll()
                }
            }
            .overlay(alignment: .bottom) {
                if showsJumpToLatest {
                    Button {
                        returnToLatest()
                        scrollToLatest(proxy)
                        requestTailScroll()
                    } label: {
                        Label("Jump to latest", systemImage: "arrow.down")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 13)
                            .frame(height: 34)
                            .glassEffect(.regular.interactive(), in: Capsule())
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
                windowChangeInFlight = false
                historyRequestID = nil
                blockedHistoryEdge = nil
                restoringOffset = nil
                contentCanScroll = true
                projection = .empty
                projectionConversationID = ""
                viewportMode = .awaitingInitial(conversationID: selectedID)
                isAtRenderedEnd = false
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
                if windowChangeInFlight {
                    let anchor = pendingWindowAnchor
                    renderWindowPosition = renderWindowPosition.afterUserScroll(
                        isAtLatest: false, renderedRange: range)
                    await Task.yield()
                    guard key == projectionKey, key.conversationID == conversationID else { return }
                    if let anchor, scrollAnchors.restore(anchor) {
                        restoringOffset = scrollAnchors.lastRestoredOffset
                    }
                    await Task.yield()
                    guard key == projectionKey, key.conversationID == conversationID else { return }
                    pendingWindowAnchor = nil
                    windowChangeInFlight = false
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
        proxy.scrollTo(ConversationScrollBehavior.bottomID, anchor: .bottom)
    }

    private func updateViewportAfterUserScroll() {
        guard !windowChangeInFlight, !historyLoadInFlight else { return }
        if isAtLatest {
            returnToLatest()
            return
        }
        viewportMode = ConversationScrollBehavior.afterUserScroll(isAtLatest: isAtLatest)
        renderWindowPosition = renderWindowPosition.afterUserScroll(
            isAtLatest: isAtLatest, renderedRange: renderRange)
    }

    private func requestTailScroll() {
        tailScrollRequest &+= 1
    }

    private func returnToLatest() {
        historyRequestID = nil
        historyLoadInFlight = false
        blockedHistoryEdge = nil
        restoringOffset = nil
        pendingWindowAnchor = nil
        windowChangeInFlight = false
        viewportMode = .followingLatest
        renderWindowPosition = .latest
        // Release pages collected during scrollback and rejoin the live window,
        // including after the bounded history cache has evicted its newer end.
        context.model.returnToLatest()
        requestTailScroll()
    }

    private func historyEdge(loading: Bool, earlier: Bool) -> some View {
        HStack(spacing: 8) {
            if loading {
                ProgressView().controlSize(.small)
                Text(earlier ? "Loading earlier messages…" : "Loading later messages…")
                    .font(.caption).foregroundStyle(DieterTheme.tertiary)
            } else if !contentCanScroll || blockedHistoryEdge == earlier {
                // A collapsed activity group or hidden reasoning may not be
                // tall enough to scroll. Keep that history reachable as well.
                Button(earlier ? "Load earlier messages" : "Load later messages") {
                    if earlier {
                        showEarlierMessages(preservingPosition: false)
                    } else {
                        showLaterMessages(preservingPosition: false)
                    }
                }
                .buttonStyle(.borderless).font(.caption)
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity).frame(height: 18)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(earlier ? "conversation.history.earlier" : "conversation.history.later")
        .smokeTarget(earlier ? "conversation.history.earlier" : "conversation.history.later")
        .accessibilityLabel(earlier ? "Earlier conversation history" : "Later conversation history")
        .accessibilityAction(named: earlier ? "Load earlier messages" : "Load later messages") {
            if earlier {
                showEarlierMessages(preservingPosition: false)
            } else {
                showLaterMessages(preservingPosition: false)
            }
        }
    }

    private func handleUserScrollIntent(_ delta: CGFloat) {
        guard !windowChangeInFlight, !historyLoadInFlight else { return }
        let earlier = delta > 0
        guard scrollAnchors.isAtEdge(earlier: earlier) else { return }
        restoringOffset = nil
        if earlier {
            showEarlierMessages()
        } else if renderRange.upperBound == messages.count, !context.model.browsingEarlierHistory {
            returnToLatest()
        } else {
            showLaterMessages()
        }
    }

    private func showEarlierMessages(preservingPosition: Bool = true) {
        guard !windowChangeInFlight, !historyLoadInFlight else { return }
        if renderRange.lowerBound == 0 {
            if context.conversationHistoryHasMore { loadHistory(earlier: true) }
            return
        }
        moveRenderWindow(earlier: true, preservingPosition: preservingPosition)
    }

    private func showLaterMessages(preservingPosition: Bool = true) {
        guard !windowChangeInFlight, !historyLoadInFlight else { return }
        if renderRange.upperBound == messages.count {
            if context.model.browsingEarlierHistory { loadHistory(earlier: false) }
            return
        }
        moveRenderWindow(earlier: false, preservingPosition: preservingPosition)
    }

    private func moveRenderWindow(earlier: Bool, preservingPosition: Bool) {
        let anchor = preservingPosition ? scrollAnchors.capture(preferBottom: !earlier) : nil
        let fallback = earlier ? renderRange.lowerBound : max(renderRange.lowerBound, renderRange.upperBound - 1)
        let index = fallback
        let next: ConversationRenderWindow.Position = earlier ? .pagingEarlier(from: index) : .pagingLater(from: index)
        let nextRange = ConversationRenderWindow.range(messages: messages, position: next)
        guard earlier ? nextRange.lowerBound < renderRange.lowerBound : nextRange.upperBound > renderRange.upperBound
        else { return }
        if let anchor, !messages[nextRange].contains(where: { $0.id == anchor.messageID }) {
            // Wait until the reader reaches the retained overlap instead of
            // evicting a partly visible oversized message. A fallback remains
            // available when hidden messages make that overlap unreachable.
            blockedHistoryEdge = earlier
            return
        }
        blockedHistoryEdge = nil
        viewportMode = .detached
        pendingWindowAnchor = anchor
        windowChangeInFlight = true
        renderWindowPosition = next
    }

    private func loadHistory(earlier: Bool) {
        guard !historyLoadInFlight, !windowChangeInFlight else { return }
        let requestID = UUID()
        historyRequestID = requestID
        historyLoadInFlight = true
        loadingEarlier = earlier
        blockedHistoryEdge = nil
        viewportMode = .detached
        let selectedID = conversationID
        let anchor = scrollAnchors.capture(preferBottom: !earlier)
        let fallbackID = earlier ? messages.first?.id : messages.last?.id
        Task { @MainActor in
            let loaded = earlier ? await context.loadEarlierMessages() : await context.model.loadLaterMessages()
            guard historyRequestID == requestID, selectedID == conversationID else { return }
            historyRequestID = nil
            if loaded {
                // The user may keep scrolling during the network request. The
                // old projection is still mounted here; retain its current
                // visible point rather than restoring the request's old offset.
                let anchor = scrollAnchors.capture(preferBottom: !earlier) ?? anchor
                let anchorID = anchor?.messageID ?? fallbackID
                let index = anchorID.flatMap { id in messages.firstIndex { $0.id == id } }
                pendingWindowAnchor = anchor
                windowChangeInFlight = true
                if let index {
                    renderWindowPosition = earlier ? .pagingEarlier(from: index) : .pagingLater(from: index)
                } else {
                    renderWindowPosition = earlier ? .startingAt(0) : .latest
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
