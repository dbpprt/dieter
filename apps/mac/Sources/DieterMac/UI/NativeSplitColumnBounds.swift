import AppKit
import SwiftUI

/// Enforces bounds on the native column, not just SwiftUI's content proposal.
struct NativeSplitColumnBounds: NSViewRepresentable {
    let minimum: CGFloat
    let maximum: CGFloat

    func makeNSView(context: Context) -> SplitColumnBoundsView { SplitColumnBoundsView() }

    func updateNSView(_ view: SplitColumnBoundsView, context: Context) {
        view.minimum = minimum
        view.maximum = maximum
        view.scheduleConfiguration()
    }

    static func dismantleNSView(_ view: SplitColumnBoundsView, coordinator: ()) { view.stopObserving() }
}

final class SplitColumnBoundsView: NSView {
    var minimum: CGFloat = 0
    var maximum: CGFloat = .greatestFiniteMagnitude
    private weak var splitView: NSSplitView?
    private weak var column: NSView?
    private var resizeObserver: NSObjectProtocol?
    private var configurationScheduled = false

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopObserving() } else { scheduleConfiguration() }
    }

    func stopObserving() {
        if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
        resizeObserver = nil
        splitView = nil
        column = nil
    }

    func scheduleConfiguration() {
        guard !configurationScheduled else { return }
        configurationScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.configurationScheduled = false
            self.configure()
        }
    }

    private func configure() {
        guard window != nil else { return }
        var ancestor = superview
        while let view = ancestor {
            if let split = view as? NSSplitView, split.isVertical,
                let column = split.arrangedSubviews.first(where: { self.isDescendant(of: $0) })
            {
                if splitView !== split {
                    stopObserving()
                    splitView = split
                    resizeObserver = NotificationCenter.default.addObserver(
                        forName: NSSplitView.didResizeSubviewsNotification, object: split, queue: .main
                    ) { [weak self] _ in
                        MainActor.assumeIsolated { self?.scheduleConfiguration() }
                    }
                }
                self.column = column
                if let controller = split.delegate as? NSSplitViewController,
                    let item = controller.splitViewItems.first(where: { self.isDescendant(of: $0.viewController.view) })
                {
                    if item.minimumThickness != minimum { item.minimumThickness = minimum }
                    if item.maximumThickness != maximum { item.maximumThickness = maximum }
                }
                clampColumn()
                return
            }
            ancestor = view.superview
        }
    }

    private func clampColumn() {
        guard let splitView, let column, !column.isHidden,
            let index = splitView.arrangedSubviews.firstIndex(of: column), column.frame.width > 0
        else { return }
        let width = min(max(column.frame.width, minimum), maximum)
        guard abs(width - column.frame.width) > 1 else { return }
        if index == splitView.arrangedSubviews.count - 1, index > 0 {
            splitView.setPosition(splitView.bounds.width - width - splitView.dividerThickness, ofDividerAt: index - 1)
        } else if index < splitView.arrangedSubviews.count - 1 {
            splitView.setPosition(column.frame.minX + width, ofDividerAt: index)
        }
    }
}
