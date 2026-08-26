import DieterAPI
import SwiftUI
import UniformTypeIdentifiers

struct ChatsView: View {
    @Environment(DieterStore.self) private var store
    @State private var search = ""
    @State private var showArchived = false
    @State private var expandedProjects: Set<String> = []
    @State private var collapsedProjects: Set<String> = []

    private var visibleChats: [Dieter_V1_Card] {
        store.chats
            .filter { chat in
                chat.scope == "chat" && chat.boardID.isEmpty && chat.archived == showArchived &&
                    (search.isEmpty || chat.title.localizedCaseInsensitiveContains(search) || chat.summary.localizedCaseInsensitiveContains(search))
            }
            .sorted { ($0.lastActivityAt.isEmpty ? $0.updatedAt : $0.lastActivityAt) > ($1.lastActivityAt.isEmpty ? $1.updatedAt : $1.lastActivityAt) }
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
                        let pinned = showArchived ? [] : visibleChats.filter(\.pinned)
                        if !pinned.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Label("PINNED", systemImage: "pin.fill").font(DieterFont.sectionLabel).foregroundStyle(DieterTheme.tertiary).padding(.horizontal, 8)
                                ForEach(pinned, id: \.id) { ChatRow(card: $0) }
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
    }

    private func toggle(_ id: String, in values: inout Set<String>) {
        if values.contains(id) { values.remove(id) } else { values.insert(id) }
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
        VStack(alignment: .leading, spacing: 4) {
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
                ForEach(displayed, id: \.id) { ChatRow(card: $0) }
                if chats.count > 5 {
                    Button(action: toggleExpanded) {
                        HStack { Text(expanded ? "Show fewer" : "Show more"); if !expanded { Text("\(chats.count - 5)").foregroundStyle(DieterTheme.tertiary) } }
                            .font(.caption2.weight(.medium)).foregroundStyle(DieterTheme.subtle).padding(.horizontal, 31).padding(.vertical, 5)
                    }.buttonStyle(.plain)
                } else if chats.isEmpty {
                    Text(showArchived ? "No archived chats" : "No chats").font(.caption).foregroundStyle(.tertiary).padding(.leading, 31).padding(.vertical, 5)
                }
            }
        }
    }
}

struct ChatRow: View {
    @Environment(DieterStore.self) private var store
    let card: Dieter_V1_Card
    @State private var hovering = false
    @State private var renamePresented = false
    @State private var renameText = ""

    var body: some View {
        Button {
            Task {
                if card.archived { await store.archive(card, archived: false) }
                await store.openConversation(cardID: card.id, chat: true)
            }
        } label: {
            HStack(alignment: .top, spacing: 9) {
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
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(card.title.isEmpty ? "Untitled chat" : card.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                        if card.pinned { Image(systemName: "pin.fill").font(.system(size: 8)).foregroundStyle(DieterTheme.shell) }
                        if card.archived { Image(systemName: "archivebox.fill").font(.system(size: 8)).foregroundStyle(DieterTheme.tertiary) }
                        Spacer()
                        HStack(spacing: 5) {
                            if store.isChatUnread(card) {
                                Circle().fill(DieterTheme.primary).frame(width: 6, height: 6)
                                    .accessibilityLabel("Unread")
                            }
                            TimelineView(.periodic(from: .now, by: 30)) { context in
                                Text(ChatActivityText.compact(
                                    card.lastActivityAt.isEmpty ? card.updatedAt : card.lastActivityAt,
                                    relativeTo: context.date
                                ))
                            }
                            .fixedSize()
                        }
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(DieterTheme.tertiary)
                    }
                    HStack(spacing: 6) {
                        if ["running", "starting"].contains(card.runtime) { Text("Running").foregroundStyle(DieterTheme.primary) }
                        else if !card.summary.isEmpty { Text(card.summary).lineLimit(1) }
                        if !card.activeSubagents.isEmpty {
                            Text("· \(card.activeSubagents.count) subagent\(card.activeSubagents.count == 1 ? "" : "s")").foregroundStyle(DieterTheme.subtle)
                        }
                    }
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(DieterTheme.tertiary)
                }
            }
            .padding(.horizontal, 9).padding(.vertical, 8)
            .background(store.selectedChatID == card.id ? DieterTheme.selection : (hovering ? DieterTheme.surface.opacity(0.62) : .clear), in: RoundedRectangle(cornerRadius: DieterMetrics.controlRadius, style: .continuous))
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

enum ChatActivityText {
    static func compact(_ value: String, relativeTo now: Date = Date()) -> String {
        let precise = ISO8601DateFormatter(); precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = precise.date(from: value) ?? ISO8601DateFormatter().date(from: value) else { return "" }
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

    private let suggestions = [
        ("Explore the codebase", "Explore this codebase and explain its architecture, important entry points, and current risks."),
        ("Build a feature", "Help me design and implement a new feature in this project."),
        ("Review recent changes", "Review the recent changes in this repository and identify correctness or maintainability issues."),
        ("Fix a failure", "Investigate the current failures in this project, find the root cause, and implement a verified fix."),
    ]

    private var project: Dieter_V1_Project? { store.projects.first { $0.id == projectID } }
    private var harness: Dieter_V1_Harness? { store.harnessCatalog.harnesses.first { $0.id == provider } }
    private var selectedModel: Dieter_V1_HarnessModel? { harness?.models.first { $0.id == model } }
    private var promptEditorHeight: CGFloat {
        let lines = prompt.split(separator: "\n", omittingEmptySubsequences: false).count
        return min(108, 42 + CGFloat(max(0, lines - 1)) * 18)
    }

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
                        .frame(height: promptEditorHeight)
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
        .fileImporter(isPresented: $fileImporterPresented, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            do { attachments = try store.attachmentParts(try result.get(), appendingTo: attachments) }
            catch { store.show(error) }
        }
        .onPasteCommand(of: [.image, .fileURL]) { providers in
            Task {
                do { attachments = try await store.attachmentParts(providers, appendingTo: attachments) }
                catch { store.show(error) }
            }
        }
        .attachmentPasteCatcher { pasteboard in
            do {
                guard let parts = try store.pasteboardAttachmentParts(pasteboard, appendingTo: attachments) else { return false }
                attachments = parts
                return true
            } catch {
                store.show(error)
                return true
            }
        }
        .onAppear { chooseDefaults() }
        .onChange(of: store.newChatProjectID) { _, value in if !value.isEmpty { projectID = value } }
    }

    private func chooseDefaults() {
        if projectID.isEmpty {
            projectID = store.newChatProjectID.isEmpty ? (store.selectedProjectID.isEmpty ? (store.projects.first?.id ?? "") : store.selectedProjectID) : store.newChatProjectID
        }
        guard provider.isEmpty, let item = store.harnessCatalog.harnesses.first else { return }
        provider = item.id
        model = item.defaultModel
        effort = item.models.first(where: { $0.id == model })?.defaultEffort ?? item.effort.options.first?.id ?? ""
        providerOptions = ProviderOptionValues.defaults(for: item)
    }

    private func submit() async {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!text.isEmpty || !attachments.isEmpty), !projectID.isEmpty else { return }
        submitting = true
        let firstLine = text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init)
            ?? attachments.first?.filename ?? "New chat"
        let title = firstLine.count > 72 ? String(firstLine.prefix(69)) + "…" : firstLine
        await store.createConversation(title: title, prompt: text, attachments: attachments, chat: true, provider: provider, model: model, effort: effort, providerOptions: providerOptions, deferred: false, projectID: projectID)
        submitting = false
    }
}
