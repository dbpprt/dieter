import AppKit
import SwiftUI

/// A native sheet normally ignores clicks on its parent. Close an unchanged
/// draft on that click, consuming it so the underlying card is not activated.
struct SheetOutsideClickDismissal: NSViewRepresentable {
    let enabled: Bool
    let dismiss: () -> Void

    func makeNSView(context: Context) -> OutsideClickSheetView { OutsideClickSheetView() }
    func updateNSView(_ view: OutsideClickSheetView, context: Context) {
        view.dismissEnabled = enabled
        view.dismiss = dismiss
    }
    static func dismantleNSView(_ view: OutsideClickSheetView, coordinator: ()) { view.stopMonitoring() }
}

final class OutsideClickSheetView: NSView {
    var dismissEnabled = false
    var dismiss: () -> Void = {}
    private var monitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoring()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, let sheet = self.window, let parent = sheet.sheetParent,
                  sheet.attachedSheet == nil,
                  Self.shouldDismiss(enabled: self.dismissEnabled, belongsToParent: event.window === parent,
                                     point: parent.convertPoint(toScreen: event.locationInWindow), sheetFrame: sheet.frame)
            else { return event }
            self.dismiss()
            return nil
        }
    }

    func stopMonitoring() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    static func shouldDismiss(enabled: Bool, belongsToParent: Bool, point: NSPoint, sheetFrame: NSRect) -> Bool {
        enabled && belongsToParent && !sheetFrame.contains(point)
    }
}
