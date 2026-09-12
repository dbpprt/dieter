import AppKit
import SwiftUI

struct ConversationContentPane: View {
    @Bindable var model: ConversationContentModel

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            if let error = model.error {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(error).textSelection(.enabled)
                    Spacer(minLength: 0)
                }
                .font(.caption).foregroundStyle(.secondary).padding(12)
                .accessibilityIdentifier("conversation.content.error")
            }
            if model.tabs.isEmpty {
                if model.loading { LoadFeedback(title: "Opening…") } else { launcher }
            } else {
                ZStack {
                    ForEach(model.tabs) { tab in
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
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(model.tabs) { tab in
                            ConversationWorkspaceTabLabel(
                                tab: tab, selected: model.selectedTabID == tab.id,
                                select: { model.selectTab(tab.id) },
                                close: { Task { await model.closeTab(tab.id) } }
                            )
                            .id(tab.id)
                        }
                    }.padding(.horizontal, 6)
                }
                .onChange(of: model.selectedTabID, initial: true) { _, selectedID in
                    if let selectedID { proxy.scrollTo(selectedID, anchor: .trailing) }
                }
            }
            Menu {
                ForEach(ConversationPanelKind.allCases) { kind in
                    Button(kind.title, systemImage: kind.symbol) {
                        model.requestPanel(kind, conversationID: model.conversationID)
                    }
                    .accessibilityIdentifier("conversation.content.add.\(kind.rawValue)")
                }
            } label: {
                Image(systemName: "plus").frame(width: 28, height: 30)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Open a workspace tab")
            .accessibilityLabel("Open a workspace tab")
            .accessibilityIdentifier("conversation.content.add").smokeTarget("conversation.content.add")
            Button {
                model.hide()
            } label: {
                Image(systemName: "sidebar.right").frame(width: 28, height: 30)
            }
            .buttonStyle(.borderless)
            .help("Hide workspace pane").accessibilityLabel("Hide workspace pane")
            .accessibilityIdentifier("conversation.content.close").smokeTarget("conversation.content.close")
            .padding(.trailing, 6)
        }
        .frame(height: 40)
        .background(DieterTheme.sidebar.opacity(0.4))
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
                ForEach(ConversationPanelKind.allCases) { kind in
                    Button {
                        model.requestPanel(kind, conversationID: model.conversationID)
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

private struct ConversationWorkspaceTabLabel: View {
    @Bindable var tab: ConversationContentTab
    let selected: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: select) {
                HStack(spacing: 6) {
                    Image(systemName: tab.symbol).font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(tab.title).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                    if tab.dirty { Circle().fill(.secondary).frame(width: 5, height: 5) }
                }
                .frame(minWidth: 36, maxWidth: 180, minHeight: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(tab.title)
            .accessibilityAddTraits(selected ? [.isSelected] : [])
            .accessibilityIdentifier("conversation.content.tab.\(tab.id.uuidString)")
            .smokeTarget("conversation.content.tab.\(tab.id.uuidString)")
            Button(action: close) { Image(systemName: "xmark").font(.system(size: 9, weight: .medium)) }
                .buttonStyle(.plain).frame(width: 18, height: 24)
                .opacity(selected || hovering ? 1 : 0)
                .help("Close \(tab.title)").accessibilityLabel("Close \(tab.title)")
                .accessibilityIdentifier("conversation.content.tab.\(tab.id.uuidString).close")
                .smokeTarget("conversation.content.tab.\(tab.id.uuidString).close")
        }
        .padding(.leading, 9).padding(.trailing, 3)
        .background(selected ? DieterTheme.surface : .clear, in: RoundedRectangle(cornerRadius: 7))
        .overlay(alignment: .bottom) {
            if selected { Capsule().fill(.secondary.opacity(0.6)).frame(height: 2).padding(.horizontal, 8) }
        }
        .onHover { hovering = $0 }
    }
}

private struct ConversationWorkspaceTabView: View {
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
            .help(path.isEmpty ? tab.rootPath : path)
            Spacer(minLength: 6)
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

/// Keeps the transcript subtree mounted as the secondary column appears. The
/// native split divider supplies resizing, keyboard access and pointer feedback.
struct ConversationContentSplit<Chat: View, Content: View>: View {
    let presented: Bool
    @ViewBuilder let chat: () -> Chat
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { geometry in
            HSplitView {
                chat()
                    .frame(
                        minWidth: presented ? min(280, geometry.size.width * 0.4) : 0,
                        idealWidth: presented ? geometry.size.width * 0.45 : geometry.size.width,
                        maxWidth: .infinity, maxHeight: .infinity
                    )
                    .clipped()
                    .background(ConversationSplitPositioner(presented: presented))
                if presented {
                    content()
                        .frame(
                            minWidth: min(300, geometry.size.width * 0.45),
                            idealWidth: geometry.size.width * 0.55,
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
                let width = split.bounds.width
                stableSamples = previousWidth.map { abs($0 - width) < 1 } == true ? stableSamples + 1 : 0
                previousWidth = width
                guard stableSamples >= 3 else { continue }
                let available = max(0, width - split.dividerThickness)
                split.setPosition(available * 0.45, ofDividerAt: 0)
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
