#if os(iOS)
    import DieterAPI
    import PhotosUI
    import SwiftUI
    import UniformTypeIdentifiers

    struct IOSConversationView: View {
        @Bindable var store: IOSStore
        let cardID: String
        @Binding var draft: IOSConversationDraft
        let browseFiles: () -> Void
        @State private var sending = false
        @State private var followsLatest = true
        @State private var isAtLatest = false
        @State private var contentCanScroll = false
        @State private var userScrolling = false
        @State private var timelineReadyCardID: String?
        @State private var pageAnchorToRestore: String?
        @State private var pageRestoreRequest = 0
        @State private var attachmentError: String?
        @State private var photoItems: [PhotosPickerItem] = []
        @State private var fileImporterPresented = false
        @FocusState private var composerFocused: Bool

        private var card: Dieter_V1_Card? {
            if store.selectedCard?.card.id == cardID { return store.selectedCard?.card }
            return (store.cards + store.chats).first { $0.id == cardID }
        }

        private var timelineReady: Bool { timelineReadyCardID == cardID }

        private var messages: [Dieter_V1_UiMessage] {
            guard store.conversation?.cardID == cardID else { return [] }
            let queuedIDs = Set((store.conversation?.queue ?? []).lazy.map(\.id).filter { !$0.isEmpty })
            return (store.conversation?.messages ?? []).filter { !queuedIDs.contains($0.id) }
        }

        private var queue: [Dieter_V1_QueuedMessage] {
            store.conversation?.cardID == cardID ? store.conversation?.queue ?? [] : []
        }

        private var isRunning: Bool {
            IOSConversationPresentation.isAgentWorking(
                conversationStatus: store.conversation?.status ?? "", cardRuntime: card?.runtime ?? "")
        }

        var body: some View {
            Group {
                if let card, store.conversation?.cardID == cardID {
                    transcript(card)
                } else {
                    IOSConversationLoadingView(isChat: card?.scope == "chat")
                }
            }
            .navigationTitle(card?.title ?? "Conversation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    IOSProviderQuotaCompactView(store: store)
                    if isRunning {
                        Button("Stop task", systemImage: "stop.circle") { Task { await store.cancelTask() } }
                            .disabled(!store.phase.isConnected || store.busy)
                            .accessibilityIdentifier("ios.task.stop")
                    } else {
                        Button("Start task", systemImage: "play.circle") { Task { await store.startTask() } }
                            .disabled(card == nil || !store.phase.isConnected || store.busy)
                            .accessibilityIdentifier("ios.task.start")
                    }
                    Menu {
                        Button("Browse files", systemImage: "folder", action: browseFiles)
                            .accessibilityIdentifier("ios.task.files")
                        if card?.scope != "chat" {
                            Menu("Move task", systemImage: "rectangle.3.group") {
                                ForEach(["todo", "running", "review", "done"], id: \.self) { lane in
                                    Button(lane.capitalized) { Task { await store.moveTask(lane: lane) } }
                                        .accessibilityIdentifier("ios.task.move.\(lane)")
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Task actions")
                    .accessibilityIdentifier("ios.task.actions")
                    .disabled(card == nil || !store.phase.isConnected)
                }
            }
            .task(id: cardID) {
                timelineReadyCardID = nil
                followsLatest = true
                isAtLatest = false
                contentCanScroll = false
                userScrolling = false
                pageAnchorToRestore = nil
                pageRestoreRequest = 0
                await store.selectCard(id: cardID)
            }
            .fileImporter(
                isPresented: $fileImporterPresented,
                allowedContentTypes: [.item],
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls):
                    Task {
                        do {
                            draft.attachments = try await IOSAttachmentLoader().parts(
                                urls: urls, appendingTo: draft.attachments)
                            attachmentError = nil
                        } catch {
                            showAttachmentError(error)
                        }
                    }
                case .failure(let error):
                    if (error as NSError).code != NSUserCancelledError {
                        showAttachmentError(error)
                    }
                }
            }
            .onChange(of: photoItems) { _, items in
                guard !items.isEmpty else { return }
                photoItems = []
                Task {
                    do {
                        draft.attachments = try await IOSAttachmentLoader().parts(
                            photoItems: items, appendingTo: draft.attachments)
                        attachmentError = nil
                    } catch {
                        showAttachmentError(error)
                    }
                }
            }
        }

        private func transcript(_ card: Dieter_V1_Card) -> some View {
            ScrollViewReader { proxy in
                ZStack {
                    ScrollView {
                        // The transcript is bounded to 240 messages. An eager stack keeps every explicit
                        // scroll target alive while pages are prepended or the retained tail is compacted.
                        VStack(alignment: .leading, spacing: 22) {
                            HStack(spacing: 10) {
                                IOSStatusBadge(state: card.runtime)
                                Spacer(minLength: 12)
                                Label(card.model, systemImage: "sparkles")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 12)
                            .frame(minHeight: 36)
                            .background(.thinMaterial, in: Capsule())

                            if store.hasOlderMessages {
                                Button {
                                    loadOlderMessages(keeping: messages.first?.id)
                                } label: {
                                    HStack(spacing: 8) {
                                        if store.loadingOlder { ProgressView().controlSize(.small) }
                                        Text(
                                            store.loadingOlder
                                                ? "Loading earlier messages…" : "Load earlier messages")
                                    }
                                    .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                                .disabled(store.loadingOlder || !store.phase.isConnected)
                                .accessibilityIdentifier("ios.conversation.earlier")
                            }

                            if messages.isEmpty {
                                ContentUnavailableView(
                                    "Ready when you are", systemImage: "bubble.left.and.bubble.right",
                                    description: Text(
                                        card.initialPrompt.isEmpty ? "Send a message to begin." : card.initialPrompt)
                                )
                                .padding(.vertical, 32)
                            }

                            ForEach(IOSConversationPresentation.timelineItems(messages)) { item in
                                if item.isActivity {
                                    IOSConversationActivityDisclosure(steps: item.steps, identifier: item.id)
                                        .id(item.id)
                                } else if let message = item.messages.first {
                                    IOSConversationMessage(message: message)
                                        .id(item.id)
                                }
                            }

                            if isRunning {
                                IOSConversationTurnIndicator(
                                    startedAt: IOSConversationPresentation.turnStart(
                                        messages: messages, runtimeUpdatedAt: card.runtimeUpdatedAt),
                                    stopping: card.runtime.lowercased() == "cancelling"
                                )
                                .id("ios.conversation.agent-working")
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
                        contentCanScroll = current.canScroll
                        if userScrolling { followsLatest = current.atEnd }
                        if !timelineReady, current.atEnd { timelineReadyCardID = cardID }
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
                            if isAtLatest, !store.loadingOlder, store.trimHistoryAtBottom() {
                                requestLatestScroll(proxy)
                            }
                        }
                    }
                    .onChange(of: store.conversation?.lastSeq) { _, _ in
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
                        if timelineReady, contentCanScroll, !isAtLatest, !messages.isEmpty {
                            Button("Jump to latest", systemImage: "arrow.down") {
                                jumpToLatest(proxy)
                            }
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
                        IOSConversationLoadingView(isChat: card.scope == "chat", preparingTimeline: true)
                            .allowsHitTesting(false)
                    }
                }
                .task(id: cardID) {
                    // Give the eager stack more than one layout pass before revealing it. If a proxy request
                    // arrives before its target is mounted, the next pass repeats it and geometry still keeps
                    // the recovery button honest instead of claiming that an offset viewport is at the tail.
                    for _ in 0..<3 {
                        await Task.yield()
                        scroll(proxy, to: IOSConversationScrollBehavior.bottomID, anchor: .bottom)
                    }
                    await Task.yield()
                    timelineReadyCardID = cardID
                }
                .safeAreaInset(edge: .bottom, spacing: 0) { composer }
            }
        }

        private func loadOlderMessages(keeping anchor: String?) {
            guard let anchor else { return }
            followsLatest = false
            Task { @MainActor in
                let previousFirst = messages.first?.id
                await store.loadOlderMessages()
                guard previousFirst != messages.first?.id else {
                    return
                }
                pageAnchorToRestore = IOSConversationPresentation.anchorItem(
                    containing: anchor,
                    in: IOSConversationPresentation.timelineItems(messages))
                guard pageAnchorToRestore != nil else { return }
                pageRestoreRequest &+= 1
            }
        }

        private func jumpToLatest(_ proxy: ScrollViewProxy) {
            followsLatest = true
            if !store.loadingOlder { store.trimHistoryAtBottom() }
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

        private var composer: some View {
            VStack(spacing: 8) {
                if !store.phase.isConnected {
                    IOSConnectionBanner(title: store.phase.label, detail: "Your draft will stay here.") {
                        Task { await store.reconnect() }
                    }
                }
                if !queue.isEmpty {
                    IOSQueuedMessageTray(
                        store: store, messages: queue, agentIsWorking: isRunning, draft: $draft,
                        focusComposer: { composerFocused = true }
                    )
                    .frame(maxWidth: 900)
                }
                if !draft.attachments.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(Array(draft.attachments.enumerated()), id: \.offset) { index, attachment in
                                HStack(spacing: 6) {
                                    Image(systemName: attachment.mediaType.hasPrefix("image/") ? "photo" : "doc")
                                    Text(attachment.filename.isEmpty ? "Attachment" : attachment.filename)
                                        .lineLimit(1)
                                    Button("Remove attachment", systemImage: "xmark") {
                                        draft.attachments.remove(at: index)
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
                    startPoint: .top,
                    endPoint: .center
                )
                .ignoresSafeArea()
            }
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
            HStack(alignment: .bottom, spacing: 6) {
                PhotosPicker(
                    selection: $photoItems,
                    maxSelectionCount: max(
                        1, IOSAttachmentLoader.maximumCount - draft.attachments.count),
                    matching: .images
                ) {
                    Image(systemName: "photo")
                        .frame(width: 38, height: 42)
                }
                .modifier(IOSComposerAccessoryStyle())
                .disabled(draft.attachments.count >= IOSAttachmentLoader.maximumCount)
                .accessibilityLabel("Attach photos")
                .accessibilityIdentifier("ios.composer.attach-photos")

                Button {
                    composerFocused = false
                    fileImporterPresented = true
                } label: {
                    Image(systemName: "paperclip")
                        .frame(width: 38, height: 42)
                }
                .modifier(IOSComposerAccessoryStyle())
                .disabled(draft.attachments.count >= IOSAttachmentLoader.maximumCount)
                .accessibilityLabel("Attach files")
                .accessibilityIdentifier("ios.composer.attach-files")

                IOSAttachmentTextEditor(
                    text: $draft.text,
                    isFocused: Binding(
                        get: { composerFocused },
                        set: { composerFocused = $0 }
                    ),
                    placeholder: "Message Dieter…",
                    minimumLines: 1,
                    maximumLines: 8,
                    accessibilityIdentifier: "ios.composer.message",
                    pastedImages: appendPastedImages,
                    pasteFailed: showAttachmentError
                )
                .padding(.horizontal, 8).padding(.vertical, 4)
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture().onEnded { composerFocused = true })

                Button(action: sendDraft) {
                    Group {
                        if sending {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "arrow.up").font(.headline)
                        }
                    }
                    .frame(width: 42, height: 42)
                }
                .modifier(IOSComposerSendStyle())
                .disabled(sending || draft.isEmpty || !store.phase.isConnected)
                .accessibilityLabel("Send message")
                .accessibilityIdentifier("ios.composer.send")
            }
        }

        private func sendDraft() {
            let message = draft
            followsLatest = true
            sending = true
            Task { @MainActor in
                let accepted = await store.sendMessage(
                    text: message.text, attachments: message.attachments, selection: message.selection)
                if accepted, draft.text == message.text,
                    IOSConversationPresentation.attachmentIdentity(draft.attachments)
                        == IOSConversationPresentation.attachmentIdentity(message.attachments),
                    draft.selection == message.selection
                {
                    draft = IOSConversationDraft()
                }
                sending = false
            }
        }

        private func appendPastedImages(_ payloads: [IOSAttachmentPayload]) {
            Task {
                do {
                    draft.attachments = try await IOSAttachmentLoader().parts(
                        payloads: payloads,
                        appendingTo: draft.attachments)
                    attachmentError = nil
                } catch {
                    showAttachmentError(error)
                }
            }
        }

        private func showAttachmentError(_ error: Error) {
            attachmentError = error.localizedDescription
        }
    }

    private struct IOSConversationLoadingView: View {
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
                    Text("Dieter is setting the table")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                RadialGradient(
                    colors: [Color.accentColor.opacity(0.08), .clear],
                    center: .center,
                    startRadius: 0,
                    endRadius: 220)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("ios.conversation.loading")
        }
    }

    private struct IOSDieterActivityGlyph: View {
        let size: CGFloat
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var rotation = Angle.zero
        @State private var breathing = false

        var body: some View {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.16))
                    .frame(width: size * 1.18, height: size * 1.18)
                    .blur(radius: size * 0.17)
                    .scaleEffect(breathing ? 1.08 : 0.92)
                Circle()
                    .stroke(Color.accentColor.opacity(0.14), lineWidth: max(1, size * 0.025))
                    .frame(width: size, height: size)
                Circle()
                    .trim(from: 0.08, to: 0.73)
                    .stroke(
                        AngularGradient(
                            colors: [.clear, Color.accentColor.opacity(0.35), .accentColor, .clear],
                            center: .center),
                        style: StrokeStyle(lineWidth: max(2, size * 0.055), lineCap: .round)
                    )
                    .frame(width: size, height: size)
                    .rotationEffect(rotation)
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: size * 0.67, height: size * 0.67)
                    .overlay(Circle().stroke(.white.opacity(0.22), lineWidth: 0.75))
                Image(systemName: "fork.knife")
                    .font(.system(size: size * 0.27, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: size * 1.25, height: size * 1.25)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.7).repeatForever(autoreverses: false)) {
                    rotation = .degrees(360)
                }
                withAnimation(.easeInOut(duration: 1.15).repeatForever(autoreverses: true)) {
                    breathing = true
                }
            }
            .accessibilityHidden(true)
        }
    }

    private struct IOSConversationTurnIndicator: View {
        let startedAt: Date?
        let stopping: Bool
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var shimmer = false

        private var label: String { stopping ? "Dieter is stopping…" : "Dieter is working…" }

        var body: some View {
            HStack(spacing: 9) {
                IOSDieterActivityGlyph(size: 16)
                Text(label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .overlay {
                        if !reduceMotion {
                            GeometryReader { geometry in
                                LinearGradient(
                                    colors: [.clear, .primary.opacity(0.8), .clear],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                                .frame(width: geometry.size.width)
                                .offset(x: shimmer ? geometry.size.width : -geometry.size.width)
                            }
                            .mask(Text(label).font(.caption.weight(.medium)))
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                        }
                    }
                    .lineLimit(1)
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

    private struct IOSConversationScrollLayout: Equatable {
        let contentHeight: CGFloat
        let viewportHeight: CGFloat
        let bottomInset: CGFloat
    }

    private struct IOSConversationScrollSample: Equatable {
        let layout: IOSConversationScrollLayout
        let atEnd: Bool
        let canScroll: Bool

        init(_ geometry: ScrollGeometry) {
            layout = IOSConversationScrollLayout(
                contentHeight: geometry.contentSize.height,
                viewportHeight: geometry.visibleRect.height,
                bottomInset: geometry.contentInsets.bottom)
            atEnd = IOSConversationScrollBehavior.isAtLatest(
                visibleMaxY: geometry.visibleRect.maxY,
                contentHeight: geometry.contentSize.height,
                bottomInset: geometry.contentInsets.bottom)
            canScroll = geometry.contentSize.height > geometry.visibleRect.height - geometry.contentInsets.bottom + 2
        }
    }

    private struct IOSFloatingGlassModifier<GlassShape: Shape>: ViewModifier {
        let shape: GlassShape

        @ViewBuilder func body(content: Content) -> some View {
            if #available(iOS 26.0, *) {
                content.glassEffect(.regular.interactive(), in: shape)
            } else {
                content
                    .background(.ultraThinMaterial, in: shape)
                    .overlay(shape.stroke(Color.secondary.opacity(0.18), lineWidth: 0.75))
            }
        }
    }

    private struct IOSComposerAccessoryStyle: ViewModifier {
        @ViewBuilder func body(content: Content) -> some View {
            if #available(iOS 26.0, *) {
                content.buttonStyle(.glass).buttonBorderShape(.circle)
            } else {
                content.buttonStyle(.plain).foregroundStyle(Color.accentColor)
            }
        }
    }

    private struct IOSComposerSendStyle: ViewModifier {
        @ViewBuilder func body(content: Content) -> some View {
            if #available(iOS 26.0, *) {
                content.buttonStyle(.glassProminent).buttonBorderShape(.circle)
            } else {
                content.buttonStyle(.borderedProminent).buttonBorderShape(.circle)
            }
        }
    }

    private struct IOSConversationMessage: View {
        let message: Dieter_V1_UiMessage

        private var isUser: Bool { ["user", "human"].contains(message.role.lowercased()) }

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                Label(isUser ? "You" : "Dieter", systemImage: isUser ? "person.fill" : "sparkles")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isUser ? Color.accentColor : Color.secondary)
                ForEach(IOSConversationPresentation.partGroups(in: message)) { group in
                    if group.isActivity {
                        IOSConversationActivityDisclosure(steps: group.steps, identifier: group.id)
                    } else {
                        ForEach(group.steps) { step in
                            IOSConversationPart(messageID: step.messageID, part: step.part, role: message.role)
                        }
                    }
                }
            }
            .padding(isUser ? 14 : 0)
            .background {
                if isUser {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.accentColor.opacity(0.10))
                        .overlay {
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .stroke(Color.accentColor.opacity(0.16), lineWidth: 0.75)
                        }
                }
            }
            .padding(.leading, isUser ? 34 : 0)
            .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        }
    }

    private struct IOSConversationActivityDisclosure: View {
        let steps: [IOSConversationActivityStep]
        let identifier: String
        @State private var expanded = false

        var body: some View {
            DisclosureGroup(isExpanded: $expanded) {
                if expanded {
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(steps) { step in
                            if IOSConversationPresentation.isReasoning(step.part) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Reasoning").font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                                    IOSMessageText(text: step.part.text)
                                }
                            } else {
                                IOSToolPart(messageID: step.messageID, part: step.part)
                            }
                        }
                    }
                    .padding(.top, 6)
                }
            } label: {
                Label(IOSConversationActivitySummary(steps: steps).title, systemImage: "waveform.path.ecg")
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityIdentifier("ios.conversation.activity.\(identifier)")
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
        }
    }

    private struct IOSConversationPart: View {
        let messageID: String
        let part: Dieter_V1_MessagePart
        let role: String

        var body: some View {
            if IOSConversationPresentation.isReasoning(part) {
                DisclosureGroup("Reasoning") { IOSMessageText(text: part.text) }
                    .font(.subheadline).foregroundStyle(.secondary)
            } else if IOSConversationPresentation.isToolCall(part) {
                IOSToolPart(messageID: messageID, part: part)
            } else if !part.text.isEmpty {
                IOSMessageText(text: part.text)
                    .accessibilityIdentifier("ios.message.text.\(role)")
            } else if !part.filename.isEmpty {
                Label(part.filename, systemImage: part.mediaType.hasPrefix("image/") ? "photo" : "doc")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private struct IOSToolPart: View {
        let messageID: String
        let part: Dieter_V1_MessagePart
        @State private var expanded = false

        private var name: String {
            let value = IOSConversationPresentation.effectiveToolName(part)
            return value.isEmpty ? "Command" : value
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                DisclosureGroup(isExpanded: $expanded) {
                    if expanded {
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
                            systemName: IOSConversationPresentation.needsAttention(part)
                                ? "exclamationmark.circle" : "terminal"
                        )
                        Text(name).font(.system(.caption, design: .monospaced).weight(.medium)).lineLimit(1)
                        Spacer(minLength: 8)
                        if !part.state.isEmpty {
                            Text(part.state.replacingOccurrences(of: "_", with: " "))
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
                .font(.subheadline)
                .foregroundStyle(IOSConversationPresentation.needsAttention(part) ? Color.orange : Color.secondary)
                if IOSConversationPresentation.needsAttention(part), !part.errorText.isEmpty, !expanded {
                    Text(part.errorText).font(.caption.monospaced()).foregroundStyle(.red)
                }
            }
            .accessibilityIdentifier(
                "ios.conversation.tool.\(messageID).\(part.toolCallID.isEmpty ? name : part.toolCallID)")
        }
    }

    private struct IOSQueuedMessageTray: View {
        @Bindable var store: IOSStore
        let messages: [Dieter_V1_QueuedMessage]
        let agentIsWorking: Bool
        @Binding var draft: IOSConversationDraft
        let focusComposer: () -> Void

        var body: some View {
            ScrollView(.vertical) {
                LazyVStack(spacing: 7) {
                    ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                        IOSQueuedMessageRow(
                            store: store, message: message,
                            canSteer: index == 0 && agentIsWorking,
                            draft: $draft, focusComposer: focusComposer
                        )
                    }
                }
            }
            .scrollIndicators(.hidden)
            .frame(height: min(CGFloat(messages.count) * 68, 196))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Queued messages")
            .accessibilityIdentifier("ios.conversation.queue")
        }
    }

    private struct IOSQueuedMessageRow: View {
        private enum Action { case edit, remove, steer }

        @Bindable var store: IOSStore
        let message: Dieter_V1_QueuedMessage
        let canSteer: Bool
        @Binding var draft: IOSConversationDraft
        let focusComposer: () -> Void
        @State private var action: Action?

        private var queuedDraft: IOSConversationDraft {
            IOSConversationPresentation.queuedDraft(for: message)
        }

        private var summary: String {
            if !queuedDraft.text.isEmpty { return queuedDraft.text }
            if queuedDraft.attachments.count == 1 { return "1 attachment" }
            if !queuedDraft.attachments.isEmpty { return "\(queuedDraft.attachments.count) attachments" }
            return "Queued message"
        }

        var body: some View {
            HStack(spacing: 10) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary).font(.subheadline.weight(.medium)).lineLimit(2)
                    HStack(spacing: 5) {
                        Text("Queued")
                        if !queuedDraft.attachments.isEmpty {
                            Text(
                                "· \(queuedDraft.attachments.count) attachment"
                                    + (queuedDraft.attachments.count == 1 ? "" : "s"))
                        }
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if canSteer {
                    Button(action == .steer ? "Steering…" : "Steer") { performSteer() }
                        .buttonStyle(.bordered).controlSize(.small)
                        .disabled(action != nil || store.busy || !store.phase.isConnected)
                        .accessibilityIdentifier("ios.queued-message.steer.\(message.id)")
                }
                Menu {
                    Button("Edit queued message", systemImage: "pencil") { performEdit() }
                    Button("Remove queued message", systemImage: "trash", role: .destructive) { performRemove() }
                } label: {
                    if action == .edit || action == .remove {
                        ProgressView()
                    } else {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                .disabled(action != nil || store.busy || !store.phase.isConnected)
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

        private func performEdit() {
            guard action == nil else { return }
            action = .edit
            Task { @MainActor in
                if let removed = await store.removeQueuedMessage(message) {
                    let restored = IOSConversationPresentation.queuedDraft(for: removed)
                    var next = draft
                    next.text = [restored.text, next.text].filter { !$0.isEmpty }.joined(separator: "\n\n")
                    next.attachments = restored.attachments + next.attachments
                    if let selection = restored.selection { next.selection = selection }
                    draft = next
                    focusComposer()
                }
                action = nil
            }
        }

        private func performRemove() {
            guard action == nil else { return }
            action = .remove
            Task { @MainActor in
                _ = await store.removeQueuedMessage(message)
                action = nil
            }
        }

        private func performSteer() {
            guard action == nil, canSteer else { return }
            action = .steer
            Task { @MainActor in
                await store.steerQueuedMessage(message)
                action = nil
            }
        }
    }
#endif
