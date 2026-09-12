import AppKit
import DieterAPI
import SwiftUI
import UniformTypeIdentifiers

struct ChatsView: View {
    @Environment(DieterStore.self) private var store
    @State private var search = ""
    @State private var showArchived = false
    @State private var projectDisclosure = ChatProjectDisclosurePreferences.load(
        from: DieterAppearance.applicationDefaults()
    )
    @State private var pinnedPageIndex = 0
    @State private var pinnedChatNavigation = PinnedChatNavigationPreferences.load(
        from: DieterAppearance.applicationDefaults()
    )

    private var activePinnedChats: [Dieter_V1_Card] {
        store.chats
            .filter { $0.scope == "chat" && $0.boardID.isEmpty && !$0.archived && $0.pinned }
            .sorted {
                ($0.lastActivityAt.isEmpty ? $0.updatedAt : $0.lastActivityAt)
                    > ($1.lastActivityAt.isEmpty ? $1.updatedAt : $1.lastActivityAt)
            }
    }

    private var pinnedChatMembership: [String] {
        activePinnedChats.map(\.id).sorted()
    }

    private var orderedProjects: [Dieter_V1_Project] {
        let projects = store.projects.filter { !$0.archived }
        let byID = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
        return store.sidebarProjectNavigation.orderedIDs(from: projects.map(\.id)).compactMap { byID[$0] }
    }

    var body: some View {
        let projection = store.replica.chatProjection(
            showArchived: showArchived,
            search: search,
            pinnedOrder: pinnedChatNavigation.chatOrder
        )
        let pinnedPage = LaneCardPage.resolve(
            total: projection.pinned.count, requestedPage: pinnedPageIndex)
        let displayedPinned = Array(projection.pinned[pinnedPage.lowerBound..<pinnedPage.upperBound])
        let displayedProjects = orderedProjects.filter {
            search.isEmpty || !(projection.byProject[$0.id] ?? []).isEmpty
        }
        let displayedProjectIDs = displayedProjects.map(\.id)
        ChatPaneSplit(browserHidden: store.conversationContext.content.isPresented(for: store.selectedChatID)) {
            VStack(spacing: 0) {
                FluidPaneChrome(background: .clear, spacing: 9) {
                    HStack(spacing: 8) {
                        PaneTitleBlock(
                            title: showArchived ? "Archived chats" : "Chats",
                            subtitle:
                                "\(projection.visible.count) conversation\(projection.visible.count == 1 ? "" : "s")",
                            prominent: true
                        )
                        Button {
                            showArchived.toggle()
                            store.closeConversation()
                        } label: {
                            Image(systemName: showArchived ? "archivebox.fill" : "archivebox")
                        }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                        .controlSize(.small)
                        .tint(showArchived ? DieterTheme.shell : nil)
                        .help(
                            showArchived ? "Show active chats" : "Show archived chats")
                        Button {
                            store.beginStandaloneChat()
                        } label: {
                            Label("New chat", systemImage: "plus")
                        }
                        .buttonStyle(.glassProminent).disabled(showArchived).help(
                            "New standalone chat"
                        )
                        .accessibilityIdentifier("chats.new")
                        .smokeTarget("chats.new")
                    }
                } secondary: {
                    DieterSearchField(text: $search, placeholder: "Search chats")
                }

                if store.chatsLoading || store.chatsError != nil {
                    LoadFeedback(
                        title: "Refreshing chats…", error: store.chatsError,
                        retry: { Task { await store.refreshChats() } }, compact: true
                    )
                    .accessibilityIdentifier("chats.load-feedback")
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        let pinned = projection.pinned
                        if !pinned.isEmpty {
                            VStack(alignment: .leading, spacing: 5) {
                                Label("PINNED", systemImage: "pin.fill").font(DieterFont.sectionLabel)
                                    .foregroundStyle(
                                        DieterTheme.tertiary
                                    ).padding(.horizontal, 8)
                                ChatGroupCard(chats: displayedPinned, movePinnedChat: movePinnedChat).padding(
                                    .leading, 14)
                                if pinnedPage.pageCount > 1 {
                                    ChatPageControls(
                                        page: pinnedPage,
                                        previous: { pinnedPageIndex = max(0, pinnedPage.page - 1) },
                                        next: { pinnedPageIndex = min(pinnedPage.pageCount - 1, pinnedPage.page + 1) }
                                    )
                                    .padding(.leading, 14)
                                }
                            }
                        }

                        Text(showArchived ? "ARCHIVED PROJECTS" : "PROJECTS")
                            .font(DieterFont.sectionLabel).tracking(0.8).foregroundStyle(DieterTheme.tertiary)
                            .padding(
                                .horizontal, 8
                            ).padding(.top, 3)

                        ForEach(displayedProjects, id: \.id) { project in
                            let projectChats = projection.byProject[project.id] ?? []
                            ChatProjectGroup(
                                project: project,
                                projectIDs: displayedProjectIDs,
                                chats: projectChats,
                                showArchived: showArchived,
                                expanded: projectDisclosure.isExpanded(project.id),
                                collapsed: projectDisclosure.isCollapsed(project.id),
                                toggleExpanded: { toggleExpanded(project.id) },
                                toggleCollapsed: { toggleCollapsed(project.id) },
                                moveProject: moveProject
                            )
                        }

                        if projection.visible.isEmpty && !store.chatsLoading && store.chatsError == nil {
                            ContentUnavailableView(
                                search.isEmpty
                                    ? (showArchived ? "No archived chats" : "No chats yet") : "No matching chats",
                                systemImage: showArchived ? "archivebox" : "bubble.left.and.bubble.right",
                                description: Text(
                                    showArchived
                                        ? "Archived standalone conversations appear here."
                                        : "Start a standalone conversation in any project folder.")
                            )
                            .padding(.vertical, 32)
                        }
                    }.padding(.horizontal, 8).padding(.vertical, 11)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("chats.browser-pane")
            .smokeTarget("chats.browser-pane")
        } detail: {
            if store.selectedChatID != nil {
                ConversationView(surfaceStyle: .inherited).environment(store.conversationContext)
            } else if showArchived {
                VStack(spacing: 0) {
                    FluidPaneChrome(background: .clear) {
                        PaneTitleBlock(
                            title: "Archived conversations", subtitle: "Select a chat to inspect or restore",
                            symbol: "archivebox")
                    }
                    VStack(spacing: 10) {
                        Image(systemName: "archivebox").font(.system(size: 34)).foregroundStyle(.secondary)
                        Text("Archived chats").font(.title2.weight(.bold))
                        Text("Select a conversation to restore or review it.").foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                StandaloneChatStartView()
            }
        }
        .task { await store.refreshChats() }
        .task(id: pinnedChatMembership) { initializePinnedChatOrderIfNeeded() }
        .onChange(of: projection.pinned.count) { _, _ in pinnedPageIndex = pinnedPage.page }
    }

    private func toggleExpanded(_ projectID: String) {
        projectDisclosure.toggleExpanded(projectID)
        projectDisclosure.save(to: DieterAppearance.applicationDefaults())
    }

    private func toggleCollapsed(_ projectID: String) {
        projectDisclosure.toggleCollapsed(projectID)
        projectDisclosure.save(to: DieterAppearance.applicationDefaults())
    }

    private func initializePinnedChatOrderIfNeeded() {
        guard pinnedChatNavigation.initializeIfNeeded(with: activePinnedChats.map(\.id)) else { return }
        pinnedChatNavigation.save(to: DieterAppearance.applicationDefaults())
    }

    private func movePinnedChat(_ chatID: String, to targetChatID: String) {
        guard pinnedChatNavigation.move(chatID, to: targetChatID, among: activePinnedChats) else {
            return
        }
        pinnedChatNavigation.save(to: DieterAppearance.applicationDefaults())
    }

    private func moveProject(_ projectID: String, before targetProjectID: String?) {
        var navigation = store.sidebarProjectNavigation
        guard navigation.move(projectID, before: targetProjectID, availableIDs: orderedProjects.map(\.id)) else {
            return
        }
        store.sidebarProjectNavigation = navigation
    }
}

enum ChatPaneSizing {
    static let minimumWidth: CGFloat = 285
    static let defaultWidth = DieterMetrics.browserWidth
    static let maximumWidth = DieterMetrics.browserMaximumWidth
    static let dividerHitWidth: CGFloat = 7
    static let dividerLineWidth: CGFloat = 1
    static let minimumDetailWidth: CGFloat = 327

    static func resolvedWidth(_ requestedWidth: CGFloat, workspaceWidth: CGFloat) -> CGFloat {
        // The resize target overlays the pane boundary, so it must not reserve
        // a transparent strip between the browser and conversation canvases.
        let available = max(0, workspaceWidth - minimumDetailWidth)
        guard available >= minimumWidth else { return available }
        return min(max(requestedWidth, minimumWidth), min(maximumWidth, available))
    }
}

private struct ChatPaneResizeDivider: View {
    let width: CGFloat
    let onChanged: (CGFloat) -> Void
    let onEnded: () -> Void
    let onAdjust: (AccessibilityAdjustmentDirection) -> Void
    @State private var hovering = false

    var body: some View {
        ZStack {
            Rectangle().fill(Color.clear)
            Rectangle()
                .fill(
                    hovering
                        ? DieterTheme.shell.opacity(0.62)
                        : Color(nsColor: .separatorColor).opacity(0.55)
                )
                .frame(width: hovering ? 2 : ChatPaneSizing.dividerLineWidth)
        }
        .frame(width: ChatPaneSizing.dividerHitWidth)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { onChanged($0.translation.width) }
                .onEnded { _ in onEnded() }
        )
        .onHover { isHovering in
            if isHovering, !hovering { NSCursor.resizeLeftRight.push() }
            if !isHovering, hovering { NSCursor.pop() }
            hovering = isHovering
        }
        .onDisappear {
            if hovering { NSCursor.pop() }
        }
        .accessibilityLabel("Resize chat browser")
        .accessibilityValue("\(Int(width)) points")
        .accessibilityAdjustableAction { direction in onAdjust(direction) }
        .accessibilityIdentifier("chats.resize-divider")
        .smokeTarget("chats.resize-divider")
    }
}

/// Unlike AppKit's HSplitView bridge, this split never renegotiates the
/// browser width from the selected conversation's intrinsic content size.
/// That keeps navigation stationary while chat Markdown is prepared or wraps.
private struct ChatPaneSplit<Browser: View, Detail: View>: View {
    let browserHidden: Bool
    let browser: Browser
    let detail: Detail
    @AppStorage("dieter.chatBrowserPaneWidth") private var storedWidth = Double(ChatPaneSizing.defaultWidth)
    @State private var dragStartWidth: CGFloat?

    init(
        browserHidden: Bool = false,
        @ViewBuilder browser: () -> Browser,
        @ViewBuilder detail: () -> Detail
    ) {
        self.browserHidden = browserHidden
        self.browser = browser()
        self.detail = detail()
    }

    var body: some View {
        GeometryReader { geometry in
            let width =
                browserHidden
                ? 0 : ChatPaneSizing.resolvedWidth(CGFloat(storedWidth), workspaceWidth: geometry.size.width)
            HStack(spacing: 0) {
                browser
                    .frame(width: width, height: geometry.size.height)
                    .allowsHitTesting(!browserHidden)
                    .accessibilityHidden(browserHidden)
                    .clipped()
                    .background {
                        DieterPaneBackground(role: .navigation, extendsUnderTitlebar: true)
                    }

                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .background {
                        DieterPaneBackground(role: .content, extendsUnderTitlebar: true)
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("chats.detail-pane")
                    .smokeTarget("chats.detail-pane")
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .overlay(alignment: .topLeading) {
                if !browserHidden {
                    // The titlebar-spanning divider must not enlarge the panes.
                    // Keep the generous drag target without inserting layout space.
                    // The one-point separator is painted directly over the touching
                    // pane edges, eliminating the exposed window-background seam.
                    ChatPaneResizeDivider(
                        width: width,
                        onChanged: { translation in
                            let startWidth = dragStartWidth ?? width
                            if dragStartWidth == nil { dragStartWidth = startWidth }
                            storedWidth = Double(
                                ChatPaneSizing.resolvedWidth(
                                    startWidth + translation,
                                    workspaceWidth: geometry.size.width
                                ))
                        },
                        onEnded: { dragStartWidth = nil },
                        onAdjust: { direction in
                            switch direction {
                            case .increment:
                                storedWidth = Double(
                                    ChatPaneSizing.resolvedWidth(width + 20, workspaceWidth: geometry.size.width))
                            case .decrement:
                                storedWidth = Double(
                                    ChatPaneSizing.resolvedWidth(width - 20, workspaceWidth: geometry.size.width))
                            @unknown default:
                                break
                            }
                        }
                    )
                    .frame(
                        height: geometry.size.height
                            + geometry.safeAreaInsets.top
                            + geometry.safeAreaInsets.bottom
                    )
                    .ignoresSafeArea(.container, edges: .vertical)
                    .offset(x: width - ChatPaneSizing.dividerHitWidth / 2)
                    .zIndex(1)
                }
            }
        }
    }
}

private struct ChatProjectGroup: View {
    @Environment(DieterStore.self) private var store
    let project: Dieter_V1_Project
    let projectIDs: [String]
    let chats: [Dieter_V1_Card]
    let showArchived: Bool
    let expanded: Bool
    let collapsed: Bool
    let toggleExpanded: () -> Void
    let toggleCollapsed: () -> Void
    let moveProject: (String, String?) -> Void
    @State private var pageIndex = 0
    @State private var dropTargeted = false

    private var projectMachine: DieterEndpoint? {
        store.machine(forProjectID: project.id)
    }

    private var projectMachineOnline: Bool? {
        projectMachine.map(store.machineIsAvailable)
    }

    private var headerAccessibilityLabel: String {
        let action = collapsed ? "Expand \(project.name) chats" : "Collapse \(project.name) chats"
        guard let projectMachine else { return action }
        let presence = projectMachineOnline == true ? "online" : "offline"
        return "\(action). Hosted on \(projectMachine.name), \(presence)"
    }

    private var displayed: [Dieter_V1_Card] {
        guard expanded else { return Array(chats.prefix(5)) }
        let page = LaneCardPage.resolve(total: chats.count, requestedPage: pageIndex)
        return Array(chats[page.lowerBound..<page.upperBound])
    }

    private var page: LaneCardPage {
        LaneCardPage.resolve(total: chats.count, requestedPage: pageIndex)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Button(action: toggleCollapsed) {
                    HStack(spacing: 7) {
                        Image(systemName: collapsed ? "chevron.right" : "chevron.down").font(
                            .system(size: 8, weight: .bold)
                        ).foregroundStyle(DieterTheme.tertiary)
                        Image(systemName: "folder").font(.system(size: 10)).foregroundStyle(
                            DieterTheme.tertiary)
                        Text(project.name.uppercased()).font(DieterFont.sectionLabel).tracking(0.8).lineLimit(1)
                            .foregroundStyle(DieterTheme.subtle)
                        Text("· \(chats.count)").font(.system(size: 10)).foregroundStyle(DieterTheme.tertiary)
                        Spacer(minLength: 4)
                        if let projectMachine {
                            ProjectMachineBadge(machine: projectMachine, online: projectMachineOnline == true)
                                .accessibilityIdentifier("chats.project.\(project.id).machine")
                                .smokeTarget(
                                    "chats.project.\(project.id).machine.\(projectMachineOnline == true ? "online" : "offline")"
                                )
                        }
                    }
                }
                .buttonStyle(.plain)
                .help(collapsed ? "Expand \(project.name) chats" : "Collapse \(project.name) chats")
                .accessibilityLabel(headerAccessibilityLabel)
                .accessibilityIdentifier("chats.project.\(project.id).toggle")
                .smokeTarget("chats.project.\(project.id).toggle")
                if !showArchived {
                    Button {
                        store.beginStandaloneChat(projectID: project.id)
                    } label: {
                        Image(systemName: "plus").font(.system(size: 9, weight: .bold))
                    }
                    .buttonStyle(.plain).help("New chat in \(project.name)")
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(
                dropTargeted ? DieterTheme.shellDeep.opacity(0.16) : .clear,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .contentShape(Rectangle())
            .draggable(SidebarProjectDragPayload(projectID: project.id).encoded) {
                SidebarProjectDragPreview(project: project)
            }
            .dropDestination(for: String.self) { values, location in
                guard let value = values.first, let payload = SidebarProjectDragPayload(value),
                    payload.projectID != project.id
                else { return false }
                let targetIndex = projectIDs.firstIndex(of: project.id) ?? 0
                let beforeProjectID: String?
                if location.y < 12 {
                    beforeProjectID = project.id
                } else if projectIDs.indices.contains(targetIndex + 1) {
                    beforeProjectID = projectIDs[targetIndex + 1]
                } else {
                    beforeProjectID = nil
                }
                moveProject(payload.projectID, beforeProjectID)
                return true
            } isTargeted: {
                dropTargeted = $0
            }
            .animation(.easeOut(duration: 0.12), value: dropTargeted)

            if !collapsed {
                if chats.isEmpty {
                    Text(showArchived ? "No archived chats" : "No chats").font(.caption).foregroundStyle(
                        .tertiary
                    )
                    .padding(.leading, 36).padding(.vertical, 2)
                } else {
                    ChatGroupCard(chats: displayed) {
                        if chats.count > 5 {
                            ChatRowSeparator()
                            if expanded {
                                VStack(spacing: 4) {
                                    if page.pageCount > 1 {
                                        ChatPageControls(
                                            page: page,
                                            previous: { pageIndex = max(0, page.page - 1) },
                                            next: { pageIndex = min(page.pageCount - 1, page.page + 1) }
                                        )
                                    }
                                    Button {
                                        pageIndex = 0
                                        toggleExpanded()
                                    } label: {
                                        Label("Show fewer", systemImage: "chevron.up")
                                            .font(.system(size: 10.5, weight: .medium))
                                            .foregroundStyle(DieterTheme.subtle)
                                            .padding(.leading, 24).padding(.vertical, 5)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .buttonStyle(.plain)
                                }
                            } else {
                                Button(action: toggleExpanded) {
                                    HStack(spacing: 5) {
                                        Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
                                        Text("Show \(chats.count - 5) more")
                                    }
                                    .font(.system(size: 10.5, weight: .medium)).foregroundStyle(DieterTheme.subtle)
                                    .padding(.leading, 27).padding(.vertical, 6)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.leading, 14)
                }
            }
        }
        .onChange(of: chats.count) { _, _ in pageIndex = page.page }
    }
}

private struct ChatPageControls: View {
    let page: LaneCardPage
    let previous: () -> Void
    let next: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: previous) { Image(systemName: "chevron.left") }
                .disabled(!page.canGoBackward)
                .accessibilityLabel("Previous chats")
            Text(page.rangeLabel)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(DieterTheme.tertiary)
                .frame(maxWidth: .infinity)
            Button(action: next) { Image(systemName: "chevron.right") }
                .disabled(!page.canGoForward)
                .accessibilityLabel("Next chats")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8).padding(.vertical, 4)
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

    init(chats: [Dieter_V1_Card], movePinnedChat: @escaping (String, String) -> Void)
    where Footer == EmptyView {
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
        Rectangle().fill(DieterTheme.border).frame(height: 1).padding(.leading, 27).padding(
            .trailing, 4)
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
    private var running: Bool { ChatRuntimePresentation.isActive(card.runtime) }

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
                    if running {
                        ChatRunningIndicator(color: runtimeColor(card.runtime))
                            .accessibilityLabel("Running")
                    } else {
                        ZStack {
                            Circle().stroke(runtimeColor(card.runtime).opacity(0.35), lineWidth: 1.5).frame(
                                width: 11, height: 11)
                            Circle().fill(runtimeColor(card.runtime)).frame(width: 5, height: 5)
                        }
                    }
                }
                .frame(width: 15, height: 15)
                .padding(.top, 3)
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(card.title.isEmpty ? "Untitled chat" : card.title)
                            .font(.system(size: 12.5, weight: unread ? .semibold : .medium))
                            .lineLimit(1)
                        if card.pinned {
                            Image(systemName: "pin.fill").font(.system(size: 8)).foregroundStyle(
                                DieterTheme.shell)
                        }
                        if card.archived {
                            Image(systemName: "archivebox.fill").font(.system(size: 8)).foregroundStyle(
                                DieterTheme.tertiary)
                        }
                        Spacer()
                        HStack(spacing: 5) {
                            if unread {
                                Circle().fill(DieterTheme.primary).frame(width: 6.5, height: 6.5)
                                    .accessibilityLabel("Unread")
                            }
                            Text(
                                ChatActivityText.compact(
                                    card.lastActivityAt.isEmpty ? card.updatedAt : card.lastActivityAt,
                                    relativeTo: .now
                                )
                            )
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
                        if running {
                            Text("Running")
                                .fontWeight(.semibold)
                                .foregroundStyle(DieterTheme.primary)
                        } else if !card.summary.isEmpty {
                            Text(card.summary).lineLimit(1)
                        }
                        if !card.workspaceMode.isEmpty { WorkspaceSummaryBadge(card: card, compact: true) }
                        if !card.activeSubagents.isEmpty {
                            Text(
                                "· \(card.activeSubagents.count) subagent\(card.activeSubagents.count == 1 ? "" : "s")"
                            ).foregroundStyle(DieterTheme.subtle)
                        }
                    }
                    .font(.system(size: 10)).foregroundStyle(DieterTheme.tertiary)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
            .background(
                store.selectedChatID == card.id
                    ? DieterTheme.selection : (hovering ? DieterTheme.raised.opacity(0.75) : .clear),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .opacity(store.isPendingCard(card.id) ? 0.52 : 1)
            .overlay(alignment: .bottomTrailing) {
                if store.isPendingCard(card.id) {
                    Image(
                        systemName: store.isFailedOutboxItem(card.id) ? "exclamationmark.circle.fill" : "clock"
                    )
                    .font(.caption2)
                    .foregroundStyle(
                        store.isFailedOutboxItem(card.id) ? DieterTheme.coral : DieterTheme.tertiary
                    )
                    .padding(5)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            if store.isFailedOutboxItem(card.id) {
                Button("Retry queued creation") { Task { await store.retryOutboxItem(card.id) } }
                Button("Discard queued creation", role: .destructive) {
                    Task { await store.discardOutboxItem(card.id) }
                }
                Divider()
            }
            if card.archived {
                Button("Restore") { Task { await store.archive(card, archived: false) } }
            } else {
                Button(card.pinned ? "Unpin" : "Pin") {
                    Task { await store.pin(card, pinned: !card.pinned) }
                }
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
        .smokeTarget("chat.\(card.id)")
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

enum ChatRuntimePresentation {
    private static let activeRuntimes = Set(["running", "starting", "working", "streaming"])

    static func isActive(_ runtime: String) -> Bool {
        activeRuntimes.contains(runtime.lowercased())
    }
}

/// The All Chats list can show several active conversations at once. Keep its
/// motion on Core Animation's compositor instead of installing one SwiftUI
/// animation driver per row.
struct ChatRunningIndicator: NSViewRepresentable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let color: Color

    func makeNSView(context: Context) -> ChatRunningIndicatorView {
        ChatRunningIndicatorView(frame: .zero)
    }

    func updateNSView(_ view: ChatRunningIndicatorView, context: Context) {
        view.configure(color: NSColor(color), animates: !reduceMotion)
    }

    static func dismantleNSView(_ view: ChatRunningIndicatorView, coordinator: Void) {
        view.stopAnimating()
    }
}

final class ChatRunningIndicatorView: NSView {
    private enum AnimationKey {
        static let pulse = "dieter.chat-running.pulse"
        static let orbit = "dieter.chat-running.orbit"
    }

    private let pulseLayer = CAShapeLayer()
    private let orbitLayer = CAShapeLayer()
    private let coreLayer = CAShapeLayer()
    private var animates = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        [pulseLayer, orbitLayer, coreLayer].forEach { layer?.addSublayer($0) }
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 15, height: 15) }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let layerBounds = CGRect(origin: .zero, size: bounds.size)
        let center = CGPoint(x: layerBounds.midX, y: layerBounds.midY)
        let coreRect = CGRect(x: center.x - 2.5, y: center.y - 2.5, width: 5, height: 5)
        pulseLayer.frame = layerBounds
        pulseLayer.path = CGPath(ellipseIn: coreRect, transform: nil)
        orbitLayer.frame = layerBounds
        orbitLayer.path = CGPath(ellipseIn: layerBounds.insetBy(dx: 1.5, dy: 1.5), transform: nil)
        coreLayer.frame = layerBounds
        coreLayer.path = CGPath(ellipseIn: coreRect, transform: nil)
        CATransaction.commit()
    }

    func configure(color: NSColor, animates: Bool) {
        let resolved = color.usingColorSpace(.deviceRGB) ?? color
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pulseLayer.fillColor = resolved.withAlphaComponent(animates ? 0.45 : 0.18).cgColor
        orbitLayer.fillColor = nil
        orbitLayer.strokeColor = resolved.withAlphaComponent(animates ? 0.82 : 0.38).cgColor
        orbitLayer.lineWidth = 1.25
        orbitLayer.lineCap = .round
        orbitLayer.strokeStart = animates ? 0.08 : 0
        orbitLayer.strokeEnd = animates ? 0.67 : 1
        coreLayer.fillColor = resolved.cgColor
        coreLayer.shadowColor = resolved.cgColor
        coreLayer.shadowOpacity = animates ? 0.55 : 0
        coreLayer.shadowRadius = animates ? 3 : 0
        coreLayer.shadowOffset = .zero
        CATransaction.commit()

        guard self.animates != animates else { return }
        if animates {
            self.animates = true
            startAnimating()
        } else {
            stopAnimating()
        }
    }

    func stopAnimating() {
        animates = false
        pulseLayer.removeAnimation(forKey: AnimationKey.pulse)
        orbitLayer.removeAnimation(forKey: AnimationKey.orbit)
    }

    private func startAnimating() {
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.8
        scale.toValue = 2.7
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.72
        fade.toValue = 0
        let pulse = CAAnimationGroup()
        pulse.animations = [scale, fade]
        pulse.duration = 1.35
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeOut)
        pulseLayer.add(pulse, forKey: AnimationKey.pulse)

        let orbit = CABasicAnimation(keyPath: "transform.rotation.z")
        orbit.fromValue = 0
        orbit.toValue = CGFloat.pi * 2
        orbit.duration = 1.8
        orbit.repeatCount = .infinity
        orbit.timingFunction = CAMediaTimingFunction(name: .linear)
        orbitLayer.add(orbit, forKey: AnimationKey.orbit)
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
                    payload.chatID != card.id
                else { return false }
                moveDraggedChat(payload.chatID)
                return true
            } isTargeted: {
                dropTargeted = $0
            }
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
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(DieterTheme.shell.opacity(0.4))
        )
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
    @FocusState private var promptFocused: Bool
    @State private var workspaceDraft = ConversationWorkspaceDraft()
    @State private var destinationHarnesses: [Dieter_V1_Harness] = []
    @State private var harnessCatalogLoading = false
    @State private var harnessCatalogError: String?
    @State private var harnessCatalogRetry = 0
    @State private var harnessCatalogRequestID = UUID()

    private struct HarnessLoadID: Hashable {
        let projectID: String
        let endpointID: String
        let connected: Bool
        let retry: Int
    }

    private let suggestions = [
        (
            "Explore the codebase",
            "Explore this codebase and explain its architecture, important entry points, and current risks."
        ),
        ("Build a feature", "Help me design and implement a new feature in this project."),
        (
            "Review recent changes",
            "Review the recent changes in this repository and identify correctness or maintainability issues."
        ),
        (
            "Fix a failure",
            "Investigate the current failures in this project, find the root cause, and implement a verified fix."
        ),
    ]

    private var availableProjects: [Dieter_V1_Project] { store.projects.filter { !$0.archived } }
    private var destinationGroups: [ProjectDestinationGroup] {
        store.projectDestinationGroups(projects: availableProjects)
    }
    private var destination: ProjectDestination? {
        ProjectDestinationCatalog.destination(projectID: projectID, in: destinationGroups)
    }
    private var project: Dieter_V1_Project? { destination?.project }
    private var harness: Dieter_V1_Harness? { destinationHarnesses.first { $0.id == provider } }
    private var selectedModel: Dieter_V1_HarnessModel? { harness?.models.first { $0.id == model } }
    var body: some View {
        VStack(spacing: 0) {
            FluidPaneChrome(background: .clear, spacing: 8) {
                HStack {
                    PaneTitleBlock(
                        title: "New chat",
                        subtitle: destination.map {
                            "\($0.project.name) on \($0.machineName) · Standalone chat"
                        }
                            ?? "Choose a project and machine · Standalone chat",
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
                    RoundedRectangle(cornerRadius: 15, style: .continuous).fill(
                        DieterTheme.shellDeep.opacity(0.16)
                    )
                    .frame(width: 60, height: 60)
                    Image(systemName: "bubble.left").font(.system(size: 23, weight: .medium)).foregroundStyle(
                        DieterTheme.shell)
                }
                Text("What should we work on?").font(.system(size: 22, weight: .semibold))
                Text(
                    "Start a standalone local conversation in one of your project folders.\nIt never becomes a dieter card."
                )
                .font(.system(size: 13)).foregroundStyle(DieterTheme.subtle).multilineTextAlignment(.center)
                .lineSpacing(3)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(suggestions, id: \.0) { suggestion in
                        Button {
                            prompt = suggestion.1
                        } label: {
                            HStack {
                                Image(systemName: "sparkles").font(.system(size: 10)).foregroundStyle(
                                    DieterTheme.shell)
                                Text(suggestion.0).font(.system(size: 12, weight: .medium))
                                Spacer()
                            }
                            .padding(.horizontal, 13).frame(height: 46)
                            .background(
                                DieterTheme.surface.opacity(0.7),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(DieterTheme.border))
                        }.buttonStyle(.plain)
                    }
                }.frame(maxWidth: 590)
            }
            Spacer(minLength: 24)

            newChatComposer
                .padding(.horizontal, 14).padding(.vertical, 12)
        }
        .attachmentIntake(
            store: store,
            importerPresented: $fileImporterPresented,
            attachments: $attachments
        )
        .onAppear { chooseProject() }
        .onChange(of: store.newChatProjectID) { _, value in if !value.isEmpty { projectID = value } }
        .task(
            id: HarnessLoadID(
                projectID: projectID, endpointID: store.endpoint.id,
                connected: store.phase.isConnected, retry: harnessCatalogRetry)
        ) { await loadDestinationHarnesses(for: projectID) }
    }

    private var canSubmit: Bool {
        !submitting && !harnessCatalogLoading && harnessCatalogError == nil && harness != nil
            && !projectID.isEmpty
            && (!prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }

    private var newChatComposer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if harnessCatalogLoading {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("Loading models from this project's machine…")
                }
                .font(.caption2).foregroundStyle(DieterTheme.tertiary)
                .accessibilityIdentifier("chats.new.harness-loading")
            } else if let harnessCatalogError {
                HStack {
                    Label(harnessCatalogError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(DieterTheme.coral)
                        .accessibilityIdentifier("chats.new.harness-error")
                    Button("Retry") { harnessCatalogRetry += 1 }
                        .accessibilityIdentifier("chats.new.harness-retry")
                }.font(.caption2)
            }

            ComposerSurface(focused: promptFocused, dropTargeted: attachmentDropTargeted) {
                destinationControls
                ComposerTextInput(
                    placeholder: "Ask anything, describe a task, or explore an idea…",
                    text: $prompt, focus: $promptFocused
                )
                .accessibilityIdentifier("chats.new.prompt")
                .smokeTarget("chats.new.prompt")
                .onKeyPress(.return, phases: .down) { press in
                    if !ComposerReturnPolicy.sendsMessage(shiftPressed: press.modifiers.contains(.shift)) {
                        return .ignored
                    }
                    if canSubmit { Task { await submit() } }
                    return .handled
                }

                if !attachments.isEmpty {
                    AttachmentPreviewStrip(attachments: $attachments)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 6)
                }

                ComposerToolbar { metrics in
                    ComposerAttachmentButton(
                        identifierPrefix: "chats.new", identity: projectID,
                        onUpload: { fileImporterPresented = true }
                    )
                    newChatProviderMenu(compact: metrics.compact)
                    newChatModelMenu(compact: metrics.compact)
                        .layoutPriority(1)
                    if let efforts = selectedModel?.efforts, !efforts.isEmpty {
                        newChatReasoningMenu(efforts: efforts, compact: metrics.compact)
                    }
                    ComposerProviderOptions(
                        options: ProviderOptionValues.options(for: harness, model: model),
                        values: $providerOptions, identity: projectID, identifierPrefix: "chats.new"
                    )
                    .smokeTarget("chats.new.provider-options")
                    .fixedSize()
                    Spacer(minLength: 0)
                    ComposerSendButton(isEnabled: canSubmit, submitting: submitting) {
                        Task { await submit() }
                    }
                    .accessibilityIdentifier("chats.new.send")
                    .smokeTarget("chats.new.send")
                }
            }
            .smokeTarget("chats.new.composer-shell")
            .attachmentDropTarget(isTargeted: $attachmentDropTargeted) { providers in
                Task {
                    do {
                        attachments = try await store.attachmentParts(providers, appendingTo: attachments)
                    } catch { store.show(error) }
                }
            }
        }
    }

    private var destinationControls: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 12) {
                ComposerSelectionMenu(
                    title: destination?.title ?? "Project and machine", symbol: "folder", help: "Project",
                    maximumWidth: 240
                ) {
                    ProjectDestinationMenuContent(
                        groups: destinationGroups, selectedProjectID: projectID, allowsOffline: true
                    ) { projectID = $0.project.id }
                }
                .accessibilityIdentifier("chats.new.project")
                .accessibilityValue(destination?.title ?? "No project selected")
                .smokeTarget("chats.new.project")

                ComposerSelectionMenu(
                    title: workspaceDraft.mode.shortTitle, symbol: "square.stack.3d.up", help: "Workspace",
                    maximumWidth: 92
                ) {
                    ForEach(ConversationWorkspaceMode.allCases) { mode in
                        Button(mode.title) { workspaceDraft.mode = mode }
                    }
                }
                .accessibilityIdentifier("chats.new.workspace")
                .smokeTarget("chats.new.workspace")
                Spacer(minLength: 0)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(DieterTheme.subtle)
            .controlSize(.small)

            if let destination {
                HStack(spacing: 6) {
                    Image(
                        systemName: destination.machineOnline
                            ? "desktopcomputer" : "desktopcomputer.trianglebadge.exclamationmark"
                    )
                    .foregroundStyle(destination.machineOnline ? DieterTheme.eyes : DieterTheme.coral)
                    Text("Runs on \(destination.machineName)")
                        .font(.caption2.weight(.medium)).foregroundStyle(DieterTheme.subtle)
                    Text("· \(destination.detail)")
                        .font(.caption2).foregroundStyle(DieterTheme.tertiary)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .lineLimit(1)
                .accessibilityIdentifier("chats.new.destination")
                .smokeTarget("chats.new.destination")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private func newChatProviderMenu(compact: Bool) -> some View {
        ComposerSelectionMenu(
            title: harness?.name ?? "Agent", symbol: "cpu", help: "Provider", compact: compact, maximumWidth: 100
        ) {
            ForEach(destinationHarnesses, id: \.id) { item in
                Button(item.name) {
                    guard let selection = HarnessSelection(provider: item.id).resolved(in: [item]) else { return }
                    provider = selection.provider
                    model = selection.model
                    effort = selection.effort
                    providerOptions = selection.providerOptions
                }
            }
        }
        .disabled(destinationHarnesses.isEmpty)
        .accessibilityIdentifier("chats.new.provider")
        .smokeTarget("chats.new.provider")
    }

    private func newChatModelMenu(compact: Bool) -> some View {
        let name = selectedModel?.name ?? "Model"
        return ComposerSelectionMenu(
            title: compact ? name.replacingOccurrences(of: "GPT-", with: "") : name,
            symbol: "sparkles", help: "Model"
        ) {
            ForEach(harness?.models ?? [], id: \.id) { item in
                Button(item.name) {
                    model = item.id
                    effort = item.defaultEffort
                    providerOptions = ProviderOptionValues.normalized(
                        for: harness, model: model, saved: providerOptions)
                }
            }
        }
        .accessibilityLabel("Model: \(name)")
        .accessibilityIdentifier("chats.new.model")
        .smokeTarget("chats.new.model")
    }

    private func newChatReasoningMenu(efforts: [String], compact: Bool) -> some View {
        ComposerSelectionMenu(
            title: effort.isEmpty ? "Default" : effort.capitalized,
            symbol: "sparkles", help: "Reasoning", compact: compact, maximumWidth: 80
        ) {
            ForEach(efforts, id: \.self) { value in
                Button(value.capitalized) { effort = value }
            }
        }
        .accessibilityIdentifier("chats.new.reasoning")
        .smokeTarget("chats.new.reasoning")
    }

    private func chooseProject() {
        if projectID.isEmpty {
            projectID =
                store.newChatProjectID.isEmpty
                ? (store.selectedProjectID.isEmpty
                    ? (availableProjects.first?.id ?? "") : store.selectedProjectID)
                : store.newChatProjectID
        }
    }

    private func loadDestinationHarnesses(for requestedProjectID: String) async {
        guard !Task.isCancelled else { return }
        let requestID = UUID()
        harnessCatalogRequestID = requestID
        guard !requestedProjectID.isEmpty else {
            destinationHarnesses = []
            return
        }
        harnessCatalogLoading = true
        harnessCatalogError = nil
        defer { if harnessCatalogRequestID == requestID { harnessCatalogLoading = false } }
        let catalog: Dieter_V1_HarnessCatalog
        do {
            catalog = try await store.loadHarnessCatalog(forProjectID: requestedProjectID)
        } catch {
            guard !Task.isCancelled, harnessCatalogRequestID == requestID,
                projectID == requestedProjectID
            else { return }
            destinationHarnesses = []
            harnessCatalogError =
                DieterRPCFailure.isCancellation(error)
                ? "The connection was interrupted while loading models. Try again."
                : DieterRPCFailure.message(for: error)
            return
        }
        guard !Task.isCancelled, harnessCatalogRequestID == requestID,
            projectID == requestedProjectID
        else { return }
        destinationHarnesses = catalog.harnesses
        let initializing = provider.isEmpty
        let preferences =
            initializing
            ? ConversationCreationPreferences.load(from: DieterAppearance.applicationDefaults())
            : ConversationCreationPreferences(
                provider: provider, model: model, effort: effort, workspaceMode: workspaceDraft.mode)
        guard let selection = preferences.resolved(in: destinationHarnesses),
            let harness = destinationHarnesses.first(where: { $0.id == selection.provider })
        else {
            harnessCatalogError = "This machine did not advertise any usable agent models."
            return
        }
        let previousProvider = provider
        provider = selection.provider
        model = selection.model
        effort = selection.effort
        if initializing { workspaceDraft.mode = selection.workspaceMode }
        providerOptions = ProviderOptionValues.resolved(
            for: harness,
            existing: previousProvider == selection.provider ? providerOptions : [:]
        )
    }

    private func submit() async {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty, !projectID.isEmpty,
            !harnessCatalogLoading, harnessCatalogError == nil, harness != nil
        else { return }
        submitting = true
        ConversationCreationPreferences(
            provider: provider,
            model: model,
            effort: effort,
            workspaceMode: workspaceDraft.mode
        ).save(to: DieterAppearance.applicationDefaults())
        let firstLine =
            text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init)
            ?? attachments.first?.filename ?? "New chat"
        let title = firstLine.count > 72 ? String(firstLine.prefix(69)) + "…" : firstLine
        await store.createConversation(
            title: title, prompt: text, attachments: attachments, chat: true, provider: provider,
            model: model,
            effort: effort, providerOptions: providerOptions, deferred: false, projectID: projectID,
            workspace: workspaceDraft)
        submitting = false
    }
}
