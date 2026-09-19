#if os(iOS)
    import DieterAPI
    import SwiftUI

    struct IOSConversationView: View {
        @Bindable var store: IOSStore
        let cardID: String
        @Binding var draft: IOSConversationDraft
        let browseFiles: () -> Void
        @State private var sending = false
        @State private var followsLatest = true
        @State private var bottomVisible = false
        @State private var userScrolling = false
        @State private var scrollPosition = ScrollPosition(edge: .bottom)
        @FocusState private var composerFocused: Bool

        private var card: Dieter_V1_Card? {
            guard store.selectedCard?.card.id == cardID else { return nil }
            return store.selectedCard?.card
        }

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
                if let card {
                    transcript(card)
                } else {
                    ProgressView("Opening task…").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(card?.title ?? "Task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
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
            .task(id: cardID) { await store.selectCard(id: cardID) }
        }

        private func transcript(_ card: Dieter_V1_Card) -> some View {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    HStack {
                        IOSStatusBadge(state: card.runtime)
                        Spacer()
                        Text(card.model).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if store.hasOlderMessages {
                        Button {
                            let previousFirst = messages.first?.id
                            followsLatest = false
                            Task {
                                await store.loadOlderMessages()
                                if let previousFirst { scrollPosition.scrollTo(id: previousFirst, anchor: .top) }
                            }
                        } label: {
                            HStack {
                                if store.loadingOlder { ProgressView() }
                                Text(store.loadingOlder ? "Loading earlier messages…" : "Load earlier messages")
                            }.frame(maxWidth: .infinity)
                        }
                        .disabled(store.loadingOlder || !store.phase.isConnected)
                        .accessibilityIdentifier("ios.conversation.earlier")
                    }
                    if messages.isEmpty {
                        ContentUnavailableView(
                            "Ready when you are", systemImage: "bubble.left",
                            description: Text(
                                card.initialPrompt.isEmpty ? "Send a message to begin." : card.initialPrompt))
                    }
                    ForEach(IOSConversationPresentation.timelineItems(messages)) { item in
                        if item.isActivity {
                            IOSConversationActivityDisclosure(steps: item.steps, identifier: item.id)
                                .id(item.id)
                        } else if let message = item.messages.first {
                            IOSConversationMessage(message: message)
                                .id(message.id)
                        }
                    }
                    Color.clear.frame(height: 1)
                        .onAppear {
                            bottomVisible = true
                            followsLatest = true
                        }
                        .onDisappear {
                            bottomVisible = false
                            if userScrolling { followsLatest = false }
                        }
                }
                .scrollTargetLayout()
                .padding(.horizontal, 20)
                .padding(.vertical, 20)
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
            }
            .accessibilityIdentifier("ios.conversation.transcript")
            .scrollDismissesKeyboard(.interactively)
            .scrollPosition($scrollPosition)
            .onScrollPhaseChange { _, phase in
                userScrolling = phase == .interacting || phase == .decelerating
                if phase == .idle {
                    followsLatest = bottomVisible
                    if bottomVisible, !store.loadingOlder, store.trimHistoryAtBottom() {
                        scrollPosition.scrollTo(edge: .bottom)
                    }
                }
            }
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .onChange(of: store.conversation?.lastSeq) { _, _ in
                if followsLatest { scrollPosition.scrollTo(edge: .bottom) }
            }
            .overlay(alignment: .bottom) {
                if !bottomVisible, !messages.isEmpty {
                    Button("Jump to latest", systemImage: "arrow.down") {
                        followsLatest = true
                        // Compact first, then pin the real edge of the shorter lazy stack. Retaining the old
                        // sentinel offset can leave the viewport below the content as an empty dark screen.
                        if !store.loadingOlder { store.trimHistoryAtBottom() }
                        scrollPosition.scrollTo(edge: .bottom)
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 10)
                    .accessibilityIdentifier("ios.conversation.latest")
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { composer }
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
                                .background(Color(uiColor: .secondarySystemGroupedBackground), in: Capsule())
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                    .frame(maxWidth: 900, alignment: .leading)
                    .accessibilityIdentifier("ios.composer.attachments")
                }
                HStack(alignment: .bottom, spacing: 10) {
                    TextField("Message the agent…", text: $draft.text, axis: .vertical)
                        .lineLimit(1...8)
                        .focused($composerFocused)
                        .padding(12)
                        .background(
                            Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18)
                        )
                        .contentShape(Rectangle())
                        .simultaneousGesture(TapGesture().onEnded { composerFocused = true })
                        .accessibilityIdentifier("ios.composer.message")
                    Button {
                        let message = draft
                        sending = true
                        Task {
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
                            followsLatest = true
                        }
                    } label: {
                        Group {
                            if sending {
                                ProgressView().tint(.white)
                            } else {
                                Image(systemName: "arrow.up").font(.headline)
                            }
                        }
                        .frame(width: 42, height: 42)
                    }
                    .buttonStyle(.borderedProminent).buttonBorderShape(.circle)
                    .disabled(
                        sending || draft.isEmpty || !store.phase.isConnected
                    )
                    .accessibilityLabel("Send message")
                    .accessibilityIdentifier("ios.composer.send")
                }
                .frame(maxWidth: 900)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(.bar)
        }
    }

    private struct IOSConversationMessage: View {
        let message: Dieter_V1_UiMessage

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                Text(message.role == "user" ? "You" : message.role.capitalized)
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
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
            .padding(message.role == "user" ? 14 : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if message.role == "user" {
                    RoundedRectangle(cornerRadius: 18).fill(Color(uiColor: .secondarySystemBackground))
                }
            }
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
                Text(IOSConversationActivitySummary(steps: steps).title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
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
