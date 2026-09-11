import AppKit
import SwiftUI

enum MarkdownEditorLayout: String, CaseIterable {
    case source, split, preview

    var title: String {
        switch self {
        case .source: "Source"
        case .split: "Split"
        case .preview: "Preview"
        }
    }

    var symbol: String {
        switch self {
        case .source: "chevron.left.forwardslash.chevron.right"
        case .split: "rectangle.split.2x1"
        case .preview: "doc.richtext"
        }
    }
}

/// AppKit owns divider tracking and pane collapse. Both SwiftUI hosts remain
/// mounted so switching layout retains the editor buffer, selection and undo.
struct MarkdownEditorSplitView: NSViewControllerRepresentable {
    let source: AnyView
    let preview: AnyView
    let layout: MarkdownEditorLayout
    var scrollCoordinator: MarkdownScrollCoordinator?
    var richEditing = false

    func makeNSViewController(context: Context) -> MarkdownEditorSplitController {
        MarkdownEditorSplitController()
    }

    func updateNSViewController(_ controller: MarkdownEditorSplitController, context: Context) {
        controller.sourceHost.rootView = source
        controller.previewHost.rootView = preview
        controller.scrollCoordinator = scrollCoordinator
        scrollCoordinator?.configure(enabled: layout == .split, richEditing: richEditing)
        controller.setLayout(layout)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize, nsViewController: MarkdownEditorSplitController, context: Context
    ) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height, width.isFinite, height.isFinite else {
            return nil
        }
        return CGSize(width: width, height: height)
    }
}

@MainActor
final class MarkdownEditorSplitController: NSSplitViewController {
    let sourceHost = NSHostingView(rootView: AnyView(EmptyView()))
    let previewHost = NSHostingView(rootView: AnyView(EmptyView()))
    private(set) var layout: MarkdownEditorLayout = .split
    private var sourceFraction: CGFloat = 0.5
    private var restoreDivider = true
    weak var scrollCoordinator: MarkdownScrollCoordinator?

    init() {
        super.init(nibName: nil, bundle: nil)
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.setAccessibilityIdentifier("files.markdown.native-split")
        for (host, minimum) in [(sourceHost, CGFloat(140)), (previewHost, CGFloat(220))] {
            host.sizingOptions = []
            let controller = NSViewController()
            controller.view = host
            let item = NSSplitViewItem(viewController: controller)
            item.minimumThickness = minimum
            item.canCollapse = false
            item.canCollapseFromWindowResize = false
            item.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
            item.holdingPriority = .init(250)
            addSplitViewItem(item)
        }
    }

    required init?(coder: NSCoder) { nil }

    func setLayout(_ newLayout: MarkdownEditorLayout) {
        guard layout != newLayout else { return }
        if layout == .split, !restoreDivider, splitView.bounds.width > 0 {
            sourceFraction = sourceHost.frame.width / splitView.bounds.width
        }
        layout = newLayout
        // Release a responder that is about to become hidden, keeping its
        // selection and undo manager attached to the retained source view.
        if let responder = view.window?.firstResponder as? NSView {
            let hidden = newLayout == .source ? previewHost : newLayout == .preview ? sourceHost : nil
            if let hidden, responder === hidden || responder.isDescendant(of: hidden) {
                view.window?.makeFirstResponder(nil)
            }
        }
        // Collapse the outgoing pane first. Expanding a retained full-width
        // pane while its sibling is still visible can make AppKit enlarge the
        // window to fit both, changing the divider's restored position.
        if newLayout == .preview { splitViewItems[0].isCollapsed = true }
        if newLayout == .source { splitViewItems[1].isCollapsed = true }
        splitViewItems[0].isCollapsed = newLayout == .preview
        splitViewItems[1].isCollapsed = newLayout == .source
        restoreDivider = newLayout == .split
        view.needsLayout = true
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if let editor = sourceTextView(in: sourceHost), let scroll = editor.enclosingScrollView {
            scrollCoordinator?.attachSource(scroll)
        }
        guard restoreDivider, layout == .split, splitView.bounds.width >= 361 else { return }
        restoreDivider = false
        splitView.setPosition(splitView.bounds.width * sourceFraction, ofDividerAt: 0)
    }

    private func sourceTextView(in view: NSView) -> NSTextView? {
        if let editor = view as? NSTextView { return editor }
        return view.subviews.lazy.compactMap { self.sourceTextView(in: $0) }.first
    }
}
