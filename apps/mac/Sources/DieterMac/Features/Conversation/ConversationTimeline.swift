import AppKit
import DieterAPI
import SwiftUI
import UniformTypeIdentifiers

struct ConversationTimeline: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(ConversationContext.self) private var context
    // The native sidebar supplies its own adaptive glass behind the transcript.
    var background: Color = .clear
    // Optional instrumentation for isolated native scroll regression fixtures.
    var onTailScroll: (() -> Void)?
    var onViewportObservation: ((ConversationViewportObservation) -> Void)?
    @State private var historyLoadInFlight = false
    @State private var loadingEarlier = true
    @State private var historyRequestID: UUID?
    @State private var contentCanScroll = true
    @State private var viewportMode = ConversationViewportMode.awaitingInitial(conversationID: "")
    @State private var presentedFailureLog: String?
    /// The retry just clicked, so a second click cannot send it twice.
    @State private var retryClicked = false
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

    private struct ResponseReadKey: Hashable {
        let cardID: String
        let responseSeq: Int64
        let seenSeq: Int64
        let visible: Bool
    }

    private var responseReadKey: ResponseReadKey {
        let card = context.conversation?.detail.card
        let loaded = (context.conversation?.conversation.lastSeq ?? 0) >= (card?.responseSeq ?? 0)
        return ResponseReadKey(
            cardID: card?.id ?? "", responseSeq: card?.responseSeq ?? 0,
            seenSeq: card?.seenResponseSeq ?? 0,
            visible: loaded && scenePhase == .active && timelineReadyForDisplay
                && viewportObservation.isAtLatest && viewportObservation.initialPositionComplete)
    }

    private func acknowledgeVisibleResponse() async {
        guard responseReadKey.visible else { return }
        // A transient mount during navigation is not a viewed reply.
        do { try await DieterTaskSleep.milliseconds(200) } catch { return }
        await context.model.markResponseSeen()
    }

    private var messages: [Dieter_V1_UiMessage] { context.conversationMessages }
    private var timelineRows: [ClientTimelineItem] { projection.rows }
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
            renderStart: renderRange.lowerBound,
            renderCount: renderRange.count
        )
    }
    private var conversationID: String { context.selectedCardID ?? context.selectedChatID ?? "" }
    private var state: ClientConversationState { context.model.state }
    private var unsentAttachments: [Dieter_V1_MessagePart] {
        state.unsentAttachments ? context.conversation?.conversation.draftAttachments ?? [] : []
    }
    private var pendingTools: [Dieter_V1_PendingTool] {
        let tools = context.conversation?.conversation.pendingTools ?? []
        return state.pendingToolIds.compactMap { id in tools.first { $0.id == id } }
    }
    private var agentIsWorking: Bool { state.working }
    private var turnFailure: ClientTurnFailure? { context.model.turnFailure }
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
                        standalone: state.chat, prompt: state.unsentTask, attachments: unsentAttachments)
                }

                ForEach(timelineRows, id: \.id) { row in
                    ConversationTimelineItemView(
                        row: row, isLatest: renderedThroughLatest && row.id == timelineRows.last?.id
                    )
                    .id(row.id)
                    .background {
                        ConversationScrollAnchorProbe(controller: scroller, messageIDs: row.messageIds)
                    }
                }

                ForEach(context.model.taskPlans(ids: context.model.unattachedPlanIDs), id: \.id) {
                    TaskPlanView(plan: $0)
                }

                if !state.pendingToolsSummary.isEmpty {
                    PendingToolGroupView(title: state.pendingToolsSummary, tools: pendingTools)
                }
                if agentIsWorking {
                    ConversationAgentWorkingIndicator(
                        label: state.showReasoning ? state.liveReasoning : state.liveActivity,
                        startedAt: context.model.turnStartedAt
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
                        retrying: context.model.retrying || retryClicked,
                        onViewLog: { presentedFailureLog = turnFailure.log },
                        onRetry: {
                            guard !retryClicked, !context.model.retrying else { return }
                            retryClicked = true
                            Task { @MainActor in
                                _ = await context.retryFailedTurn(turnFailure)
                                retryClicked = false
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
        .task(id: responseReadKey) { await acknowledgeVisibleResponse() }
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
            let throughLatest = range.upperBound == messages.count && !context.model.browsingEarlierHistory
            // Rows whose messages meet the rendered range mount whole; their
            // prose is prepared for rendering off the main thread.
            let rendered = Set(
                messages[range].enumerated().map { offset, message in
                    message.id.isEmpty ? "position:\(range.lowerBound + offset)" : message.id
                })
            let rows = context.model.timeline.filter { $0.messageIds.contains(where: rendered.contains) }
            let texts = rows.flatMap { row in
                row.groups.filter { !$0.activity }.flatMap(\.steps).compactMap { step in
                    step.text.isEmpty ? context.model.part(for: step)?.text : step.text
                }
            }
            guard
                let next = try? await BackgroundPreparation.run({
                    for text in texts where !text.isEmpty {
                        try Task.checkCancellation()
                        _ = try ConversationRenderCache.prepare(ConversationRenderCache.preview(text))
                    }
                    return ConversationTimelineProjection(rows: rows)
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
            let source = Array(messages[range])
            if source.isEmpty {
                scroller.finishInitialPositioning()
                viewportMode = .followingLatest
                return
            }
            // Reveal the transcript once its first layout is pinned to the tail.
            for _ in 0..<20 {
                // Yield an actual run-loop pass so AppKit can place the rows;
                // a sequence of executor yields can all precede native layout.
                try? await DieterTaskSleep.milliseconds(5)
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
