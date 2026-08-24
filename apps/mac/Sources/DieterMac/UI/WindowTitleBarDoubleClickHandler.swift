import AppKit
import SwiftUI

/// Restores AppKit's standard title-bar zoom toggle when SwiftUI draws content
/// into the title bar with `.windowStyle(.hiddenTitleBar)`.
struct WindowTitleBarDoubleClickHandler: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowTitleBarDoubleClickView {
        WindowTitleBarDoubleClickView()
    }

    func updateNSView(_ nsView: WindowTitleBarDoubleClickView, context: Context) {}

    static func dismantleNSView(_ nsView: WindowTitleBarDoubleClickView, coordinator: ()) {
        nsView.stopMonitoring()
    }
}

@MainActor
final class WindowTitleBarDoubleClickView: NSView {
    private var eventMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoring()
        guard let window else { return }

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak window] event in
            guard let window, Self.shouldZoom(for: event, in: window) else { return event }
            window.performZoom(nil)
            return nil
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func stopMonitoring() {
        guard let eventMonitor else { return }
        NSEvent.removeMonitor(eventMonitor)
        self.eventMonitor = nil
    }

    static func shouldZoom(for event: NSEvent, in window: NSWindow) -> Bool {
        guard event.type == .leftMouseDown,
              event.clickCount == 2,
              event.window === window,
              window.styleMask.contains(.titled),
              window.styleMask.contains(.resizable),
              !window.styleMask.contains(.fullScreen),
              !window.isSheet,
              let zoomButton = window.standardWindowButton(.zoomButton),
              zoomButton.isEnabled,
              !zoomButton.isHidden
        else { return false }

        let location = event.locationInWindow
        guard location.y >= window.contentLayoutRect.maxY else { return false }

        let windowButtons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        return !windowButtons.contains { type in
            guard let button = window.standardWindowButton(type) else { return false }
            return button.convert(button.bounds, to: nil).insetBy(dx: -2, dy: -2).contains(location)
        }
    }
}
