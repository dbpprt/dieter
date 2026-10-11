import AppKit

/// A first click can put the inspector over the original card. Keep only that
/// click's edit action briefly, so the second click still addresses the same
/// card without delaying every ordinary click. Normal drags never arm this:
/// the card's completed single-tap action is the only entry point.
@MainActor final class BoardCardDoubleClickTracker: NSObject {
    static let shared = BoardCardDoubleClickTracker()
    private var firstClick: NSEvent?
    private var edit: (() -> Void)?
    private var monitor: Any?

    func arm(after event: NSEvent?, edit: @escaping () -> Void) {
        cancel()
        guard let event, event.type == .leftMouseUp, event.clickCount == 1 else { return }
        firstClick = event
        self.edit = edit
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel]
        ) { [weak self] event in
            guard let self else { return event }
            // Local monitors run on AppKit's UI thread, including modal loops.
            // Use native dispatch instead of asserting a Swift task executor.
            return self.perform(#selector(BoardCardDoubleClickTracker.filter(_:)), with: event)?
                .takeUnretainedValue() as? NSEvent
        }
        // Input timestamps, not processing time, determine a double click.
        // A layout stall can queue the second click behind a wall-clock timer;
        // expiring here would discard a valid click before AppKit delivers it.
        // Retain at most one action until the next input or window deactivation.
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDeactivated(_:)),
            name: NSWindow.didResignKeyNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDeactivated(_:)),
            name: NSWindow.willCloseNotification, object: nil)
    }

    @objc func filter(_ event: NSEvent) -> NSEvent? {
        guard let first = firstClick, let edit else { return event }
        let elapsed = event.timestamp - first.timestamp
        let matches =
            event.type == .leftMouseDown && event.clickCount == 2
            && event.windowNumber == first.windowNumber
            && elapsed >= 0 && elapsed <= NSEvent.doubleClickInterval
            && abs(event.locationInWindow.x - first.locationInWindow.x) <= 4
            && abs(event.locationInWindow.y - first.locationInWindow.y) <= 4
        cancel()
        guard matches else { return event }
        edit()
        // Do not deliver the second mouse-down to a different control which
        // the newly opened inspector placed under the pointer.
        return nil
    }

    @objc private func windowDeactivated(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
            window.windowNumber == firstClick?.windowNumber
        else { return }
        cancel()
    }

    func cancel() {
        NotificationCenter.default.removeObserver(self)
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        firstClick = nil
        edit = nil
    }
}
