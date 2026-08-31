import DieterAPI
import SwiftUI
import UniformTypeIdentifiers

struct ChatsView: View {
    @Environment(DieterStore.self) private var store
    @State private var search = ""
    @State private var showArchived = false
    @State private var expandedProjects: Set<String> = []
    @State private var collapsedProjects: Set<String> = []
    @State private var pinnedChatNavigation = PinnedChatNavigationPreferences.load(
        from: DieterAppearance.applicationDefaults()
    )

    private var visibleChats: [Dieter_V1_Card] {
        store.chats
            .filter { chat in
                chat.scope == "chat" && chat.boardID.isEmpty && chat.archived == showArchived &&
                    (search.isEmpty || chat.title.localizedCaseInsensitiveContains(search) || chat.summary.localizedCaseInsensitiveContains(search))
            }
            .sorted { ($0.lastActivityAt.isEmpty ? $0.updatedAt : $0.lastActivityAt) > ($1.lastActivityAt.isEmpty ? $1.updatedAt : $1.lastActivityAt) }
    }

    private var activePinnedChats: [Dieter_V1_Card] {
        store.chats
            .filter { $0.scope == "chat" && $0.boardID.isEmpty && !$0.archived && $0.pinned }
            .sorted { ($0.lastActivityAt.isEmpty ? $0.updatedAt : $0.lastActivityAt) > ($1.lastActivityAt.isEmpty ? $1.updatedAt : $1.lastActivityAt) }
    }

    private var pinnedChatMembership: [String] {
        activePinnedChats.map(\.id).sorted()
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                FluidPaneChrome(background: DieterTheme.sidebar, spacing: 9) {
                    HStack(spacing: 8) {
                        PaneTitleBlock(
                            title: showArchived ? "Archived chats" : "Chats",
                            subtitle: "\(visibleChats.count) conversation\(visibleChats.count == 1 ? "" : "s")",
                            prominent: true
                        )
                        Button {
                            showArchived.toggle()
                            store.closeConversation()
                        } label: { Image(systemName: showArchived ? "archivebox.fill" : "archivebox") }
                        .buttonStyle(DieterIconButtonStyle(active: showArchived)).help(showArchived ? "Show active chats" : "Show archived chats")
                        Button { store.beginStandaloneChat() } label: { Label("New chat", systemImage: "plus") }
                            .buttonStyle(DieterPrimaryButtonStyle()).disabled(showArchived).help("New standalone chat")
                            .accessibilityIdentifier("chats.new")
                    }
                } secondary: {
                    DieterSearchField(text: $search, placeholder: "Search chats")
                }

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        let pinned = showArchived ? [] : PinnedChatOrdering.ordered(
                            visibleChats.filter(\.pinned),
                            preferredOrder: pinnedChatNavigation.chatOrder
                        )
                        if !pinned.isEmpty {
                            VStack(alignment: .leading, spacing: 5) {
                                Label("PINNED", systemImage: "pin.fill").font(DieterFont.sectionLabel).foregroundStyle(DieterTheme.tertiary).padding(.horizontal, 8)
                                ChatGroupCard(chats: pinned, movePinnedChat: movePinnedChat).padding(.leading, 14)
                            }
                        }

                        Text(showArchived ? "ARCHIVED PROJECTS" : "PROJECTS")
                            .font(DieterFont.sectionLabel).tracking(0.8).foregroundStyle(DieterTheme.tertiary).padding(.horizontal, 8).padding(.top, 3)

                        ForEach(store.projects.filter { !$0.archived }, id: \.id) { project in
                            let projectChats = visibleChats.filter { $0.projectID == project.id && (showArchived || !$0.pinned) }
                            if search.isEmpty || !projectChats.isEmpty {
                                ChatProjectGroup(
                                    project: project,
                                    chats: projectChats,
                                    showArchived: showArchived,
                                    expanded: expandedProjects.contains(project.id),
                                    collapsed: collapsedProjects.contains(project.id),
                                    toggleExpanded: { toggle(project.id, in: &expandedProjects) },
                                    toggleCollapsed: { toggle(project.id, in: &collapsedProjects) }
                                )
                            }
                        }

                        if visibleChats.isEmpty {
                            ContentUnavailableView(
                                search.isEmpty ? (showArchived ? "No archived chats" : "No chats yet") : "No matching chats",
                                systemImage: showArchived ? "archivebox" : "bubble.left.and.bubble.right",
                                description: Text(showArchived ? "Archived standalone conversations appear here." : "Start a standalone conversation in any project folder.")
                            )
                            .padding(.vertical, 32)
                        }
                    }.padding(.horizontal, 8).padding(.vertical, 11)
                }
            }
            .frame(minWidth: 285, idealWidth: DieterMetrics.browserWidth, maxWidth: DieterMetrics.browserMaximumWidth)
            .background(DieterTheme.sidebar)

            if store.selectedChatID != nil {
                ConversationView()
            } else if showArchived {
                VStack(spacing: 0) {
                    FluidPaneChrome {
                        PaneTitleBlock(title: "Archived conversations", subtitle: "Select a chat to inspect or restore", symbol: "archivebox")
                    }
                    VStack(spacing: 10) {
                        Image(systemName: "archivebox").font(.system(size: 34)).foregroundStyle(.secondary)
                        Text("Archived chats").font(.title2.weight(.bold))
                        Text("Select a conversation to restore or review it.").foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity).background(DieterTheme.background)
                }
            } else {
                StandaloneChatStartView()
            }
        }
        .task { await store.refreshChats() }
        .task(id: pinnedChatMembership) { initializePinnedChatOrderIfNeeded() }
    }

    private func toggle(_ id: String, in values: inout Set<String>) {
        if values.contains(id) { values.remove(id) } else { values.insert(id) }
    }

    private func initializePinnedChatOrderIfNeeded() {
        guard pinnedChatNavigation.initializeIfNeeded(with: activePinnedChats.map(\.id)) else { return }
        pinnedChatNavigation.save(to: DieterAppearance.applicationDefaults())
    }

    private func movePinnedChat(_ chatID: String, to targetChatID: String) {
        guard pinnedChatNavigation.move(chatID, to: targetChatID, among: activePinnedChats) else { return }
        pinnedChatNavigation.save(to: DieterAppearance.applicationDefaults())
    }
}

private struct ChatProjectGroup: View {
    @Environment(DieterStore.self) private var store
    let project: Dieter_V1_Project
    let chats: [Dieter_V1_Card]
    let showArchived: Bool
    let expanded: Bool
    let collapsed: Bool
    let toggleExpanded: () -> Void
    let toggleCollapsed: () -> Void

    private var displayed: [Dieter_V1_Card] {
        expanded ? chats : Array(chats.prefix(5))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Button(action: toggleCollapsed) {
                    HStack(spacing: 7) {
                        Image(systemName: collapsed ? "chevron.right" : "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(DieterTheme.tertiary)
                        Image(systemName: "folder").font(.system(size: 10)).foregroundStyle(DieterTheme.tertiary)
                        Text(project.name.uppercased()).font(DieterFont.sectionLabel).tracking(0.8).lineLimit(1).foregroundStyle(DieterTheme.subtle)
                        Text("· \(chats.count)").font(.system(size: 10)).foregroundStyle(DieterTheme.tertiary)
                    }
                }.buttonStyle(.plain)
                Spacer()
                if !showArchived {
                    Button { store.beginStandaloneChat(projectID: project.id) } label: { Image(systemName: "plus").font(.system(size: 9, weight: .bold)) }
                        .buttonStyle(.plain).help("New chat in \(project.name)")
                }
            }.padding(.horizontal, 8).frame(height: 24)

            if !collapsed {
                if chats.isEmpty {
                    Text(showArchived ? "No archived chats" : "No chats").font(.caption).foregroundStyle(.tertiary).padding(.leading, 36).padding(.vertical, 2)
                } else {
                    ChatGroupCard(chats: displayed) {
                        if chats.count > 5 {
                            ChatRowSeparator()
                            Button(action: toggleExpanded) {
                                HStack(spacing: 5) {
                                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 7, weight: .bold))
                                    Text(expanded ? "Show fewer" : "Show \(chats.count - 5) more")
                                }
                                .font(.system(size: 10.5, weight: .medium)).foregroundStyle(DieterTheme.subtle)
                                .padding(.leading, 27).padding(.vertical, 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                    .padding(.leading, 14)
                }
            }
        }
    }
}

/// Inset container that gives a project's conversations one bounded surface,
/// with hairline separators between rows for legible scanning.
private struct ChatGroupCard<Footer: View>: View {
    let chats: [Dieter_V1_Card]
    let footer: Footer
    let movePinnedChat: ((String, String) -> Void)?

    init(chats: [Dieter_V1_Card], @ViewBuilder footer: () -> Footer) {
        self.chats = chats
        self.footer = footer()
        movePinnedChat = nil
    }

    init(chats: [Dieter_V1_Card]) where Footer == EmptyView {
        self.chats = chats
        footer = EmptyView()
        movePinnedChat = nil
    }

    init(chats: [Dieter_V1_Card], movePinnedChat: @escaping (String, String) -> Void) where Footer == EmptyView {
        self.chats = chats
        footer = EmptyView()
        self.movePinnedChat = movePinnedChat
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(chats.enumerated()), id: \.element.id) { index, chat in
                if index > 0 { ChatRowSeparator() }
                if let movePinnedChat {
                    PinnedChatRow(card: chat) { draggedChatID in
                        movePinnedChat(draggedChatID, chat.id)
                    }
                } else {
                    ChatRow(card: chat)
                }
            }
            footer
        }
        .padding(3)
        .dieterSurface(radius: DieterMetrics.cardRadius)
    }
}

private struct ChatRowSeparator: View {
    var body: some View {
        Rectangle().fill(DieterTheme.border).frame(height: 1).padding(.leading, 27).padding(.trailing, 4)
    }
}

struct ChatRow: View {
    @Environment(DieterStore.self) private var store
    let card: Dieter_V1_Card
    let showsPinnedDragHandle: Bool
    @State private var hovering = false
    @State private var renamePresented = false
    @State private var renameText = ""

    private var unread: Bool { store.isChatUnread(card) }

    init(card: Dieter_V1_Card, showsPinnedDragHandle: Bool = false) {
        self.card = card
        self.showsPinnedDragHandle = showsPinnedDragHandle
    }

    var body: some View {
        Button {
            Task {
                if card.archived { await store.archive(card, archived: false) }
                await store.openConversation(cardID: card.id, chat: true)
            }
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Group {
                    if ["running", "starting"].contains(card.runtime) {
                        DieterActivityIndicator(color: runtimeColor(card.runtime))
                            .accessibilityLabel("Running")
                    } else {
                        ZStack {
                            Circle().stroke(runtimeColor(card.runtime).opacity(0.35), lineWidth: 1.5).frame(width: 11, height: 11)
                            Circle().fill(runtimeColor(card.runtime)).frame(width: 5, height: 5)
                        }
                    }
                }
                .padding(.top, 3)
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(card.title.isEmpty ? "Untitled chat" : card.title)
                            .font(.system(size: 12.5, weight: unread ? .semibold : .medium))
                            .lineLimit(1)
                        if card.pinned { Image(systemName: "pin.fill").font(.system(size: 8)).foregroundStyle(DieterTheme.shell) }
                        if card.archived { Image(systemName: "archivebox.fill").font(.system(size: 8)).foregroundStyle(DieterTheme.tertiary) }
                        Spacer()
                        HStack(spacing: 5) {
                            if unread {
                                Circle().fill(DieterTheme.primary).frame(width: 6.5, height: 6.5)
                                    .accessibilityLabel("Unread")
                            }
                            Text(ChatActivityText.compact(
                                card.lastActivityAt.isEmpty ? card.updatedAt : card.lastActivityAt,
                                relativeTo: .now
                            ))
                            .fixedSize()
                            if showsPinnedDragHandle {
                                Image(systemName: "line.3.horizontal")
                                    .font(.system(size: 10, weight: .semibold))
                                    .help("Drag to reorder pinned chats")
                            }
                        }
                        .font(.system(size: 10, weight: unread ? .semibold : .medium))
                        .foregroundStyle(unread ? DieterTheme.primary : DieterTheme.tertiary)
                    }
                    HStack(spacing: 6) {
                        if ["running", "starting"].contains(card.runtime) { Text("Running").foregroundStyle(DieterTheme.primary) }
                        else if !card.summary.isEmpty { Text(card.summary).lineLimit(1) }
                        if !card.workspaceMode.isEmpty { WorkspaceSummaryBadge(card: card, compact: true) }
                        if !card.activeSubagents.isEmpty {
                            Text("· \(card.activeSubagents.count) subagent\(card.activeSubagents.count == 1 ? "" : "s")").foregroundStyle(DieterTheme.subtle)
                        }
                    }
                    .font(.system(size: 10)).foregroundStyle(DieterTheme.tertiary)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
            .background(store.selectedChatID == card.id ? DieterTheme.selection : (hovering ? DieterTheme.raised.opacity(0.75) : .clear), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .opacity(store.isPendingCard(card.id) ? 0.52 : 1)
            .overlay(alignment: .bottomTrailing) {
                if store.isPendingCard(card.id) {
                    Image(systemName: store.isFailedOutboxItem(card.id) ? "exclamationmark.circle.fill" : "clock")
                        .font(.caption2)
                        .foregroundStyle(store.isFailedOutboxItem(card.id) ? DieterTheme.coral : DieterTheme.tertiary)
                        .padding(5)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            if store.isFailedOutboxItem(card.id) {
                Button("Retry queued creation") { Task { await store.retryOutboxItem(card.id) } }
                Button("Discard queued creation", role: .destructive) { Task { await store.discardOutboxItem(card.id) } }
                Divider()
            }
            if card.archived {
                Button("Restore") { Task { await store.archive(card, archived: false) } }
            } else {
                Button(card.pinned ? "Unpin" : "Pin") { Task { await store.pin(card, pinned: !card.pinned) } }
            }
            Button("Rename…", systemImage: "pencil") {
                renameText = card.title
                renamePresented = true
            }
            if !card.archived {
                Divider()
                Button("Archive", role: .destructive) { Task { await store.archive(card, archived: true) } }
            }
        }
        .accessibilityIdentifier("chat.\(card.id)")
        .sheet(isPresented: $renamePresented) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Rename chat").font(.title2.weight(.bold))
                TextField("Title", text: $renameText)
                    .accessibilityIdentifier("chat.rename.title")
                    .onSubmit { rename() }
                HStack {
                    Spacer()
                    Button("Cancel") { renamePresented = false }
                    Button("Rename") { rename() }
                        .buttonStyle(.borderedProminent)
                        .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("chat.rename.confirm")
                }
            }
            .padding(22)
            .frame(width: 440)
        }
    }

    private func rename() {
        let title = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        Task { await store.rename(card, title: title) }
        renamePresented = false
    }
}

private struct PinnedChatRow: View {
    let card: Dieter_V1_Card
    let moveDraggedChat: (String) -> Void
    @State private var dropTargeted = false

    var body: some View {
        ChatRow(card: card, showsPinnedDragHandle: true)
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(dropTargeted ? DieterTheme.shell : .clear, lineWidth: 1.5)
                    .padding(.horizontal, 1)
                    .allowsHitTesting(false)
            }
            .draggable(PinnedChatDragPayload(chatID: card.id).encoded) {
                PinnedChatDragPreview(card: card)
            }
            .dropDestination(for: String.self) { values, _ in
                guard let value = values.first,
                      let payload = PinnedChatDragPayload(value),
                      payload.chatID != card.id else { return false }
                moveDraggedChat(payload.chatID)
                return true
            } isTargeted: { dropTargeted = $0 }
            .animation(.easeOut(duration: 0.12), value: dropTargeted)
            .accessibilityHint("Drag to reorder pinned chats")
    }
}

private struct PinnedChatDragPreview: View {
    let card: Dieter_V1_Card

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "pin.fill").foregroundStyle(DieterTheme.shell)
            Text(card.title.isEmpty ? "Untitled chat" : card.title)
                .font(.system(size: 12, weight: .semibold)).lineLimit(1)
        }
        .padding(.horizontal, 12).frame(width: 220, height: 40, alignment: .leading)
        .background(DieterTheme.elevated, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(DieterTheme.shell.opacity(0.4)))
        .shadow(color: Color.black.opacity(0.4), radius: 14, y: 7)
    }
}

struct PinnedChatDragPayload: Equatable {
    private static let prefix = "dieter:pinned-chat:"
    let chatID: String

    init(chatID: String) {
        self.chatID = chatID
    }

    init?(_ encoded: String) {
        guard encoded.hasPrefix(Self.prefix) else { return nil }
        let chatID = String(encoded.dropFirst(Self.prefix.count))
        guard !chatID.isEmpty else { return nil }
        self.chatID = chatID
    }

    var encoded: String { Self.prefix + chatID }
}

enum ChatActivityText {
    static func compact(_ value: String, relativeTo now: Date = Date()) -> String {
        guard let date = DieterTimestamp.date(from: value) else { return "" }
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case ..<60: return "now"
        case ..<3_600: return "\(seconds / 60)m"
        case ..<86_400: return "\(seconds / 3_600)h"
        case ..<604_800: return "\(seconds / 86_400)d"
        default: return "\(seconds / 604_800)w"
        }
    }
}

private struct StandaloneChatStartView: View {
    @Environment(DieterStore.self) private var store
    @State private var prompt = ""
    @State private var projectID = ""
    @State private var provider = ""
    @State private var model = ""
    @State private var effort = ""
    @State private var providerOptions: [String: String] = [:]
    @State private var submitting = false
    @State private var attachments: [Dieter_V1_MessagePart] = []
    @State private var fileImporterPresented = false
    @State private var attachmentDropTargeted = false
    @State private var workspaceDraft = ConversationWorkspaceDraft()

    private let suggestions = [
        ("Explore the codebase", "Explore this codebase and explain its architecture, important entry points, and current risks."),
        ("Build a feature", "Help me design and implement a new feature in this project."),
        ("Review recent changes", "Review the recent changes in this repository and identify correctness or maintainability issues."),
        ("Fix a failure", "Investigate the current failures in this project, find the root cause, and implement a verified fix."),
    ]

    private var project: Dieter_V1_Project? { store.projects.first { $0.id == projectID } }
    private var harness: Dieter_V1_Harness? { store.harnessCatalog.harnesses.first { $0.id == provider } }
    private var selectedModel: Dieter_V1_HarnessModel? { harness?.models.first { $0.id == model } }
    var body: some View {
        VStack(spacing: 0) {
            FluidPaneChrome(background: DieterTheme.sidebar, spacing: 8) {
                HStack {
                    PaneTitleBlock(
                        title: "New chat",
                        subtitle: "\(project?.name ?? "Choose a project") · Standalone chat",
                        symbol: "bubble.left"
                    )
                    StatusPill(text: "New")
                }
            } secondary: {
                HStack(spacing: 7) {
                    Image(systemName: "info.circle").foregroundStyle(DieterTheme.shell)
                    Text("Standalone chats stay in their project folder and never become board cards.")
                    Spacer()
                }
                .font(.caption2).foregroundStyle(DieterTheme.tertiary)
            }

            Spacer(minLength: 24)
            VStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 15, style: .continuous).fill(DieterTheme.shellDeep.opacity(0.16)).frame(width: 60, height: 60)
                    Image(systemName: "bubble.left").font(.system(size: 23, weight: .medium)).foregroundStyle(DieterTheme.shell)
                }
                Text("What should we work on?").font(.system(size: 22, weight: .semibold))
                Text("Start a standalone local conversation in one of your project folders.\nIt never becomes a dieter card.")
                    .font(.system(size: 13)).foregroundStyle(DieterTheme.subtle).multilineTextAlignment(.center).lineSpacing(3)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(suggestions, id: \.0) { suggestion in
                        Button { prompt = suggestion.1 } label: {
                            HStack { Image(systemName: "sparkles").font(.system(size: 10)).foregroundStyle(DieterTheme.shell); Text(suggestion.0).font(.system(size: 12, weight: .medium)); Spacer() }
                                .padding(.horizontal, 13).frame(height: 46)
                                .background(DieterTheme.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(DieterTheme.border))
                        }.buttonStyle(.plain)
                    }
                }.frame(maxWidth: 590)
            }
            Spacer(minLength: 24)

            VStack(spacing: 9) {
                HStack(spacing: 8) {
                    Menu {
                        ForEach(store.projects.filter { !$0.archived }, id: \.id) { item in Button(item.name) { projectID = item.id } }
                    } label: { DieterChipLabel(title: project?.name ?? "Project", symbol: "folder") }.menuStyle(.borderlessButton).fixedSize()

                    Menu {
                        ForEach(store.harnessCatalog.harnesses, id: \.id) { item in
                            Button(item.name) {
                                provider = item.id; model = item.defaultModel
                                effort = item.models.first(where: { $0.id == model })?.defaultEffort ?? item.effort.options.first?.id ?? ""
                                providerOptions = ProviderOptionValues.defaults(for: item)
                            }
                        }
                    } label: { DieterChipLabel(title: harness?.name ?? "Agent", symbol: "cpu") }.menuStyle(.borderlessButton).fixedSize()

                    Menu {
                        ForEach(ConversationWorkspaceMode.allCases) { mode in
                            Button(mode.title) { workspaceDraft.mode = mode }
                        }
                    } label: {
                        DieterChipLabel(title: workspaceDraft.mode.shortTitle, symbol: "square.stack.3d.up")
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help(workspaceDraft.mode.detail)

                    Menu {
                        ForEach(harness?.models ?? [], id: \.id) { item in Button(item.name) { model = item.id; effort = item.defaultEffort } }
                    } label: { DieterChipLabel(title: selectedModel?.name ?? "Model", symbol: "terminal", maximumTitleWidth: 190) }.menuStyle(.borderlessButton).fixedSize()

                    if let options = selectedModel?.efforts, !options.isEmpty {
                        Menu { ForEach(options, id: \.self) { value in Button(value.capitalized) { effort = value } } } label: { DieterChipLabel(title: effort.isEmpty ? "Default" : effort.capitalized, symbol: "sparkles") }.menuStyle(.borderlessButton).fixedSize()
                    }
                    ProviderOptionChips(options: harness?.options ?? [], values: $providerOptions)
                    Spacer()
                }
                if !attachments.isEmpty {
                    AttachmentPreviewStrip(attachments: $attachments)
                        .padding(.horizontal, 4)
                }
                HStack(alignment: .bottom, spacing: 10) {
                    Button { fileImporterPresented = true } label: {
                        Image(systemName: "paperclip").frame(width: 34, height: 34)
                    }
                    .buttonStyle(DieterIconButtonStyle())
                    .help("Attach images or files")
                    TextField("Ask anything, describe a task, or explore an idea…", text: $prompt, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .lineLimit(1...4)
                        .padding(.horizontal, 13).padding(.vertical, 11)
                        .accessibilityIdentifier("chats.new.prompt")
                        .onKeyPress(.return, phases: .down) { press in
                            if !ComposerReturnPolicy.sendsMessage(shiftPressed: press.modifiers.contains(.shift)) {
                                return .ignored
                            }
                            if !submitting, !projectID.isEmpty,
                               !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty {
                                Task { await submit() }
                            }
                            return .handled
                        }
                        .frame(minHeight: 42, alignment: .topLeading)
                        .background(attachmentDropTargeted ? DieterTheme.shellDeep.opacity(0.12) : DieterTheme.input, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(attachmentDropTargeted ? DieterTheme.shell : DieterTheme.shellDeep.opacity(0.45), lineWidth: attachmentDropTargeted ? 1.5 : 1))
                        .attachmentDropTarget(isTargeted: $attachmentDropTargeted) { providers in
                            Task {
                                do { attachments = try await store.attachmentParts(providers, appendingTo: attachments) }
                                catch { store.show(error) }
                            }
                        }
                    Button { Task { await submit() } } label: {
                        Image(systemName: submitting ? "hourglass" : "arrow.up").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 36, height: 36).background(DieterTheme.shellDeep, in: Circle())
                            .shadow(color: DieterTheme.shellDeep.opacity(0.28), radius: 8, y: 2)
                    }
                    .buttonStyle(.plain)
                    .disabled(submitting || projectID.isEmpty || (prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty))
                    .accessibilityIdentifier("chats.new.send")
                }
            }
            .padding(16).background(DieterTheme.sidebar)
        }
        .background(DieterTheme.background)
        .attachmentIntake(
            store: store,
            importerPresented: $fileImporterPresented,
            attachments: $attachments
        )
        .onAppear { chooseDefaults() }
        .onChange(of: store.newChatProjectID) { _, value in if !value.isEmpty { projectID = value } }
    }

    private func chooseDefaults() {
        if projectID.isEmpty {
            projectID = store.newChatProjectID.isEmpty ? (store.selectedProjectID.isEmpty ? (store.projects.first?.id ?? "") : store.selectedProjectID) : store.newChatProjectID
        }
        let preferences = ConversationCreationPreferences.load(from: DieterAppearance.applicationDefaults())
        guard provider.isEmpty,
              let selection = preferences.resolved(in: store.harnessCatalog.harnesses),
              let harness = store.harnessCatalog.harnesses.first(where: { $0.id == selection.provider }) else { return }
        provider = selection.provider
        model = selection.model
        effort = selection.effort
        workspaceDraft.mode = selection.workspaceMode
        providerOptions = ProviderOptionValues.defaults(for: harness)
    }

    private func submit() async {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!text.isEmpty || !attachments.isEmpty), !projectID.isEmpty else { return }
        submitting = true
        ConversationCreationPreferences(
            provider: provider,
            model: model,
            effort: effort,
            workspaceMode: workspaceDraft.mode
        ).save(to: DieterAppearance.applicationDefaults())
        let firstLine = text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init)
            ?? attachments.first?.filename ?? "New chat"
        let title = firstLine.count > 72 ? String(firstLine.prefix(69)) + "…" : firstLine
        await store.createConversation(title: title, prompt: text, attachments: attachments, chat: true, provider: provider, model: model, effort: effort, providerOptions: providerOptions, deferred: false, projectID: projectID, workspace: workspaceDraft)
        submitting = false
    }
}
