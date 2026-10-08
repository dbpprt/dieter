#if os(iOS)
    import DieterAPI
    import DieterShared
    import PhotosUI
    import SharedCore
    import SwiftUI
    import UniformTypeIdentifiers

    /// The open conversation: its model is created once per card and observes
    /// the core's conversation slice while the screen is shown.
    struct IOSConversationScreen: View {
        @Environment(IOSAppModel.self) private var app
        @Environment(IOSWorkspaceNavigation.self) private var navigation
        let cardID: String
        @State private var model: IOSConversationModel?

        var body: some View {
            Group {
                if let model {
                    IOSConversationView(model: model)
                } else {
                    IOSConversationLoadingView(isChat: false)
                }
            }
            .task(id: cardID) {
                let model =
                    self.model
                    ?? IOSConversationModel(
                        cardID: cardID, core: app.core, drafts: app.drafts, show: { [app] in app.show($0) })
                self.model = model
                model.observe()
                takeSharedAttachments(into: model)
            }
            .onChange(of: navigation.sharedAttachments[cardID]?.count ?? 0) { _, _ in
                if let model { takeSharedAttachments(into: model) }
            }
            .onAppear { app.setVisibleConversation(cardID) }
            .onDisappear {
                model?.close()
                app.conversationHidden(cardID)
            }
        }

        /// Shared items routed here join the composer, within the core's limits.
        private func takeSharedAttachments(into model: IOSConversationModel) {
            guard let shared = navigation.sharedAttachments.removeValue(forKey: cardID), !shared.isEmpty else {
                return
            }
            do {
                model.draftAttachments = try IOSAttachmentLoader.appending(shared, to: model.draftAttachments)
            } catch {
                app.show(error)
            }
        }
    }

    private struct IOSConversationView: View {
        @Environment(IOSAppModel.self) private var app
        @Environment(IOSWorkspaceNavigation.self) private var navigation
        @Environment(\.scenePhase) private var scenePhase
        @Bindable var model: IOSConversationModel
        @State private var followsLatest = true
        @State private var isAtLatest = false
        @State private var showsJumpToLatest = false
        @State private var contentCanScroll = false
        @State private var userScrolling = false
        @State private var timelineReady = false
        @State private var pageAnchorToRestore: String?
        @State private var pageRestoreRequest = 0
        @State private var attachmentError: String?
        @State private var photoItems: [PhotosPickerItem] = []
        @State private var fileImporterPresented = false
        @State private var modelSettingsPresented = false
        @State private var failureLog: IOSConversationLog?
        @State private var images = IOSConversationImages()
        @FocusState private var composerFocused: Bool

        private var state: ClientConversationState { model.state }
        private var card: Dieter_V1_Card? { model.card ?? app.card(model.cardID) }
        private var title: String {
            guard let card else { return "Conversation" }
            return SharedRules.shared.conversationTitle(title: card.title, scope: card.scope, boardId: card.boardID)
        }

        var body: some View {
            Group {
                if model.loading {
                    IOSConversationLoadingView(isChat: state.chat)
                } else if let error = model.error, model.card == nil {
                    ContentUnavailableView(
                        "Conversation unavailable", systemImage: "exclamationmark.bubble",
                        description: Text(error))
                } else {
                    transcript
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .environment(\.openURL, OpenURLAction { openConversationURL($0) })
            .overlay {
                if let loadingTitle = images.loadingTitle {
                    ProgressView("Loading \(loadingTitle)…")
                        .padding(.horizontal, 18).padding(.vertical, 14)
                        .background(.regularMaterial, in: Capsule())
                        .accessibilityIdentifier("ios.conversation.image-loading")
                }
            }
            .fullScreenCover(item: $images.preview) { preview in
                IOSConversationImageLightbox(preview: preview)
            }
            .sheet(isPresented: $modelSettingsPresented) {
                IOSConversationModelSettingsView(model: model)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(item: $failureLog) { log in
                IOSConversationLogView(log: log)
            }
            .toolbar { toolbar }
            .fileImporter(
                isPresented: $fileImporterPresented, allowedContentTypes: [.item], allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls):
                    intake { try await IOSAttachmentLoader().parts(urls: urls, appendingTo: $0) }
                case .failure(let error):
                    if (error as NSError).code != NSUserCancelledError { attachmentError = error.localizedDescription }
                }
            }
            .onChange(of: photoItems) { _, items in
                guard !items.isEmpty else { return }
                photoItems = []
                intake { try await IOSAttachmentLoader().parts(photoItems: items, appendingTo: $0) }
            }
        }

        // MARK: - Toolbar

        @ToolbarContentBuilder
        private var toolbar: some ToolbarContent {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Model settings", systemImage: "slider.horizontal.3") {
                    composerFocused = false
                    modelSettingsPresented = true
                }
                // Keeps the Start button's position while the catalog loads.
                .disabled(model.agent == nil)
                .accessibilityIdentifier("ios.conversation.model-settings")
                .accessibilityValue(model.agent.map(IOSAgentSummary.text) ?? "")
                if let card {
                    IOSConversationProviderQuotaView(accountKey: card.providerAccountKey)
                }
                if state.canHalt {
                    Button("Stop", systemImage: "stop.circle") { Task { await model.cancel() } }
                        .accessibilityIdentifier("ios.task.stop")
                } else if state.canStart || state.starting {
                    Button("Start task", systemImage: "play.circle") { Task { await model.start() } }
                        .disabled(state.starting)
                        .accessibilityIdentifier("ios.task.start")
                }
                Menu {
                    Button("Browse files", systemImage: "folder", action: browseFiles)
                        .disabled(model.daemonID.isEmpty || card == nil)
                        .accessibilityIdentifier("ios.task.files")
                    if !state.chat, let lanes = model.slice?.board.lanes, !lanes.isEmpty {
                        Menu("Move task", systemImage: "rectangle.3.group") {
                            ForEach(lanes, id: \.id) { lane in
                                Button(lane.name) { Task { await model.move(toLane: lane.id) } }
                                    .disabled(lane.id == card?.lane)
                                    .accessibilityIdentifier("ios.task.move.\(lane.id)")
                            }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Task actions")
                .accessibilityIdentifier("ios.task.actions")
                .disabled(card == nil)
            }
        }

        private func browseFiles() {
            guard let card else { return }
            navigation.sheet = .files(
                IOSFileScope(
                    machineID: model.daemonID, projectID: card.projectID, checkoutID: card.checkoutID,
                    cardID: card.id, title: title))
        }

        // MARK: - Transcript

        private var transcript: some View {
            ScrollViewReader { proxy in
                ZStack {
                    ScrollView {
                        // An eager stack keeps every explicit scroll target alive while
                        // earlier pages are prepended or the core drops loaded history.
                        VStack(alignment: .leading, spacing: 22) {
                            header
                            if model.hasEarlier || model.loadingEarlier {
                                earlierButton
                            }
                            if model.timeline.isEmpty, !state.working {
                                ContentUnavailableView(
                                    "Ready when you are", systemImage: "bubble.left.and.bubble.right",
                                    description: Text(
                                        state.unsentTask.isEmpty ? "Send a message to begin." : state.unsentTask)
                                )
                                .padding(.vertical, 32)
                            }
                            ForEach(model.timeline, id: \.id) { row in
                                IOSTimelineRowView(model: model, row: row)
                                    .id(row.id)
                            }
                            ForEach(model.taskPlans(ids: model.slice?.unattachedPlanIds ?? []), id: \.id) { plan in
                                IOSTaskPlanView(plan: plan)
                            }
                            if state.working {
                                IOSConversationTurnIndicator(
                                    label: state.showReasoning ? state.liveReasoning : state.liveActivity,
                                    detail: state.pendingToolsSummary, startedAt: model.turnStartedAt
                                )
                                .id("ios.conversation.agent-working")
                            }
                            if let failure = model.turnFailure {
                                IOSTurnFailureView(
                                    failure: failure, retrying: model.retrying || model.retryingFailure,
                                    viewLog: { failureLog = IOSConversationLog(title: "Turn log", text: failure.log) },
                                    retry: { Task { await model.retryFailedTurn() } }
                                )
                                .id("ios.conversation.turn-failure")
                            }
                            Color.clear.frame(height: 1).id(IOSConversationScrollBehavior.bottomID)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 20)
                        .frame(maxWidth: 900)
                        .frame(maxWidth: .infinity)
                    }
                    .opacity(timelineReady ? 1 : 0)
                    .accessibilityHidden(!timelineReady)
                    .allowsHitTesting(timelineReady)
                    .accessibilityIdentifier("ios.conversation.transcript")
                    .scrollDismissesKeyboard(.interactively)
                    .defaultScrollAnchor(.bottom, for: .initialOffset)
                    .defaultScrollAnchor(.top, for: .sizeChanges)
                    .onScrollGeometryChange(for: IOSConversationScrollSample.self) { geometry in
                        IOSConversationScrollSample(geometry)
                    } action: { previous, current in
                        isAtLatest = current.atEnd
                        showsJumpToLatest = current.showsJumpToLatest
                        contentCanScroll = current.canScroll
                        if userScrolling { followsLatest = current.atEnd }
                        if !timelineReady, current.atEnd { timelineReady = true }
                        if !userScrolling, followsLatest, !current.atEnd, current.layout != previous.layout {
                            requestLatestScroll(proxy)
                        }
                    }
                    .onScrollPhaseChange { oldPhase, newPhase in
                        let wasUserScrolling = oldPhase == .interacting || oldPhase == .decelerating
                        let isUserScrolling = newPhase == .interacting || newPhase == .decelerating
                        userScrolling = isUserScrolling
                        if isUserScrolling {
                            followsLatest = isAtLatest
                        } else if wasUserScrolling {
                            followsLatest = isAtLatest
                            if isAtLatest, model.returnToLatest() { requestLatestScroll(proxy) }
                        }
                    }
                    .onChange(of: model.timeline.last?.id) { _, _ in
                        if followsLatest { requestLatestScroll(proxy) }
                    }
                    .onChange(of: model.timeline.last) { _, _ in
                        if followsLatest { requestLatestScroll(proxy) }
                    }
                    .onChange(of: pageRestoreRequest) { _, _ in
                        guard let anchor = pageAnchorToRestore else { return }
                        Task { @MainActor in
                            await Task.yield()
                            scroll(proxy, to: anchor, anchor: .top)
                            pageAnchorToRestore = nil
                        }
                    }
                    .overlay(alignment: .bottom) {
                        if timelineReady, contentCanScroll, showsJumpToLatest, !model.timeline.isEmpty {
                            Button("Jump to latest", systemImage: "arrow.down") { jumpToLatest(proxy) }
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 14).padding(.vertical, 10)
                                .modifier(IOSFloatingGlassModifier(shape: Capsule()))
                                .buttonStyle(.plain)
                                .padding(.bottom, 10)
                                .accessibilityIdentifier("ios.conversation.latest")
                        }
                    }
                    .background(Color(uiColor: .systemBackground))

                    if !timelineReady {
                        IOSConversationLoadingView(isChat: state.chat, preparingTimeline: true)
                            .allowsHitTesting(false)
                    }
                }
                .task(id: model.cardID) {
                    // Give the eager stack more than one layout pass before revealing it.
                    for _ in 0..<3 {
                        await Task.yield()
                        scroll(proxy, to: IOSConversationScrollBehavior.bottomID, anchor: .bottom)
                    }
                    await Task.yield()
                    timelineReady = true
                }
                .task(id: ResponseReadKey(model: model, visible: readVisible)) {
                    await acknowledgeVisibleResponse()
                }
                .safeAreaInset(edge: .bottom, spacing: 0) { composer }
            }
        }

        private var header: some View {
            HStack(spacing: 10) {
                Text(SharedRules.shared.runtimeLabel(runtime: state.runtime))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(
                        SharedRules.shared.runtimeActive(runtime: state.runtime) ? Color.accentColor : .secondary)
                Spacer(minLength: 12)
                if let agent = model.agent {
                    Label(agent.modelLabel, systemImage: "sparkles")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 36)
            .background(.thinMaterial, in: Capsule())
        }

        private var earlierButton: some View {
            Button {
                loadEarlierMessages()
            } label: {
                HStack(spacing: 8) {
                    if model.loadingEarlier { ProgressView().controlSize(.small) }
                    Text(model.loadingEarlier ? "Loading earlier messages…" : "Load earlier messages")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(model.loadingEarlier)
            .accessibilityIdentifier("ios.conversation.earlier")
        }

        private func loadEarlierMessages() {
            let anchor = model.timeline.first?.id
            followsLatest = false
            Task { @MainActor in
                guard await model.loadEarlierMessages(), let anchor, model.timeline.first?.id != anchor,
                    model.timeline.contains(where: { $0.id == anchor })
                else { return }
                pageAnchorToRestore = anchor
                pageRestoreRequest &+= 1
            }
        }

        private func jumpToLatest(_ proxy: ScrollViewProxy) {
            followsLatest = true
            model.returnToLatest()
            requestLatestScroll(proxy)
        }

        private func requestLatestScroll(_ proxy: ScrollViewProxy) {
            Task { @MainActor in
                await Task.yield()
                scroll(proxy, to: IOSConversationScrollBehavior.bottomID, anchor: .bottom)
            }
        }

        private func scroll(_ proxy: ScrollViewProxy, to id: String, anchor: UnitPoint) {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { proxy.scrollTo(id, anchor: anchor) }
        }

        // MARK: - Read receipts

        /// The latest reply is on screen: the scene is active and the
        /// transcript rests at its end.
        private var readVisible: Bool {
            scenePhase == .active && timelineReady && isAtLatest && !model.browsingEarlier
        }

        private struct ResponseReadKey: Equatable {
            let cardID: String
            let responseSeq: Int64
            let lastSeq: Int64
            let visible: Bool

            @MainActor init(model: IOSConversationModel, visible: Bool) {
                cardID = model.cardID
                responseSeq = model.card?.responseSeq ?? 0
                lastSeq = model.slice?.conversation.lastSeq ?? 0
                self.visible = visible
            }
        }

        /// Shows the conversation as on screen once a reply has settled into
        /// view; the core marks it read when it holds that reply. Scrolling
        /// away or leaving first cancels this.
        private func acknowledgeVisibleResponse() async {
            guard readVisible else { return }
            do { try await DieterTaskSleep.milliseconds(200) } catch { return }
            guard readVisible else { return }
            app.setVisibleConversation(model.cardID)
        }

        // MARK: - Workspace links

        /// Workspace images open in the lightbox and other workspace files in
        /// the files sheet; web and other links go to the system.
        private func openConversationURL(_ url: URL) -> OpenURLAction.Result {
            guard let card else { return .systemAction(url) }
            let destination = url.isFileURL ? url.path : url.absoluteString
            if SharedRules.shared.isWorkspaceImage(destination: destination) {
                let target = WorkspaceTarget(
                    endpointID: IOSAppModel.endpointID(daemonID: model.daemonID), projectID: card.projectID,
                    conversationID: card.id)
                Task { await images.open(destination, target: target, core: app.core, show: { app.show($0) }) }
                return .handled
            }
            // Without a workspace, a file link is the only kind that fails for want of one.
            let outside = ClientContentLinkResolution(
                rules: SharedRules.shared.resolveContentLink(url: url.relativeString, workspaceRoot: "", relativeTo: "")
            )
            guard case .failure(let failure) = outside.result, failure.kind == .invalidWorkspace else {
                return .systemAction(url)
            }
            Task { await openWorkspaceFile(url, card: card) }
            return .handled
        }

        /// Resolves a file link against the conversation's workspace on its
        /// machine and opens the file there.
        private func openWorkspaceFile(_ url: URL, card: Dieter_V1_Card) async {
            guard
                let workspace = await app.perform({
                    $0.admin = .with { $0.conversationWorkspace = .with { $0.cardID = card.id } }
                })?.workspace
            else { return }
            let resolution = ClientContentLinkResolution(
                rules: SharedRules.shared.resolveContentLink(
                    url: url.relativeString, workspaceRoot: workspace.path, relativeTo: ""))
            switch resolution.result {
            case .file(let file):
                navigation.sheet = .files(
                    IOSFileScope(
                        machineID: model.daemonID, projectID: card.projectID, checkoutID: card.checkoutID,
                        cardID: card.id, title: title, openPath: file.path))
            case .failure(let failure):
                app.errorMessage = failure.message
            default:
                break
            }
        }

        // MARK: - Composer

        private var composer: some View {
            VStack(spacing: 8) {
                if app.session.hasNotice {
                    let notice = app.session.notice
                    IOSConnectionBanner(
                        title: notice.title,
                        detail: notice.detail.isEmpty ? "Your draft will stay here." : notice.detail,
                        isConnecting: notice.working,
                        retry: notice.working ? nil : { Task { await app.reconnect() } })
                }
                if !model.queue.isEmpty {
                    IOSQueuedMessageTray(model: model, focusComposer: { composerFocused = true })
                        .frame(maxWidth: 900)
                }
                if let agent = model.agent {
                    agentPill(agent)
                }
                if !state.respondingModel.isEmpty {
                    Text("Last response model: \(state.respondingModel)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 900, alignment: .leading)
                        .accessibilityIdentifier("ios.composer.responding-model")
                }
                if !model.draftAttachments.isEmpty {
                    attachmentsStrip
                }
                if let attachmentError {
                    Text(attachmentError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: 900, alignment: .leading)
                        .accessibilityIdentifier("ios.composer.attachment-error")
                }
                composerInput
                    .frame(maxWidth: 900)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background {
                LinearGradient(
                    colors: [.clear, Color(uiColor: .systemBackground).opacity(0.92)],
                    startPoint: .top, endPoint: .center
                )
                .ignoresSafeArea()
            }
        }

        private func agentPill(_ agent: ClientAgentControlsState) -> some View {
            let fast = IOSAgentSummary.fastMode(agent)
            return HStack(spacing: 8) {
                Button {
                    composerFocused = false
                    modelSettingsPresented = true
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: fast ? "bolt.fill" : "sparkles")
                            .foregroundStyle(fast ? Color.orange : Color.accentColor)
                        Text(IOSAgentSummary.text(agent)).lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.caption2.bold())
                            .foregroundStyle(.tertiary)
                    }
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12)
                    .frame(minHeight: 34)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .modifier(IOSFloatingGlassModifier(shape: Capsule()))
                .accessibilityLabel("Next message model settings")
                .accessibilityValue(IOSAgentSummary.text(agent))
                .accessibilityIdentifier("ios.composer.model-settings")
                Spacer(minLength: 8)
                if state.contextUsedTokens > 0, state.contextWindowTokens > 0 {
                    Text(
                        "\(SharedRules.shared.compactTokens(value: state.contextUsedTokens)) · \(state.contextPercent)%"
                    )
                    .font(.caption.weight(.medium).monospacedDigit())
                    .foregroundStyle(state.contextNearLimit ? Color.orange : Color.secondary)
                    .accessibilityLabel("Context used")
                    .accessibilityValue("\(state.contextPercent) percent")
                    .accessibilityIdentifier("ios.composer.context")
                }
            }
            .frame(maxWidth: 900)
        }

        private var attachmentsStrip: some View {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(Array(model.draftAttachments.enumerated()), id: \.offset) { index, attachment in
                        HStack(spacing: 6) {
                            Image(systemName: attachment.mediaType.hasPrefix("image/") ? "photo" : "doc")
                            Text(attachment.filename).lineLimit(1)
                            Button("Remove attachment", systemImage: "xmark") {
                                guard model.draftAttachments.indices.contains(index) else { return }
                                model.draftAttachments.remove(at: index)
                                attachmentError = nil
                            }
                            .labelStyle(.iconOnly)
                            .accessibilityIdentifier("ios.composer.attachment.remove.\(index)")
                        }
                        .font(.caption)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .modifier(IOSFloatingGlassModifier(shape: Capsule()))
                    }
                }
            }
            .scrollIndicators(.hidden)
            .frame(maxWidth: 900, alignment: .leading)
            .accessibilityIdentifier("ios.composer.attachments")
        }

        @ViewBuilder private var composerInput: some View {
            let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
            if #available(iOS 26.0, *) {
                composerControls
                    .padding(6)
                    .glassEffect(.regular.interactive(), in: shape)
            } else {
                composerControls
                    .padding(6)
                    .background(.ultraThinMaterial, in: shape)
                    .overlay(shape.stroke(Color.secondary.opacity(0.2), lineWidth: 0.75))
                    .shadow(color: .black.opacity(0.08), radius: 12, y: 5)
            }
        }

        private var composerControls: some View {
            let sendEnabled = !model.sending && model.hasDraft
            let slots = IOSAttachmentLoader.remainingSlots(after: model.draftAttachments)
            return HStack(alignment: .bottom, spacing: 8) {
                VStack(spacing: 0) {
                    PhotosPicker(selection: $photoItems, maxSelectionCount: max(1, slots), matching: .images) {
                        Image(systemName: "photo")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 30, height: 25)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(slots == 0)
                    .accessibilityLabel("Attach photos")
                    .accessibilityIdentifier("ios.composer.attach-photos")

                    Divider().frame(width: 16)

                    Button {
                        composerFocused = false
                        fileImporterPresented = true
                    } label: {
                        Image(systemName: "paperclip")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 30, height: 25)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(slots == 0)
                    .accessibilityLabel("Attach files")
                    .accessibilityIdentifier("ios.composer.attach-files")
                }
                .foregroundStyle(Color.accentColor)
                .modifier(IOSFloatingGlassModifier(shape: Capsule()))
                .padding(.bottom, 1)

                IOSAttachmentTextEditor(
                    text: $model.draftText,
                    isFocused: Binding(get: { composerFocused }, set: { composerFocused = $0 }),
                    placeholder: "Message Dieter…",
                    minimumLines: 1,
                    maximumLines: 8,
                    accessibilityIdentifier: "ios.composer.message",
                    pastedImages: { payloads in
                        intake { try await IOSAttachmentLoader().parts(payloads: payloads, appendingTo: $0) }
                    },
                    pasteFailed: { attachmentError = $0.localizedDescription }
                )
                .padding(.horizontal, 8).padding(.vertical, 4)
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture().onEnded { composerFocused = true })

                Button {
                    followsLatest = true
                    Task { await model.send() }
                } label: {
                    Group {
                        if model.sending {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "arrow.up").font(.system(size: 15, weight: .bold))
                        }
                    }
                    .frame(width: 36, height: 36)
                    .modifier(IOSComposerSendVisualStyle(enabled: sendEnabled))
                    .contentShape(Circle())
                    .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 3)
                .disabled(!sendEnabled)
                .accessibilityLabel(state.working ? "Queue message" : "Send message")
                .accessibilityIdentifier("ios.composer.send")
            }
        }

        /// Reads picked or pasted files into the draft of this conversation.
        private func intake(
            _ read: @escaping @Sendable ([Dieter_V1_MessagePart]) async throws -> [Dieter_V1_MessagePart]
        ) {
            let existing = model.draftAttachments
            Task { @MainActor in
                do {
                    let parts = try await read(existing)
                    // Attachments added meanwhile stay; the result is checked again.
                    let added = Array(parts.dropFirst(existing.count))
                    model.draftAttachments = try IOSAttachmentLoader.appending(added, to: model.draftAttachments)
                    attachmentError = nil
                } catch {
                    attachmentError = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Timeline rows

    /// One transcript row as the core lays it out: a user message, an
    /// assistant message's step groups, or a run of routine work.
    private struct IOSTimelineRowView: View {
        let model: IOSConversationModel
        let row: ClientTimelineItem

        var body: some View {
            if row.activity {
                IOSActivityDisclosure(
                    model: model, title: row.summary, steps: row.groups.flatMap(\.steps), identifier: row.id)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Label(row.user ? "You" : "Dieter", systemImage: row.user ? "person.fill" : "sparkles")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(row.user ? Color.accentColor : Color.secondary)
                    ForEach(row.groups, id: \.id) { group in
                        if group.activity {
                            IOSActivityDisclosure(
                                model: model, title: group.summary, steps: group.steps, identifier: group.id)
                        } else {
                            ForEach(group.steps, id: \.id) { step in
                                IOSTimelineStepView(
                                    model: model, step: step, user: row.user, subagentIDs: row.subagentIds)
                            }
                        }
                    }
                    ForEach(model.taskPlans(ids: row.planIds), id: \.id) { plan in
                        IOSTaskPlanView(plan: plan)
                    }
                    if row.user, row.delivery != .unspecified, row.delivery != .synced {
                        IOSMessageDelivery(row: row)
                    }
                }
                .padding(row.user ? 14 : 0)
                .background {
                    if row.user {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(Color.accentColor.opacity(0.10))
                            .overlay {
                                RoundedRectangle(cornerRadius: 20, style: .continuous)
                                    .stroke(Color.accentColor.opacity(0.16), lineWidth: 0.75)
                            }
                    }
                }
                .opacity(row.unconfirmed && row.delivery != .failed ? 0.6 : 1)
                .padding(.leading, row.user ? 34 : 0)
                .frame(maxWidth: .infinity, alignment: row.user ? .trailing : .leading)
                .contextMenu {
                    if row.copyable {
                        Button("Copy message", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = model.copyText(row)
                        }
                    }
                }
            }
        }
    }

    /// A user message that has not synced yet, as the core reports it.
    private struct IOSMessageDelivery: View {
        @Environment(IOSAppModel.self) private var app
        let row: ClientTimelineItem

        private var messageID: String { row.messageIds.first ?? "" }

        var body: some View {
            if row.delivery == .failed {
                HStack(spacing: 8) {
                    Label("Send failed", systemImage: "exclamationmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                    Spacer(minLength: 8)
                    Button("Retry") { Task { await app.perform { $0.retryPending = .with { $0.id = messageID } } } }
                        .accessibilityIdentifier("ios.message.retry.\(messageID)")
                    Button("Remove", role: .destructive) {
                        Task { await app.perform { $0.discardPending = .with { $0.id = messageID } } }
                    }
                    .accessibilityIdentifier("ios.message.remove.\(messageID)")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                Label(row.deliveryLabel, systemImage: row.delivery == .queued ? "clock.badge.checkmark" : "clock")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    /// One visible part of a message.
    private struct IOSTimelineStepView: View {
        let model: IOSConversationModel
        let step: ClientTimelineStep
        let user: Bool
        let subagentIDs: [String]

        var body: some View {
            switch step.kind {
            case .subagents:
                ForEach(model.subagents(ids: subagentIDs), id: \.id) { agent in
                    IOSSubagentView(agent: agent)
                }
            case .tool:
                IOSToolStepView(step: step, part: model.part(for: step))
            case .attention where step.toolStatus != .unspecified:
                // A tool call that failed or waits for a decision.
                IOSToolStepView(step: step, part: model.part(for: step))
            case .reasoning:
                DisclosureGroup("Reasoning") { IOSMessageText(text: model.part(for: step)?.text ?? step.text) }
                    .font(.subheadline).foregroundStyle(.secondary)
            case .attachment:
                if let part = model.part(for: step) {
                    Label(
                        part.filename.isEmpty ? "Attachment" : part.filename,
                        systemImage: part.mediaType.hasPrefix("image/") ? "photo" : "doc"
                    )
                    .font(.subheadline).foregroundStyle(.secondary)
                }
            default:
                if let text = (model.part(for: step)?.text).flatMap({ $0.isEmpty ? nil : $0 }) {
                    IOSMessageText(text: text)
                        .foregroundStyle(step.kind == .attention ? Color.orange : Color.primary)
                        .accessibilityIdentifier("ios.message.text.\(user ? "user" : "assistant")")
                }
            }
        }
    }

    /// Routine work behind one disclosure titled by the core's summary.
    private struct IOSActivityDisclosure: View {
        let model: IOSConversationModel
        let title: String
        let steps: [ClientTimelineStep]
        let identifier: String
        @State private var expanded = false

        var body: some View {
            DisclosureGroup(isExpanded: $expanded) {
                if expanded {
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(steps, id: \.id) { step in
                            if step.kind == .reasoning {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Reasoning").font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                                    IOSMessageText(text: model.part(for: step)?.text ?? step.text)
                                }
                            } else {
                                IOSToolStepView(step: step, part: model.part(for: step))
                            }
                        }
                    }
                    .padding(.top, 6)
                }
            } label: {
                Label(title.isEmpty ? "Activity" : title, systemImage: "waveform.path.ecg")
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityIdentifier("ios.conversation.activity.\(identifier)")
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
        }
    }

    /// A tool call: the core's title and status, with its previews behind a disclosure.
    private struct IOSToolStepView: View {
        let step: ClientTimelineStep
        let part: Dieter_V1_MessagePart?
        @State private var expanded = false

        private var attention: Bool { step.kind == .attention || step.toolAttention }

        private var status: String { step.toolStatusLabel }

        var body: some View {
            DisclosureGroup(isExpanded: $expanded) {
                if expanded, let part {
                    VStack(alignment: .leading, spacing: 8) {
                        if !part.inputPreview.isEmpty {
                            Text(part.inputPreview).font(.system(.caption, design: .monospaced))
                        }
                        if !part.outputPreview.isEmpty {
                            Text(part.outputPreview).font(.system(.caption, design: .monospaced))
                        }
                        if !part.errorText.isEmpty { Text(part.errorText).foregroundStyle(.red) }
                    }
                    .textSelection(.enabled)
                    .padding(.top, 4)
                }
            } label: {
                HStack(spacing: 7) {
                    Image(
                        systemName: attention
                            ? "exclamationmark.circle"
                            : (step.toolStatus == .completed ? "checkmark.circle" : "terminal"))
                    Text(step.toolTitle.isEmpty ? "Tool" : step.toolTitle)
                        .font(.system(.caption, design: .monospaced).weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if step.toolStatus == .running {
                        ProgressView().controlSize(.mini)
                    } else if !status.isEmpty {
                        Text(status).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
            .font(.subheadline)
            .foregroundStyle(attention ? Color.orange : Color.secondary)
            .accessibilityIdentifier("ios.conversation.tool.\(step.id)")
        }
    }

    /// A task plan's progress and tasks, as the core words them.
    private struct IOSTaskPlanView: View {
        let plan: Dieter_V1_TaskPlan

        var body: some View {
            let summary = ClientTaskPlanSummary(rules: SharedRules.shared.taskPlanSummary(plan: plan.rulesData))
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("Plan", systemImage: summary.active ? "list.bullet.clipboard.fill" : "list.bullet.clipboard")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Text("\(summary.completed)/\(summary.total)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if summary.total > 0 {
                    ProgressView(value: Double(summary.completed), total: Double(summary.total))
                }
                ForEach(Array(summary.taskTexts.enumerated()), id: \.offset) { _, text in
                    Text(text).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("ios.conversation.plan.\(plan.id)")
        }
    }

    /// A delegated agent, as the core words it.
    private struct IOSSubagentView: View {
        let agent: Dieter_V1_Subagent

        var body: some View {
            TimelineView(.periodic(from: .now, by: 1)) { clock in
                let summary = ClientSubagentSummary(
                    rules: SharedRules.shared.subagentSummary(agent: agent.rulesData, nowMillis: clock.date.epochMillis)
                )
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Image(systemName: summary.active ? "person.2.wave.2" : "person.2")
                        Text(summary.title).font(.subheadline.weight(.medium)).lineLimit(1)
                        Spacer(minLength: 8)
                        if !summary.elapsed.isEmpty {
                            Text(summary.elapsed).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    Text([summary.agentLabel, summary.identity].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption2).foregroundStyle(.secondary)
                    if !summary.statusLine.isEmpty {
                        Text(summary.statusLine).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    }
                }
                .padding(12)
                .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .accessibilityElement(children: .combine)
            }
            .accessibilityIdentifier("ios.conversation.subagent.\(agent.id)")
        }
    }

    // MARK: - Turn state

    private struct IOSConversationTurnIndicator: View {
        let label: String
        let detail: String
        let startedAt: Date?
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var shimmer = false

        private var title: String { label.isEmpty ? "Dieter is working…" : label }

        var body: some View {
            HStack(spacing: 9) {
                IOSDieterActivityGlyph(size: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .overlay {
                            if !reduceMotion {
                                GeometryReader { geometry in
                                    LinearGradient(
                                        colors: [.clear, .primary.opacity(0.8), .clear],
                                        startPoint: .leading, endPoint: .trailing
                                    )
                                    .frame(width: geometry.size.width)
                                    .offset(x: shimmer ? geometry.size.width : -geometry.size.width)
                                }
                                .mask(Text(title).font(.caption.weight(.medium)))
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                            }
                        }
                        .lineLimit(1)
                    if !detail.isEmpty {
                        Text(detail).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if let startedAt {
                    Text(startedAt, style: .timer)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .accessibilityLabel("Elapsed turn time")
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 38)
            .modifier(IOSFloatingGlassModifier(shape: Capsule()))
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("ios.conversation.agent-working")
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 2).repeatForever(autoreverses: false)) { shimmer = true }
            }
        }
    }

    /// The last turn failed, as the core reads it.
    private struct IOSTurnFailureView: View {
        let failure: ClientTurnFailure
        let retrying: Bool
        let viewLog: () -> Void
        let retry: () -> Void

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                Label(failure.summary, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.orange)
                HStack(spacing: 10) {
                    if !failure.log.isEmpty {
                        Button("View log", action: viewLog)
                            .accessibilityIdentifier("ios.conversation.failure.log")
                    }
                    Spacer(minLength: 0)
                    if failure.retryable {
                        Button(retrying ? "Retry queued…" : "Retry turn", action: retry)
                            .buttonStyle(.borderedProminent)
                            .disabled(retrying)
                            .accessibilityIdentifier("ios.conversation.failure.retry")
                    }
                }
                .controlSize(.small)
            }
            .padding(14)
            .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("ios.conversation.failure")
        }
    }

    private struct IOSConversationLog: Identifiable {
        let id = UUID()
        let title: String
        let text: String
    }

    private struct IOSConversationLogView: View {
        @Environment(\.dismiss) private var dismiss
        let log: IOSConversationLog

        var body: some View {
            NavigationStack {
                ScrollView {
                    Text(log.text)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle(log.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = log.text }
                    }
                }
            }
            .accessibilityIdentifier("ios.conversation.log")
        }
    }

    // MARK: - Queued messages

    private struct IOSQueuedMessageTray: View {
        let model: IOSConversationModel
        let focusComposer: () -> Void

        var body: some View {
            ScrollView(.vertical) {
                LazyVStack(spacing: 7) {
                    ForEach(model.queue, id: \.id) { message in
                        IOSQueuedMessageRow(model: model, message: message, focusComposer: focusComposer)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .frame(height: min(CGFloat(model.queue.count) * 68, 196))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Queued messages")
            .accessibilityIdentifier("ios.conversation.queue")
        }
    }

    private struct IOSQueuedMessageRow: View {
        let model: IOSConversationModel
        let message: Dieter_V1_QueuedMessage
        let focusComposer: () -> Void

        private var restored: Dieter_V1_QueuedMessage {
            Dieter_V1_QueuedMessage(
                rules: SharedRules.shared.restoredDraft(message: message.rulesData, currentText: ""))
        }
        private var busy: Bool { model.queueActionID != nil }
        private var acting: Bool { model.queueActionID == message.id }
        private var canSteer: Bool { message.id == model.state.steerableID }

        var body: some View {
            let restored = restored
            HStack(spacing: 10) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(restored.text.isEmpty ? (restored.parts.first?.filename ?? "") : restored.text)
                        .font(.subheadline.weight(.medium)).lineLimit(2)
                    HStack(spacing: 5) {
                        Text("Queued")
                        if !restored.parts.isEmpty {
                            Image(systemName: "paperclip")
                            Text(restored.parts.count, format: .number)
                        }
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if canSteer {
                    Button(acting ? "Steering…" : "Steer") { Task { await model.steer(message.id) } }
                        .buttonStyle(.bordered).controlSize(.small)
                        .disabled(busy)
                        .accessibilityIdentifier("ios.queued-message.steer.\(message.id)")
                }
                Menu {
                    Button("Edit queued message", systemImage: "pencil") {
                        Task { if await model.removeQueued(message, edit: true) { focusComposer() } }
                    }
                    Button("Remove queued message", systemImage: "trash", role: .destructive) {
                        Task { await model.removeQueued(message, edit: false) }
                    }
                } label: {
                    if acting {
                        ProgressView()
                    } else {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                .disabled(busy || model.sending)
                .accessibilityLabel("Queued message actions")
                .accessibilityIdentifier("ios.queued-message.menu.\(message.id)")
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .frame(minHeight: 60)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.secondary.opacity(0.18)))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("ios.queued-message.\(message.id)")
        }
    }

    // MARK: - Agent settings

    /// The composer's agent in one line: the core's provider, model, and
    /// effort labels, and whether fast mode is on.
    enum IOSAgentSummary {
        static func text(_ agent: ClientAgentControlsState) -> String {
            [agent.modelLabel, agent.effortLabel].filter { !$0.isEmpty }.joined(separator: " · ")
        }

        /// Fast mode shows as a bolt; the option is the provider's.
        static func fastMode(_ agent: ClientAgentControlsState) -> Bool { agent.fastMode }
    }

    /// The pickers of the core's `AgentControlsState`; each pick is a choice
    /// the caller sends (ChooseAgent, or a creation preview).
    struct IOSAgentPickers: View {
        let controls: ClientAgentControlsState
        /// The pickers' accessibility identifiers start with this.
        let identifierPrefix: String
        let choose: (ClientAgentChoice.OneOf_Choice) -> Void

        var body: some View {
            Picker("Provider", selection: Binding(get: { controls.selection.provider }, set: { choose(.provider($0)) }))
            {
                if !controls.providers.contains(where: { $0.id == controls.selection.provider }) {
                    Text(controls.providerLabel).tag(controls.selection.provider).disabled(true)
                }
                ForEach(controls.providers, id: \.id) { Text($0.name).tag($0.id) }
            }
            .disabled(!controls.providerEnabled)
            .accessibilityIdentifier("\(identifierPrefix).provider")
            .accessibilityValue(controls.providerLabel)
            Picker("Model", selection: Binding(get: { controls.selection.model }, set: { choose(.model($0)) })) {
                if !controls.models.contains(where: { $0.id == controls.selection.model }) {
                    Text(controls.modelLabel).tag(controls.selection.model).disabled(true)
                }
                ForEach(controls.models, id: \.id) { Text($0.name).tag($0.id) }
            }
            .disabled(!controls.modelEnabled)
            .accessibilityIdentifier("\(identifierPrefix).model")
            .accessibilityValue(controls.modelLabel)
            if !controls.efforts.isEmpty {
                Picker("Reasoning", selection: Binding(get: { controls.effortValue }, set: { choose(.effort($0)) })) {
                    ForEach(controls.effortChoices, id: \.id) { Text($0.name).tag($0.id) }
                }
                .disabled(!controls.effortEnabled)
                .accessibilityIdentifier("\(identifierPrefix).effort")
                .accessibilityValue(controls.effortLabel)
            }
            ForEach(controls.options, id: \.id) { option in
                optionField(option)
                    .disabled(controls.optionEnabled[option.id] == false)
                    .accessibilityIdentifier("\(identifierPrefix).option.\(option.id)")
            }
        }

        @ViewBuilder
        private func optionField(_ option: Dieter_V1_ProviderOption) -> some View {
            let value = Binding(
                get: { controls.optionValues[option.id] ?? option.defaultValue },
                set: { next in
                    guard next != (controls.optionValues[option.id] ?? option.defaultValue) else { return }
                    choose(
                        .option(
                            .with {
                                $0.id = option.id
                                $0.optionValue = next
                            }))
                })
            switch controls.optionKinds[option.id] ?? .text {
            case .toggle:
                Toggle(
                    isOn: Binding(
                        get: { controls.optionOn[option.id] ?? false },
                        set: { value.wrappedValue = SharedRules.shared.toggleOptionValue(on: $0) })
                ) {
                    Label(option.name, systemImage: option.id == controls.fastOptionID ? "bolt.fill" : "switch.2")
                }
            case .choice:
                Picker(option.name, selection: value) {
                    ForEach(option.choices, id: \.value) { choice in Text(choice.name).tag(choice.value) }
                }
            default:
                TextField(option.name, text: value)
            }
        }
    }

    private struct IOSConversationModelSettingsView: View {
        @Environment(\.dismiss) private var dismiss
        let model: IOSConversationModel

        var body: some View {
            NavigationStack {
                Form {
                    if let agent = model.agent {
                        Section {
                            IOSAgentPickers(controls: agent, identifierPrefix: "ios.conversation") { choice in
                                Task { await model.chooseAgent(choice) }
                            }
                        } header: {
                            Text("Agent")
                        } footer: {
                            Text(
                                "Applies to your next message. Settings the agent cannot change mid-conversation stay locked."
                            )
                        }
                    } else {
                        ProgressView("Loading agent models…")
                    }
                }
                .scrollContentBackground(.hidden)
                .background { IOSWorkspaceBackdrop() }
                .navigationTitle("Next message")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                            .accessibilityIdentifier("ios.conversation.model-settings.done")
                    }
                }
            }
            .accessibilityIdentifier("ios.conversation.model-settings.sheet")
        }
    }

    // MARK: - Loading

    struct IOSConversationLoadingView: View {
        let isChat: Bool
        var preparingTimeline = false

        var body: some View {
            VStack(spacing: 20) {
                IOSDieterActivityGlyph(size: 82)
                VStack(spacing: 6) {
                    Text(
                        preparingTimeline ? "Finishing the conversation…" : (isChat ? "Opening chat…" : "Opening task…")
                    )
                    .font(.headline)
                    Text("Syncing the latest conversation")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                RadialGradient(
                    colors: [Color.accentColor.opacity(0.08), .clear], center: .center, startRadius: 0,
                    endRadius: 220)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("ios.conversation.loading")
        }
    }

    private struct IOSComposerSendVisualStyle: ViewModifier {
        let enabled: Bool

        @ViewBuilder func body(content: Content) -> some View {
            if #available(iOS 26.0, *) {
                content
                    .foregroundStyle(enabled ? Color.white : Color.secondary.opacity(0.72))
                    .glassEffect(
                        .regular.tint(enabled ? Color.accentColor : Color.secondary.opacity(0.12)).interactive(),
                        in: Circle())
            } else {
                content
                    .foregroundStyle(enabled ? Color.white : Color.secondary.opacity(0.72))
                    .background(enabled ? Color.accentColor : Color.secondary.opacity(0.12), in: Circle())
                    .overlay(Circle().stroke(Color.white.opacity(0.22), lineWidth: 0.75))
            }
        }
    }

    // MARK: - Scroll position

    private struct IOSConversationScrollLayout: Equatable {
        let contentHeight: CGFloat
        let viewportHeight: CGFloat
        let bottomInset: CGFloat
    }

    private struct IOSConversationScrollSample: Equatable {
        let layout: IOSConversationScrollLayout
        let atEnd: Bool
        let showsJumpToLatest: Bool
        let canScroll: Bool

        init(_ geometry: ScrollGeometry) {
            layout = IOSConversationScrollLayout(
                contentHeight: geometry.contentSize.height, viewportHeight: geometry.visibleRect.height,
                bottomInset: geometry.contentInsets.bottom)
            atEnd = IOSConversationScrollBehavior.isAtLatest(
                visibleMaxY: geometry.visibleRect.maxY, contentHeight: geometry.contentSize.height,
                bottomInset: geometry.contentInsets.bottom)
            showsJumpToLatest = IOSConversationScrollBehavior.shouldShowJumpToLatest(
                visibleMaxY: geometry.visibleRect.maxY, contentHeight: geometry.contentSize.height,
                bottomInset: geometry.contentInsets.bottom)
            canScroll = geometry.contentSize.height > geometry.visibleRect.height - geometry.contentInsets.bottom + 2
        }
    }

    // MARK: - Images

    /// A workspace image a transcript links to: the files surface reads it
    /// on the conversation's machine, resolving `file://` and absolute paths
    /// against the conversation's workspace.
    @MainActor
    @Observable
    private final class IOSConversationImages {
        var loadingTitle: String?
        var preview: IOSConversationImagePreview?
        @ObservationIgnored private var files: IOSFilesModel?
        @ObservationIgnored private var request = UUID()

        func open(
            _ destination: String, target: WorkspaceTarget, core: CoreClient, show: @MainActor (any Error) -> Void
        ) async {
            let requestID = UUID()
            request = requestID
            let title = (destination as NSString).lastPathComponent
            loadingTitle = title
            defer { if request == requestID { loadingTitle = nil } }
            let files =
                self.files
                ?? IOSFilesModel(scope: "ios-conversation-images-\(UUID().uuidString.lowercased())")
            self.files = files
            files.bind(target: target, core: core)
            await files.openFile(path: destination)
            guard request == requestID else { return }
            if let document = files.fileDocument,
                let image = UIImage(data: document.binary ? document.data : Data(document.content.utf8))
            {
                preview = IOSConversationImagePreview(title: title, image: image)
            } else {
                show(IOSConversationImageError(name: title, reason: files.fileError))
            }
        }
    }

    private struct IOSConversationImagePreview: Identifiable {
        let id = UUID()
        let title: String
        let image: UIImage
    }

    private struct IOSConversationImageError: LocalizedError {
        let name: String
        let reason: String?
        var errorDescription: String? { reason ?? "\(name) is not a supported image." }
    }

    private struct IOSConversationImageLightbox: View {
        @Environment(\.dismiss) private var dismiss
        let preview: IOSConversationImagePreview
        @State private var scale: CGFloat = 1
        @GestureState private var magnification: CGFloat = 1

        var body: some View {
            ZStack {
                Color.black.ignoresSafeArea()
                Image(uiImage: preview.image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(min(6, max(1, scale * magnification)))
                    .gesture(
                        MagnificationGesture()
                            .updating($magnification) { value, state, _ in state = value }
                            .onEnded { value in scale = min(6, max(1, scale * value)) }
                    )
                    .onTapGesture(count: 2) { withAnimation { scale = scale > 1 ? 1 : 2 } }
                    .padding(.horizontal, 8)
                    .accessibilityLabel(preview.title)
            }
            .overlay(alignment: .top) {
                HStack(spacing: 12) {
                    Text(preview.title).font(.headline).lineLimit(1)
                    Spacer(minLength: 8)
                    Button("Close", systemImage: "xmark") { dismiss() }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.circle)
                        .accessibilityIdentifier("ios.conversation.image-close")
                }
                .foregroundStyle(.white)
                .padding()
                .background(.black.opacity(0.72))
            }
            .statusBarHidden()
            .accessibilityIdentifier("ios.conversation.image-lightbox")
        }
    }
#endif
