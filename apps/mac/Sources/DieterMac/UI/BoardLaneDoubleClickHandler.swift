import AppKit
import SwiftUI

/// The native List owns card clicks. Only unused lane space creates a card.
struct BoardLaneDoubleClickHandler: NSViewRepresentable {
    var create: () -> Void

    func makeNSView(context: Context) -> LaneClickView { LaneClickView() }
    func updateNSView(_ view: LaneClickView, context: Context) { view.create = create }

    static func dismantleNSView(_ view: LaneClickView, coordinator: ()) { view.stopMonitoring() }

    final class LaneClickView: NSView {
        var create: (() -> Void)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let self, event.clickCount == 2, event.window === window,
                    bounds.contains(convert(event.locationInWindow, from: nil)),
                    Self.isUnusedSpace(event.locationInWindow, in: window)
                else { return event }
                create?()
                return nil
            }
        }

        static func isUnusedSpace(_ point: NSPoint, in window: NSWindow?) -> Bool {
            guard let root = window?.contentView else { return false }
            var hit = root.hitTest(root.convert(point, from: nil))
            while let view = hit {
                if view is NSControl && !(view is NSTableView) { return false }
                if let table = view as? NSTableView {
                    return table.row(at: table.convert(point, from: nil)) == -1
                }
                if view is NSTableCellView { return false }
                hit = view.superview
            }
            return true
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        }
    }
}
