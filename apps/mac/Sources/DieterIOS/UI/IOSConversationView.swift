#if os(iOS)
    import DieterAPI
    import SwiftUI

    struct IOSConversationView: View {
        @Bindable var store: IOSStore
        let cardID: String
        @Binding var draft: String
        let browseFiles: () -> Void
        @State private var sending = false
        @State private var followsLatest = true
        @State private var bottomVisible = false
        @State private var userScrolling = false
        @FocusState private var composerFocused: Bool

        private var card: Dieter_V1_Card? {
            guard store.selectedCard?.card.id == cardID else { return nil }
            return store.selectedCard?.card
        }

        private var messages: [Dieter_V1_UiMessage] {
            store.conversation?.cardID == cardID ? store.conversation?.messages ?? [] : []
        }

        private var isRunning: Bool {
            ["running", "starting", "resuming", "queued", "waiting"].contains(card?.runtime ?? "")
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
            ScrollViewReader { proxy in
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
                                    if let previousFirst { proxy.scrollTo(previousFirst, anchor: .top) }
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
                        ForEach(messages, id: \.id) { message in
                            IOSConversationMessage(message: message)
                                .id(message.id)
                                .accessibilityIdentifier("ios.message.\(message.id)")
                        }
                        if let queued = store.conversation?.queue.count, queued > 0 {
                            Label("\(queued) queued \(queued == 1 ? "message" : "messages")", systemImage: "clock")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Color.clear.frame(height: 1).id("latest")
                            .onAppear {
                                bottomVisible = true
                                followsLatest = true
                            }
                            .onDisappear {
                                bottomVisible = false
                                if userScrolling { followsLatest = false }
                            }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 20)
                    .frame(maxWidth: 900)
                    .frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("ios.conversation.transcript")
                .scrollDismissesKeyboard(.interactively)
                .onScrollPhaseChange { _, phase in
                    userScrolling = phase == .interacting || phase == .decelerating
                    if phase == .idle {
                        followsLatest = bottomVisible
                        if bottomVisible, !store.loadingOlder { store.trimHistoryAtBottom() }
                    }
                }
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .onChange(of: store.conversation?.lastSeq) { _, _ in
                    if followsLatest { proxy.scrollTo("latest", anchor: .bottom) }
                }
                .overlay(alignment: .bottom) {
                    if !bottomVisible, !messages.isEmpty {
                        Button("Jump to latest", systemImage: "arrow.down") {
                            followsLatest = true
                            withAnimation { proxy.scrollTo("latest", anchor: .bottom) }
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
        }

        private var composer: some View {
            VStack(spacing: 8) {
                if !store.phase.isConnected {
                    IOSConnectionBanner(title: store.phase.label, detail: "Your draft will stay here.") {
                        Task { await store.reconnect() }
                    }
                }
                HStack(alignment: .bottom, spacing: 10) {
                    TextField("Message the agent…", text: $draft, axis: .vertical)
                        .lineLimit(1...8)
                        .focused($composerFocused)
                        .padding(12)
                        .background(
                            Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18)
                        )
                        .accessibilityIdentifier("ios.composer.message")
                    Button {
                        let message = draft
                        sending = true
                        Task {
                            let accepted = await store.sendMessage(text: message)
                            if accepted, draft == message { draft = "" }
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
                        sending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || !store.phase.isConnected
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
                ForEach(Array(message.parts.enumerated()), id: \.offset) { _, part in
                    if part.type == "reasoning" {
                        DisclosureGroup("Reasoning") { IOSMessageText(text: part.text) }
                            .font(.subheadline).foregroundStyle(.secondary)
                    } else if !part.toolName.isEmpty || part.type.hasPrefix("tool-") {
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 8) {
                                if !part.inputPreview.isEmpty {
                                    Text(part.inputPreview).font(.system(.caption, design: .monospaced))
                                }
                                if !part.outputPreview.isEmpty {
                                    Text(part.outputPreview).font(.system(.caption, design: .monospaced))
                                }
                                if !part.errorText.isEmpty { Text(part.errorText).foregroundStyle(.red) }
                            }.textSelection(.enabled)
                        } label: {
                            Label(part.toolName.isEmpty ? "Tool activity" : part.toolName, systemImage: "terminal")
                        }
                        .font(.subheadline).foregroundStyle(.secondary)
                    } else if !part.text.isEmpty {
                        IOSMessageText(text: part.text)
                    } else if !part.filename.isEmpty {
                        Label(part.filename, systemImage: part.mediaType.hasPrefix("image/") ? "photo" : "doc")
                            .font(.subheadline).foregroundStyle(.secondary)
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
#endif
