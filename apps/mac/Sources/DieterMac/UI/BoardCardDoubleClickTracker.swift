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
    private var expiry: DispatchWorkItem?

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
        let expiry = DispatchWorkItem { [weak self] in self?.cancel() }
        self.expiry = expiry
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: expiry)
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

    func cancel() {
        expiry?.cancel()
        expiry = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        firstClick = nil
        edit = nil
    }
}
