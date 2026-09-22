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
    // Optional instrumentation for isolated native scroll regression fixtures.
    var onTailScroll: (() -> Void)?
    var onViewportObservation: ((ConversationViewportObservation) -> Void)?
    @State private var historyLoadInFlight = false
    @State private var loadingEarlier = true
    @State private var historyRequestID: UUID?
    @State private var contentCanScroll = true
    @State private var viewportMode = ConversationViewportMode.awaitingInitial(conversationID: "")
    @State private var presentedFailureLog: String?
    @State private var retryingFailureLog: String?
    // The mounted rows and the window they were built from change together.
    // Everything that affects layout reads these, never the requested window,
    // so nothing moves before the scroll controller holds the reading position.
    @State private var projection = ConversationTimelineProjection.empty
    @State private var projectionConversationID = ""
    @State private var renderedPosition = ConversationRenderWindow.Position.latest
    @State private var renderedHasEarlier = false
    @State private var renderedThroughLatest = true
    @State private var windowPosition = ConversationRenderWindow.Position.latest
    @State private var latestMessageLimit = ConversationRenderWindow.initialMessages
    @State private var scroller = ConversationScrollController()
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
        ConversationRenderWindow.range(
            messages: messages, position: windowPosition, latestMessageLimit: latestMessageLimit)
    }
    private var windowChangePending: Bool { renderedPosition != windowPosition }
    private var isAtLatest: Bool {
        viewportMode == .followingLatest && renderedThroughLatest && !context.model.browsingEarlierHistory
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
    private var timelineReadyForDisplay: Bool {
        ConversationTimelinePresentation.isReady(
            messageCount: messages.count,
            conversationID: conversationID,
            projectionConversationID: projectionConversationID,
            viewportMode: viewportMode
        )
    }
    private var viewportObservation: ConversationViewportObservation {
        ConversationViewportObservation(
            conversationID: conversationID,
            isAtLatest: isAtLatest,
            followsLatest: ConversationScrollBehavior.followsLatest(viewportMode),
            initialPositionComplete: ConversationScrollBehavior.initialPositionComplete(viewportMode)
        )
    }

    var body: some View {
        // The parent split and composer inset ask for minimum and ideal sizes
        // before allocating this viewport. The transcript must not answer those
        // probes by laying out every rich row at each speculative size.
        GeometryReader { _ in timeline }
    }

    private var timeline: some View {
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
                // Always mounted at a fixed height: the last older page
                // arriving must not shift the rows underneath the reader.
                historyEdge(
                    loading: historyLoadInFlight && loadingEarlier, earlier: true,
                    available: renderedHasEarlier || context.conversationHistoryHasMore)

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
                        isLatest: renderedThroughLatest && group.id == timelineGroups.last?.id,
                        scrollAnchors: scroller
                    )
                    .id(group.id)
                    .background {
                        ConversationScrollAnchorProbe(
                            controller: scroller,
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
                if !renderedThroughLatest {
                    historyEdge(loading: historyLoadInFlight && !loadingEarlier, earlier: false, available: true)
                }
                Color.clear.frame(height: 17).id(ConversationScrollBehavior.bottomID)
                    // Keeps the controller attached while no message rows exist.
                    .background { ConversationScrollAnchorProbe(controller: scroller, messageIDs: []) }
            }
            .padding(.horizontal, 18).padding(.top, 8)
            // The first projection is laid out at the scroll view's default
            // origin before the controller pins it to the tail. Keep that
            // intermediate frame mounted for layout but invisible.
            .opacity(timelineReadyForDisplay ? 1 : 0)
            .accessibilityHidden(!timelineReadyForDisplay)
            .allowsHitTesting(timelineReadyForDisplay)
        }
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        // Growing messages must not move the reading position after a user
        // scrolls away. Live following is owned by the scroll controller.
        .defaultScrollAnchor(.top, for: .sizeChanges)
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        .textSelection(.enabled)
        .background(background)
        .background {
            ConversationScrollBridge(
                controller: scroller,
                rendersLatest: renderedThroughLatest,
                onFollowingChange: handleFollowingChange,
                onUserScroll: handleUserScroll,
                onScrollableChange: { contentCanScroll = $0 },
                onScrollIntent: handleUserScrollIntent,
                onTailCorrection: onTailScroll)
        }
        .smokeTarget("conversation.viewport")
        .overlay(alignment: .bottom) {
            if showsJumpToLatest {
                Button {
                    returnToLatest()
                } label: {
                    Label("Jump to latest", systemImage: "arrow.down")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 13)
                        .frame(height: 34)
                        .dieterGlass(.regular.interactive(), in: Capsule())
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
        .onChange(of: timelineReadyForDisplay, initial: true) { _, ready in
            BoardRenderingDiagnostics.recordConversationReady(conversationID, ready: ready)
        }
        .onChange(of: viewportObservation, initial: true) { _, observation in
            onViewportObservation?(observation)
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
            latestMessageLimit = ConversationRenderWindow.initialMessages
            windowPosition = .latest
            renderedPosition = .latest
            renderedHasEarlier = false
            renderedThroughLatest = true
            historyLoadInFlight = false
            historyRequestID = nil
            contentCanScroll = true
            projection = .empty
            projectionConversationID = ""
            viewportMode = .awaitingInitial(conversationID: selectedID)
            scroller.reset()
            scroller.beginInitialPositioning()
        }
        .task(id: projectionKey) {
            let key = projectionKey
            let range = renderRange
            let source = Array(messages[range])
            let allMessageIDs = Set(messages.lazy.map(\.id).filter { !$0.isEmpty })
            let throughLatest = range.upperBound == messages.count && !context.model.browsingEarlierHistory
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
            guard !Task.isCancelled, key == projectionKey, key.conversationID == conversationID else { return }
            // The old rows are still mounted and the user may have kept
            // scrolling during preparation: hold where the reader is now.
            scroller.holdReadingPosition()
            scroller.rendersLatest = throughLatest
            projection = next
            projectionConversationID = key.conversationID
            renderedPosition = windowPosition
            renderedHasEarlier = range.lowerBound > 0
            renderedThroughLatest = throughLatest
            guard viewportMode == .awaitingInitial(conversationID: key.conversationID) else { return }
            if source.isEmpty {
                scroller.finishInitialPositioning()
                viewportMode = .followingLatest
                return
            }
            // Reveal the transcript once its first layout is pinned to the tail.
            for _ in 0..<20 {
                // Yield an actual run-loop pass so AppKit can place the rows;
                // a sequence of executor yields can all precede native layout.
                try? await Task.sleep(for: .milliseconds(5))
                guard !Task.isCancelled else { return }
                guard viewportMode == .awaitingInitial(conversationID: key.conversationID) else { return }
                if let lastID = source.last?.id, scroller.hasLaidOutMessage(lastID),
                    scroller.isAtEdge(earlier: false)
                {
                    break
                }
            }
            // Do not leave a short-message conversation with a half-empty
            // viewport merely to meet a row budget. Grow only when the actual
            // laid-out tail does not fill it, retaining the text/part limits.
            if let lastID = source.last?.id, scroller.hasLaidOutMessage(lastID),
                !scroller.contentCanScroll, range.lowerBound > 0, windowPosition == .latest
            {
                let limit = min(ConversationRenderWindow.maximumMessages, latestMessageLimit * 2)
                let expanded = ConversationRenderWindow.range(
                    messages: messages, position: .latest, latestMessageLimit: limit)
                if expanded != range {
                    latestMessageLimit = limit
                    return
                }
            }
            scroller.finishInitialPositioning()
            viewportMode = scroller.isFollowing ? .followingLatest : .detached
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

    private func handleFollowingChange(_ following: Bool) {
        if following {
            returnToLatest()
        } else {
            guard ConversationScrollBehavior.initialPositionComplete(viewportMode) else { return }
            viewportMode = .detached
            // Freeze the rendered start so appends cannot evict the text being read.
            setWindowPosition(
                ConversationRenderWindow.detached(
                    from: windowPosition, messages: messages, renderedRange: renderRange))
        }
    }

    private func handleUserScroll(_ proximity: ConversationScrollController.EdgeProximity) {
        if proximity.movedEarlier, proximity.nearStart {
            showEarlierMessages()
        } else if !proximity.movedEarlier, proximity.nearEnd {
            showLaterMessages()
        }
    }

    private func handleUserScrollIntent(_ delta: CGFloat) {
        let earlier = delta > 0
        // The native monitor runs before AppKit moves the clip view. Relinquish
        // the tail now, before content streaming in can undo this gesture.
        if earlier, scroller.contentCanScroll { scroller.detach() }
        // A clamped edge produces no movement to observe; act on intent.
        guard scroller.isAtEdge(earlier: earlier) else { return }
        if earlier {
            showEarlierMessages()
        } else if renderedThroughLatest {
            scroller.follow()
        } else {
            showLaterMessages()
        }
    }

    private func returnToLatest() {
        historyRequestID = nil
        historyLoadInFlight = false
        viewportMode = .followingLatest
        setWindowPosition(.latest)
        scroller.follow()
        // Release pages collected during scrollback and rejoin the live window,
        // including after the bounded history cache has evicted its newer end.
        if context.model.browsingEarlierHistory || !context.model.olderConversationMessages.isEmpty {
            context.model.returnToLatest()
        }
    }

    private func historyEdge(loading: Bool, earlier: Bool, available: Bool) -> some View {
        HStack(spacing: 8) {
            if !available {
                Color.clear
            } else if loading {
                ProgressView().controlSize(.small)
                Text(earlier ? "Loading earlier messages…" : "Loading later messages…")
                    .font(.caption).foregroundStyle(DieterTheme.tertiary)
            } else {
                // Scrolling loads history well before this edge is reached.
                // The button keeps it reachable when the transcript is too
                // short to scroll or a request failed.
                Button(earlier ? "Load earlier messages" : "Load later messages") {
                    if earlier { showEarlierMessages() } else { showLaterMessages() }
                }
                .buttonStyle(.borderless).font(.caption)
            }
        }
        .frame(maxWidth: .infinity).frame(height: 18)
        .accessibilityElement(children: .combine)
        .accessibilityHidden(!available)
        .accessibilityIdentifier(earlier ? "conversation.history.earlier" : "conversation.history.later")
        .smokeTarget(earlier ? "conversation.history.earlier" : "conversation.history.later")
        .accessibilityLabel(earlier ? "Earlier conversation history" : "Later conversation history")
        .accessibilityAction(named: earlier ? "Load earlier messages" : "Load later messages") {
            if earlier { showEarlierMessages() } else { showLaterMessages() }
        }
    }

    private func showEarlierMessages() {
        guard !windowChangePending, !historyLoadInFlight, projectionConversationID == conversationID else { return }
        if let next = ConversationRenderWindow.extendingEarlier(messages: messages, renderedRange: renderRange) {
            leaveLatest()
            setWindowPosition(next)
        } else if context.conversationHistoryHasMore {
            loadHistory(earlier: true)
        }
    }

    private func showLaterMessages() {
        guard !windowChangePending, !historyLoadInFlight, projectionConversationID == conversationID else { return }
        if let next = ConversationRenderWindow.extendingLater(messages: messages, renderedRange: renderRange) {
            setWindowPosition(next)
        } else if context.model.browsingEarlierHistory {
            loadHistory(earlier: false)
        }
    }

    /// A request that leaves the rendered range unchanged has nothing to
    /// build, so it is already rendered; otherwise the projection task lands it.
    private func setWindowPosition(_ next: ConversationRenderWindow.Position) {
        guard next != windowPosition else { return }
        let unchanged =
            !windowChangePending
            && ConversationRenderWindow.range(messages: messages, position: next) == renderRange
        windowPosition = next
        if unchanged { renderedPosition = next }
    }

    private func leaveLatest() {
        scroller.detach()
        if ConversationScrollBehavior.initialPositionComplete(viewportMode) { viewportMode = .detached }
    }

    private func loadHistory(earlier: Bool) {
        let requestID = UUID()
        historyRequestID = requestID
        historyLoadInFlight = true
        loadingEarlier = earlier
        leaveLatest()
        let selectedID = conversationID
        Task { @MainActor in
            let loaded = earlier ? await context.loadEarlierMessages() : await context.model.loadLaterMessages()
            guard historyRequestID == requestID, selectedID == conversationID else { return }
            historyRequestID = nil
            historyLoadInFlight = false
            guard loaded else { return }
            // Message identities keep the window where the reader is while
            // the loaded page shifts every index; mount one more page of it.
            let next =
                earlier
                ? ConversationRenderWindow.extendingEarlier(messages: messages, renderedRange: renderRange)
                : ConversationRenderWindow.extendingLater(messages: messages, renderedRange: renderRange)
            if let next { setWindowPosition(next) }
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
