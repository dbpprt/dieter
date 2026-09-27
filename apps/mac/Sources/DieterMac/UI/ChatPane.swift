import AppKit
import DieterAPI
import SwiftUI
import UniformTypeIdentifiers

struct ChatDetailPane: View {
    @Environment(DieterStore.self) private var store
    let showArchived: Bool

    var body: some View {
        if store.selectedChatID != nil {
            ConversationView(
                compact: store.conversationContext.content.isPresented(for: store.selectedChatID),
                surfaceStyle: .inherited
            )
            .environment(store.conversationContext)
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

enum ChatPaneLayout {
    case chats
    case inbox

    var identifier: String { self == .inbox ? "inbox" : "chats" }
    var preference: String { self == .inbox ? "dieter.inboxPaneWidth" : "dieter.chatBrowserPaneWidth" }
    var defaultWidth: CGFloat { self == .inbox ? 340 : ChatPaneSizing.defaultWidth }
    var minimumWidth: CGFloat { self == .inbox ? 300 : ChatPaneSizing.minimumWidth }
    var maximumWidth: CGFloat { self == .inbox ? 420 : ChatPaneSizing.maximumWidth }

    func resolvedWidth(_ requested: CGFloat, available: CGFloat) -> CGFloat {
        if self == .chats {
            return ChatPaneSizing.resolvedWidth(requested, workspaceWidth: available)
        }
        let limit = max(0, available - ChatPaneSizing.minimumDetailWidth)
        return min(max(requested, minimumWidth), maximumWidth, limit)
    }
}

/// A native AppKit split keeps the chat browser mounted and width-controlled
/// independently from the selected conversation's intrinsic content size.
struct ChatPaneSplit<Browser: View, Detail: View>: View {
    let browser: Browser
    let detail: Detail
    let layout: ChatPaneLayout
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage private var storedWidth: Double

    init(
        layout: ChatPaneLayout = .chats,
        @ViewBuilder browser: () -> Browser,
        @ViewBuilder detail: () -> Detail
    ) {
        self.layout = layout
        _storedWidth = AppStorage(wrappedValue: Double(layout.defaultWidth), layout.preference)
        self.browser = browser()
        self.detail = detail()
    }

    var body: some View {
        NativeChatPaneSplit(
            layout: layout,
            browser: AnyView(
                browser
                    .environment(\.colorScheme, colorScheme)
                    .background { DieterPaneBackground(role: .navigation, extendsUnderTitlebar: true) }),
            detail: AnyView(
                detail
                    .environment(\.colorScheme, colorScheme)
                    .background { DieterPaneBackground(role: .content, extendsUnderTitlebar: true) }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("\(layout.identifier).detail-pane")
                    .smokeTarget("\(layout.identifier).detail-pane")),
            preferredWidth: CGFloat(storedWidth),
            onWidthChange: { storedWidth = Double($0) }
        )
        // The real native divider also owns the titlebar continuation; each
        // split item still respects its content safe area below the toolbar.
        .ignoresSafeArea(.container, edges: .top)
    }
}

struct NativeChatPaneSplit: NSViewControllerRepresentable {
    let layout: ChatPaneLayout
    let browser: AnyView
    let detail: AnyView
    let preferredWidth: CGFloat
    let onWidthChange: (CGFloat) -> Void

    func makeNSViewController(context: Context) -> NativeChatPaneSplitController {
        NativeChatPaneSplitController(layout: layout)
    }

    func updateNSViewController(_ controller: NativeChatPaneSplitController, context: Context) {
        controller.browserHost.rootView = browser
        controller.detailHost.rootView = detail
        controller.configure(preferredWidth: preferredWidth, onWidthChange: onWidthChange)
    }
}

@MainActor
final class NativeChatPaneSplitController: NSSplitViewController {
    let browserHost = NSHostingView(rootView: AnyView(EmptyView()))
    let detailHost = NSHostingView(rootView: AnyView(EmptyView()))
    private let layout: ChatPaneLayout
    private var preferredWidth = ChatPaneSizing.defaultWidth
    private var reportedWidth: CGFloat?
    private var restoreWidth = true
    private var restoreScheduled = false
    private var reportScheduled = false
    private var onWidthChange: (CGFloat) -> Void = { _ in }

    init(layout: ChatPaneLayout) {
        self.layout = layout
        preferredWidth = layout.defaultWidth
        super.init(nibName: nil, bundle: nil)
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.setAccessibilityIdentifier("\(layout.identifier).resize-divider")
        split.setAccessibilityLabel(layout == .inbox ? "Resize inbox" : "Resize chat browser")
        splitView = split

        browserHost.sizingOptions = []
        detailHost.sizingOptions = []
        let browserController = NSViewController()
        browserController.view = browserHost
        let detailController = NSViewController()
        detailController.view = detailHost
        let browserItem = NSSplitViewItem(viewController: browserController)
        browserItem.minimumThickness = layout.minimumWidth
        browserItem.maximumThickness = layout.maximumWidth
        browserItem.canCollapse = false
        browserItem.canCollapseFromWindowResize = false
        // Stay below AppKit's divider-drag priority (490), or restoring and
        // dragging the divider lose to the pane's current-width constraint.
        browserItem.holdingPriority = .init(480)
        let detailItem = NSSplitViewItem(viewController: detailController)
        detailItem.minimumThickness = ChatPaneSizing.minimumDetailWidth
        detailItem.canCollapse = false
        detailItem.canCollapseFromWindowResize = false
        detailItem.holdingPriority = .init(240)
        addSplitViewItem(browserItem)
        addSplitViewItem(detailItem)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func configure(preferredWidth: CGFloat, onWidthChange: @escaping (CGFloat) -> Void) {
        loadViewIfNeeded()
        self.onWidthChange = onWidthChange
        if abs(self.preferredWidth - preferredWidth) > 0.5 {
            self.preferredWidth = preferredWidth
            restoreWidth = true
            view.needsLayout = true
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard splitView.bounds.width > 0, splitView.arrangedSubviews.count == 2 else { return }
        if restoreWidth || reportedWidth == nil {
            guard !restoreScheduled,
                splitView.bounds.width >= layout.minimumWidth + ChatPaneSizing.minimumDetailWidth
            else { return }
            restoreScheduled = true
            // Defer AppKit's immediate layout until SwiftUI has finished
            // flushing its graph, matching the board conversation split.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let target = self.layout.resolvedWidth(self.preferredWidth, available: self.splitView.bounds.width)
                self.splitView.setPosition(target, ofDividerAt: 0)
                self.splitView.layoutSubtreeIfNeeded()
                self.reportedWidth = self.splitView.arrangedSubviews[0].frame.width
                self.restoreWidth = false
                self.restoreScheduled = false
            }
            return
        }
        let width = splitView.arrangedSubviews[0].frame.width
        guard abs(width - (reportedWidth ?? width)) > 0.5, !reportScheduled else { return }
        reportedWidth = width
        reportScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reportScheduled = false
            guard !self.restoreWidth else { return }
            let currentWidth = self.splitView.arrangedSubviews[0].frame.width
            self.preferredWidth = currentWidth
            self.reportedWidth = currentWidth
            self.onWidthChange(currentWidth)
        }
    }
}
