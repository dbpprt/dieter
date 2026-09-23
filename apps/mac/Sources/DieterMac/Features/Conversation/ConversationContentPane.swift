import AppKit
import SwiftUI

private struct ConversationWorkspaceTabsInTitlebarKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var conversationWorkspaceTabsInTitlebar: Bool {
        get { self[ConversationWorkspaceTabsInTitlebarKey.self] }
        set { self[ConversationWorkspaceTabsInTitlebarKey.self] = newValue }
    }
}

enum ConversationFixedSidebarTab: String, CaseIterable, Identifiable {
    case changes = "Changes"
    case subagents = "Subagents"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .changes: "arrow.triangle.branch"
        case .subagents: "person.2"
        }
    }

    static func visible(standalone: Bool) -> [Self] {
        [.changes, .subagents]
    }
}

struct ConversationContentPane: View {
    @Environment(ConversationContext.self) private var context
    @Environment(\.conversationWorkspaceTabsInTitlebar) private var workspaceTabsInTitlebar
    @Bindable var model: ConversationContentModel

    private var standalone: Bool {
        (context.selectedCard ?? context.selectedDetail?.card)?.scope == "chat"
    }
    private var fixedTabs: [ConversationFixedSidebarTab] {
        ConversationFixedSidebarTab.visible(standalone: standalone)
    }
    private var conversationID: String {
        context.selectedCardID ?? context.selectedChatID ?? model.conversationID
    }
    private var workspaceTabs: [ConversationContentTab] {
        model.workspaceTabs(for: conversationID)
    }
    private var selectedFixedTab: ConversationFixedSidebarTab? {
        if let selected = ConversationFixedSidebarTab(rawValue: model.conversationTab), fixedTabs.contains(selected) {
            return selected
        }
        return model.selectedTab?.conversationID == conversationID && model.selectedTab?.kind == .review
            ? .changes : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            if !workspaceTabsInTitlebar {
                ConversationWorkspaceTabBar(model: model, includesConversation: !model.splitMode)
                Divider()
            }
            if let error = model.error {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(error).textSelection(.enabled)
                    Spacer(minLength: 0)
                }
                .font(.caption).foregroundStyle(.secondary).padding(12)
                .accessibilityIdentifier("conversation.content.error")
            }
            if let selectedFixedTab {
                fixedContent(selectedFixedTab)
            } else if workspaceTabs.isEmpty {
                if model.loading { LoadFeedback(title: "Opening…") } else { launcher }
            } else {
                ZStack {
                    ForEach(workspaceTabs) { tab in
                        let active = model.selectedTabID == tab.id && model.isOpen
                        ConversationWorkspaceTabView(model: model, tab: tab, active: active)
                            .opacity(active ? 1 : 0)
                            .allowsHitTesting(active)
                            .accessibilityHidden(!active)
                            .zIndex(active ? 1 : 0)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DieterTheme.surface)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("conversation.content-pane")
        .smokeTarget("conversation.content-pane")
        .task(id: "\(model.conversationID):\(selectedFixedTab?.rawValue ?? "workspace")") {
            await synchronizeFixedSelection()
        }
    }

    @ViewBuilder private func fixedContent(_ tab: ConversationFixedSidebarTab) -> some View {
        switch tab {
        case .changes:
            if let review = model.tabs.first(where: {
                $0.conversationID == conversationID && $0.kind == .review
            }) {
                ConversationWorkspaceTabView(model: model, tab: review, active: model.isOpen)
            } else if model.loading {
                LoadFeedback(title: "Opening changes…")
            } else {
                ContentUnavailableView(
                    "Changes unavailable", systemImage: "arrow.triangle.branch",
                    description: Text("Reconnect this conversation’s machine and try again."))
            }
        case .subagents:
            SubagentsView(background: .clear)
        }
    }

    private func synchronizeFixedSelection() async {
        guard let selectedFixedTab else { return }
        if selectedFixedTab == .changes {
            if let review = model.tabs.first(where: {
                $0.conversationID == conversationID && $0.kind == .review
            }) {
                model.selectTab(review.id)
            } else if !conversationID.isEmpty {
                _ = await model.openPanel(.review, conversationID: conversationID)
            }
        } else {
            model.deselectTab()
        }
    }

    private var launcher: some View {
        VStack(spacing: 22) {
            Image(systemName: "rectangle.split.2x1")
                .font(.system(size: 30, weight: .light)).foregroundStyle(.tertiary)
            VStack(spacing: 6) {
                Text("Workspace").font(.title3.weight(.semibold))
                Text("Open a file, browse a page, or work alongside this conversation.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            VStack(spacing: 3) {
                ForEach(model.addablePanelKinds(for: conversationID)) { kind in
                    Button {
                        model.requestPanel(kind, conversationID: conversationID)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: kind.symbol).frame(width: 22).foregroundStyle(.secondary)
                            Text(kind.title)
                            Spacer()
                            Image(systemName: "plus").font(.caption).foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 12).frame(height: 38).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("conversation.content.launch.\(kind.rawValue)")
                    .smokeTarget("conversation.content.launch.\(kind.rawValue)")
                }
            }
            .frame(maxWidth: 280)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
        }
        .padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ConversationWorkspaceTabBar: View {
    @Environment(ConversationContext.self) private var context
    @Bindable var model: ConversationContentModel
    var titlebar = false
    var nativeToolbar = false
    var includesConversation = false
    var showsFixedTabs = true
    var showsWorkspaceTabs = true
    var showsControls = true

    private var conversationID: String {
        context.selectedCardID ?? context.selectedChatID ?? ""
    }

    private var workspacePresented: Bool {
        model.isPresented(for: conversationID)
    }

    private var barHeight: CGFloat {
        if nativeToolbar { return ConversationWorkspaceChromeMetrics.titlebarHeight }
        return titlebar
            ? ConversationWorkspaceChromeMetrics.titlebarHeight : ConversationWorkspaceChromeMetrics.tabHeight
    }

    private var barBackground: Color {
        if nativeToolbar { return .clear }
        return titlebar ? DieterTheme.surface : DieterTheme.sidebar.opacity(0.4)
    }

    private var fixedTabs: [ConversationFixedSidebarTab] {
        ConversationFixedSidebarTab.visible(
            standalone: (context.selectedCard ?? context.selectedDetail?.card)?.scope == "chat")
    }

    private var selectedFixedTab: ConversationFixedSidebarTab? {
        if let selected = ConversationFixedSidebarTab(rawValue: model.conversationTab),
            fixedTabs.contains(selected)
        {
            return selected
        }
        return model.selectedTab?.conversationID == conversationID && model.selectedTab?.kind == .review
            ? .changes : nil
    }

    private var visibleWorkspaceTabs: [ConversationContentTab] {
        model.workspaceTabs(for: conversationID)
    }

    var body: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        if includesConversation {
                            ConversationRailTabLabel(
                                title: "Conversation", systemName: "bubble.left",
                                selected: model.conversationTab == "Conversation"
                                    && (model.splitMode || model.selectedTabID == nil),
                                height: nativeToolbar ? 40 : 30,
                                select: {
                                    if !model.splitMode { model.showConversationTab() }
                                }
                            )
                            .id("conversation")
                        }
                        if showsFixedTabs {
                            ForEach(fixedTabs) { tab in
                                ConversationFixedSidebarTabLabel(
                                    tab: tab,
                                    count: count(for: tab),
                                    selected: selectedFixedTab == tab,
                                    height: nativeToolbar ? 40 : 30,
                                    select: { select(tab) }
                                )
                                .id(tab.id)
                            }
                        }
                        if showsWorkspaceTabs {
                            ForEach(visibleWorkspaceTabs) { tab in
                                ConversationWorkspaceTabLabel(
                                    tab: tab,
                                    selected: model.isOpen && model.selectedTabID == tab.id,
                                    height: nativeToolbar ? 40 : 30,
                                    select: {
                                        model.conversationTab = "Conversation"
                                        model.selectTab(tab.id)
                                    },
                                    close: { Task { await model.closeTab(tab.id) } }
                                )
                                .id(tab.id)
                            }
                        }
                    }
                    .padding(.horizontal, 6)
                }
                .frame(minWidth: 0, maxWidth: .infinity)
                .onChange(of: model.selectedTabID) { _, selectedID in
                    if let selectedID, model.selectedTab?.conversationID == conversationID,
                        model.selectedTab?.kind != .review
                    {
                        proxy.scrollTo(selectedID, anchor: .trailing)
                    }
                }
            }
            if showsControls {
                ConversationWorkspaceControls(model: model)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: barHeight, maxHeight: barHeight, alignment: .leading)
        .clipped()
        .background(barBackground)
        .overlay(alignment: .bottom) {
            if titlebar && !nativeToolbar { Divider() }
        }
    }

    private func count(for tab: ConversationFixedSidebarTab) -> Int {
        switch tab {
        case .changes:
            Int((context.selectedCard ?? context.selectedDetail?.card)?.workspace.changedFiles ?? 0)
        case .subagents:
            context.conversation?.conversation.subagents.count ?? 0
        }
    }

    private func select(_ tab: ConversationFixedSidebarTab) {
        model.conversationTab = tab.rawValue
        switch tab {
        case .changes:
            if workspacePresented {
                if let review = model.tabs.first(where: {
                    $0.conversationID == conversationID && $0.kind == .review
                }) {
                    model.selectTab(review.id)
                } else {
                    model.requestPanel(.review, conversationID: conversationID)
                }
            }
        case .subagents:
            break
        }
    }
}

enum ConversationToolbarRailMode: Equatable {
    case unified
    case sidebar

    init(workspacePresented: Bool) {
        self = workspacePresented ? .sidebar : .unified
    }

    var railCount: Int { self == .sidebar ? 2 : 1 }
}

struct ConversationToolbarSurfaceRail: View {
    @Environment(ConversationContext.self) private var context
    @Bindable var model: ConversationContentModel
    let kanbanPresented: Bool
    let toggleKanban: () -> Void

    private var conversationID: String {
        context.selectedCardID ?? context.selectedChatID ?? ""
    }

    private var workspacePresented: Bool {
        model.isPresented(for: conversationID)
    }

    var body: some View {
        ConversationToolbarRail(identifier: "conversation.toolbar.rail.surfaces") {
            ConversationSurfaceToggles(
                model: model,
                workspacePresented: workspacePresented,
                kanbanPresented: kanbanPresented,
                toggleKanban: toggleKanban,
                showsConversation: true
            )
        }
    }
}

struct ConversationToolbarWorkspaceRail: View {
    @Bindable var model: ConversationContentModel

    var body: some View {
        ConversationToolbarRail(identifier: "conversation.toolbar.rail.sidebar") {
            ConversationWorkspaceTabBar(
                model: model,
                nativeToolbar: true,
                includesConversation: false,
                showsControls: false
            )
        }
    }
}

struct ConversationToolbarUnifiedRail: View {
    @Environment(ConversationContext.self) private var context
    @Bindable var model: ConversationContentModel
    let kanbanPresented: Bool
    let toggleKanban: () -> Void

    private var conversationID: String {
        context.selectedCardID ?? context.selectedChatID ?? ""
    }

    private var workspacePresented: Bool {
        model.isPresented(for: conversationID)
    }

    var body: some View {
        ConversationToolbarRail(identifier: "conversation.toolbar.rail.unified") {
            HStack(spacing: 3) {
                ConversationSurfaceToggles(
                    model: model,
                    workspacePresented: workspacePresented,
                    kanbanPresented: kanbanPresented,
                    toggleKanban: toggleKanban,
                    showsConversation: true
                )
                Divider()
                    .frame(height: 18)
                    .padding(.horizontal, 3)
                ConversationWorkspaceTabBar(
                    model: model,
                    nativeToolbar: true,
                    includesConversation: false,
                    showsControls: false
                )
            }
        }
    }
}

struct ConversationSurfaceToggles: View {
    @Bindable var model: ConversationContentModel
    let workspacePresented: Bool
    let kanbanPresented: Bool
    let toggleKanban: () -> Void
    let showsConversation: Bool
    var showsKanban = true
    var height: CGFloat = 26

    var body: some View {
        HStack(spacing: 2) {
            if showsKanban {
                ConversationSurfaceToggleLabel(
                    title: "Kanban",
                    systemName: "rectangle.3.group",
                    selected: kanbanPresented,
                    height: height,
                    select: toggleKanban
                )
                .help(kanbanPresented ? "Hide Kanban" : "Show Kanban")
            }
            if showsConversation {
                ConversationSurfaceToggleLabel(
                    title: "Conversation",
                    systemName: "bubble.left",
                    selected: workspacePresented || model.conversationTab == "Conversation",
                    height: height,
                    select: { model.showConversationTab() }
                )
                .help("Show Conversation")
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct ConversationToolbarRail<Content: View>: View {
    let identifier: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .id(identifier)
            .background(DieterTheme.raised.opacity(0.72), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(DieterTheme.border, lineWidth: 0.75)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(identifier)
    }
}

struct ConversationWorkspaceControls: View {
    @Environment(ConversationContext.self) private var context
    @Bindable var model: ConversationContentModel
    var height: CGFloat = 24

    private var conversationID: String {
        context.selectedCardID ?? context.selectedChatID ?? ""
    }

    private var workspacePresented: Bool {
        model.splitMode && model.isPresented(for: conversationID)
    }

    var body: some View {
        HStack(spacing: 2) {
            Menu {
                ForEach(model.addablePanelKinds(for: conversationID)) { kind in
                    Button(kind.title, systemImage: kind.symbol) {
                        model.requestPanel(kind, conversationID: conversationID)
                    }
                    .accessibilityIdentifier("conversation.content.add.\(kind.rawValue)")
                }
            } label: {
                ConversationWorkspaceSymbol(
                    systemName: "plus", frameSize: ConversationWorkspaceChromeMetrics.actionSize
                )
                .frame(width: 28, height: height)
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden)
            .help("Open a workspace tab")
            .accessibilityLabel("Open a workspace tab")
            .accessibilityIdentifier("conversation.content.add").smokeTarget("conversation.content.add")

            Button {
                if workspacePresented {
                    model.showSinglePane()
                } else {
                    model.showEmpty(conversationID: conversationID)
                }
            } label: {
                ConversationWorkspaceSymbol(
                    systemName: workspacePresented ? "rectangle.split.1x2" : "sidebar.right",
                    selected: workspacePresented, frameSize: ConversationWorkspaceChromeMetrics.actionSize
                )
                .frame(width: 28, height: height)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(workspacePresented ? "Single pane" : "Split conversation and workspace")
            .accessibilityLabel(workspacePresented ? "Single pane" : "Split conversation and workspace")
            .accessibilityIdentifier("conversation.content.close").smokeTarget("conversation.content.close")
        }
        .fixedSize()
    }
}

private struct ConversationSurfaceToggleLabel: View {
    let title: String
    let systemName: String
    let selected: Bool
    let height: CGFloat
    let select: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: 6) {
                ConversationWorkspaceSymbol(systemName: systemName, selected: selected)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 9)
            .frame(minHeight: height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? DieterTheme.text : DieterTheme.subtle)
        .background(hovering ? DieterTheme.raised.opacity(0.7) : .clear)
        .overlay(alignment: .bottom) {
            Capsule()
                .fill(selected ? DieterTheme.primary : .clear)
                .frame(height: 2)
                .padding(.horizontal, 8)
        }
        .onHover { hovering = $0 }
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier("conversation-tab-\(title.lowercased())")
        .smokeTarget("conversation-tab-\(title.lowercased())")
        .fixedSize(horizontal: true, vertical: false)
    }
}

struct ConversationRailTabLabel: View {
    let title: String
    let systemName: String
    let selected: Bool
    let height: CGFloat
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 6) {
                ConversationWorkspaceSymbol(systemName: systemName, selected: selected)
                Text(title).font(.system(size: 12)).lineLimit(1)
            }
            .padding(.horizontal, 8)
            .frame(minHeight: height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? DieterTheme.text : DieterTheme.subtle)
        .background(selected ? DieterTheme.elevated : .clear, in: RoundedRectangle(cornerRadius: 4))
        .overlay(alignment: .bottom) {
            if selected { Capsule().fill(.secondary.opacity(0.6)).frame(height: 2).padding(.horizontal, 8) }
        }
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier("conversation-tab-\(title.lowercased())")
        .smokeTarget("conversation-tab-\(title.lowercased())")
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct ConversationFixedSidebarTabLabel: View {
    let tab: ConversationFixedSidebarTab
    let count: Int
    let selected: Bool
    let height: CGFloat
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 6) {
                ConversationWorkspaceSymbol(systemName: tab.symbol, selected: selected)
                Text(tab.rawValue).font(.system(size: 12)).lineLimit(1)
                if count > 0 { ConversationTabCountBadge(count: count, selected: selected) }
            }
            .frame(minWidth: 36, maxWidth: 180, minHeight: height)
            .padding(.horizontal, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(selected ? DieterTheme.surface : .clear, in: RoundedRectangle(cornerRadius: 4))
        .overlay(alignment: .bottom) {
            if selected { Capsule().fill(.secondary.opacity(0.6)).frame(height: 2).padding(.horizontal, 8) }
        }
        .accessibilityLabel(tab.rawValue)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier("conversation.content.fixed.\(tab.rawValue.lowercased())")
        .smokeTarget("conversation.content.fixed.\(tab.rawValue.lowercased())")
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct ConversationWorkspaceTabLabel: View {
    @Bindable var tab: ConversationContentTab
    let selected: Bool
    let height: CGFloat
    let select: () -> Void
    let close: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: select) {
                HStack(spacing: 6) {
                    ConversationWorkspaceSymbol(systemName: tab.symbol, selected: selected)
                    Text(tab.title).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                    if tab.dirty { Circle().fill(.secondary).frame(width: 5, height: 5) }
                }
                .frame(minWidth: 36, maxWidth: 180, minHeight: height)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(tab.title)
            .accessibilityAddTraits(selected ? [.isSelected] : [])
            .accessibilityIdentifier("conversation.content.tab.\(tab.id.uuidString)")
            .smokeTarget("conversation.content.tab.\(tab.id.uuidString)")
            Button(action: close) { Image(systemName: "xmark").font(.system(size: 9, weight: .medium)) }
                .buttonStyle(.plain).frame(width: 18, height: height)
                .opacity(selected || hovering ? 1 : 0)
                .help("Close \(tab.title)").accessibilityLabel("Close \(tab.title)")
                .accessibilityIdentifier("conversation.content.tab.\(tab.id.uuidString).close")
                .smokeTarget("conversation.content.tab.\(tab.id.uuidString).close")
        }
        .padding(.leading, 9).padding(.trailing, 3)
        .background(selected ? DieterTheme.surface : .clear, in: RoundedRectangle(cornerRadius: 4))
        .overlay(alignment: .bottom) {
            if selected { Capsule().fill(.secondary.opacity(0.6)).frame(height: 2).padding(.horizontal, 8) }
        }
        .onHover { hovering = $0 }
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct ConversationWorkspaceTabView: View {
    @Environment(DieterStore.self) private var store
    @Bindable var model: ConversationContentModel
    @Bindable var tab: ConversationContentTab
    let active: Bool
    @State private var navigatorWidth = 200.0
    @State private var dragStart: CGFloat?

    var body: some View {
        Group {
            switch tab.kind {
            case .browser:
                ConversationBrowserView(browser: tab.browser, initialURL: tab.sourceURL, scopeID: tab.id)
            case .terminal:
                ConversationTerminalPane(tab: tab)
            case .processes:
                ConversationProcessesPane(model: tab.processes, active: active)
            case .review:
                Group {
                    if tab.usesProjectReview {
                        ProjectChangesView(
                            model: tab.projectReview, projectName: tab.scope?.projectName ?? "Project",
                            active: active, isLive: tab.transportsLive, bindingRevision: tab.transportRevision)
                    } else {
                        WorkspaceChangesView(model: tab.review, background: DieterTheme.surface, active: active)
                    }
                }
                .accessibilityIdentifier("conversation.content.review")
                .smokeTarget("conversation.content.review")
            case .files:
                filePane
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var filePane: some View {
        VStack(spacing: 0) {
            breadcrumb
            Divider()
            GeometryReader { geometry in
                let width = min(CGFloat(navigatorWidth), max(140, geometry.size.width * 0.38))
                HStack(spacing: 0) {
                    fileDocument.frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                    if tab.showFileNavigator {
                        Rectangle().fill(DieterTheme.border).frame(width: 1)
                            .frame(width: 7).contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { value in
                                        if dragStart == nil { dragStart = width }
                                        navigatorWidth = min(
                                            300, max(140, (dragStart ?? width) - value.translation.width))
                                    }.onEnded { _ in dragStart = nil }
                            )
                            .accessibilityLabel("File navigator width")
                            .accessibilityAdjustableAction { direction in
                                navigatorWidth = min(
                                    300, max(140, navigatorWidth + (direction == .increment ? 20 : -20)))
                            }
                        ConversationFileNavigator(tab: tab) { model.openFile($0, from: tab) }
                            .frame(width: width).clipped()
                    }
                }
            }
        }
        .task(id: "\(active):\(tab.transportRevision)") {
            // A newer link or connection replacement may cancel this tab's
            // first read. Selecting it again resumes that read without retrying
            // genuine errors or touching a loaded/edited document.
            guard active, tab.transportsLive, tab.files.isLive, tab.error == nil,
                tab.files.fileDocument == nil, !tab.files.fileLoading, tab.files.fileError == nil,
                case .file(let path, _) = tab.selection
            else { return }
            await tab.files.openFile(path: path)
        }
    }

    private var breadcrumb: some View {
        HStack(spacing: 7) {
            Image(systemName: "folder").foregroundStyle(.tertiary)
            Text(
                path.isEmpty
                    ? (tab.rootPath as NSString).lastPathComponent : path.replacingOccurrences(of: "/", with: "  ›  ")
            )
            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading).layoutPriority(-1)
            .help(path.isEmpty ? tab.rootPath : path)
            if tab.files.fileDocument != nil {
                FileDocumentActions(
                    files: tab.files, identifierPrefix: "conversation.content.file.\(tab.id.uuidString)",
                    active: active, compact: true, resolveExternalActions: currentExternalActions
                )
                .fixedSize()
            }
            if tab.dirty {
                Button("Save") { Task { await tab.files.saveCurrentDocument() } }
                    .keyboardShortcut("s", modifiers: .command)
                    .controlSize(.small).disabled(tab.files.saving || !active || !tab.files.isLive)
                    .accessibilityIdentifier("conversation.content.save").smokeTarget("conversation.content.save")
            }
            Button {
                tab.showFileNavigator.toggle()
            } label: {
                Image(systemName: "sidebar.right")
            }
            .buttonStyle(.borderless).help("Toggle file navigator")
            .accessibilityIdentifier("conversation.content.files.toggle")
            .smokeTarget("conversation.content.files.toggle")
        }
        .padding(.horizontal, 12).frame(height: 34)
    }

    private var path: String {
        if case .file(let path, _) = tab.selection { return path }
        return ""
    }

    private func currentExternalActions() -> FileExternalActions {
        let scope = tab.scope
        let rpc = store.rpc
        let verifiedLocal =
            active && tab.transportsLive && tab.files.isLive && store.phase.isConnected
            && scope?.target == tab.files.target && scope?.rootPath == tab.rootPath
            && rpc != nil && rpc === scope?.client
            && rpc?.endpoint.id == tab.files.target.endpointID && rpc?.isLoopbackDataPlane == true
        return FileExternalActions.resolve(
            verifiedLocal: verifiedLocal, rootPath: tab.rootPath,
            relativePath: tab.files.fileDocument?.path ?? "")
    }

    @ViewBuilder private var fileDocument: some View {
        if tab.files.fileLoading && tab.files.fileDocument == nil {
            LoadFeedback(title: "Opening…")
        } else {
            VStack(spacing: 0) {
                if let error = tab.error {
                    Text(error).font(.caption).foregroundStyle(.secondary).padding(12)
                }
                if let error = tab.files.fileError {
                    LoadFeedback(
                        title: "File", error: error,
                        retry: { model.openFile(path, from: tab) }, compact: tab.files.fileDocument != nil)
                }
                if tab.files.fileDocument != nil {
                    ConversationContentRenderer(
                        files: tab.files, line: line, navigationID: tab.navigationID, active: active
                    )
                    .environment(
                        \.conversationLinkHandler,
                        { url in
                            model.openLink(url, from: tab); return true
                        })
                } else if tab.files.fileError == nil {
                    ContentUnavailableView(
                        "Choose a file", systemImage: "doc.text",
                        description: Text("Select a file in the navigator to open it here."))
                }
            }
        }
    }
    private var line: Int? {
        if case .file(_, let line) = tab.selection { return line }
        return nil
    }
}

enum ConversationContentSizing {
    static let conversationFraction: CGFloat = 0.62

    static func minimumConversationWidth(availableWidth: CGFloat) -> CGFloat {
        min(360, availableWidth * 0.55)
    }

    static func minimumWorkspaceWidth(availableWidth: CGFloat) -> CGFloat {
        min(320, availableWidth * 0.4)
    }
}

/// Keeps the primary conversation mounted as its secondary workspace appears.
/// The native split divider supplies resizing, keyboard access and pointer feedback.
struct ConversationContentSplit<Chat: View, Content: View>: View {
    let presented: Bool
    var singleWorkspace = false
    @ViewBuilder let chat: () -> Chat
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { geometry in
            HSplitView {
                if presented || !singleWorkspace {
                    chat()
                        .frame(
                            minWidth: presented
                                ? ConversationContentSizing.minimumConversationWidth(
                                    availableWidth: geometry.size.width)
                                : 0,
                            idealWidth: presented
                                ? geometry.size.width * ConversationContentSizing.conversationFraction
                                : geometry.size.width,
                            maxWidth: .infinity, maxHeight: .infinity
                        )
                        .clipped()
                        .background(ConversationSplitPositioner(presented: presented))
                }
                if presented || singleWorkspace {
                    content()
                        .frame(
                            minWidth: ConversationContentSizing.minimumWorkspaceWidth(
                                availableWidth: geometry.size.width),
                            idealWidth: geometry.size.width
                                * (1 - ConversationContentSizing.conversationFraction),
                            maxWidth: .infinity, maxHeight: .infinity
                        )
                        .clipped()
                }
            }
        }
    }
}

/// HSplitView preserves the original column's width when inserting its second
/// child, regardless of idealWidth. Position the actual native divider once
/// after expansion settles; later content updates must respect the user's drag.
private struct ConversationSplitPositioner: NSViewRepresentable {
    let presented: Bool

    func makeNSView(context: Context) -> ConversationSplitPositioningView {
        ConversationSplitPositioningView()
    }

    func updateNSView(_ view: ConversationSplitPositioningView, context: Context) {
        view.configure(presented: presented)
    }

    static func dismantleNSView(_ view: ConversationSplitPositioningView, coordinator: ()) {
        view.configure(presented: false)
    }
}

private final class ConversationSplitPositioningView: NSView {
    private var presented = false
    private var generation = 0
    private var positionTask: Task<Void, Never>?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(presented: Bool) {
        guard self.presented != presented else { return }
        self.presented = presented
        generation &+= 1
        positionTask?.cancel()
        positionTask = nil
        guard presented else { return }
        let currentGeneration = generation
        positionTask = Task { @MainActor [weak self] in
            var previousWidth: CGFloat?
            var stableSamples = 0
            // Mounting the pane and maximizing its board parent can occur in
            // separate layout passes. Observe rather than force those passes.
            for _ in 0..<50 {
                try? await Task.sleep(for: .milliseconds(20))
                guard !Task.isCancelled, let self, self.generation == currentGeneration else { return }
                guard let split = self.enclosingSplit(), split.arrangedSubviews.count == 2,
                    split.bounds.width > 0
                else { stableSamples = 0; continue }
                split.setAccessibilityIdentifier("conversation.workspace-split")
                let width = split.bounds.width
                stableSamples = previousWidth.map { abs($0 - width) < 1 } == true ? stableSamples + 1 : 0
                previousWidth = width
                guard stableSamples >= 3 else { continue }
                let available = max(0, width - split.dividerThickness)
                split.setPosition(
                    available * ConversationContentSizing.conversationFraction,
                    ofDividerAt: 0)
                return
            }
        }
    }

    private func enclosingSplit() -> NSSplitView? {
        var ancestor = superview
        while let view = ancestor {
            if let split = view as? NSSplitView { return split }
            ancestor = view.superview
        }
        return nil
    }
}
