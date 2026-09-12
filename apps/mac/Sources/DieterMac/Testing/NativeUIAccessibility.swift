#if DIETER_UI_SMOKE
    import AppKit

    /// Observes the isolated smoke window without changing its presentation.
    /// In particular, distinguish missing geometry from a workspace that was
    /// closed, minimized, hidden, or ordered out while its SwiftUI task survived.
    @MainActor final class NativeUIWindowLifecycleTrace: NSObject {
        private weak var window: NSWindow?
        private let output: URL
        private var eventMonitor: Any?
        private var timer: Timer?
        private var lastEvent = "none"
        private var lastState = ""
        private var lines: [String] = []

        init(window: NSWindow, output: URL) {
            self.window = window
            self.output = output
            super.init()
            let notifications: [Notification.Name] = [
                NSWindow.willCloseNotification, NSWindow.willMiniaturizeNotification,
                NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification,
                NSWindow.didResignKeyNotification,
            ]
            for name in notifications {
                NotificationCenter.default.addObserver(
                    self, selector: #selector(windowChanged(_:)), name: name, object: window)
            }
            for name in [
                NSApplication.didHideNotification, NSApplication.didUnhideNotification,
                NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
            ] {
                NotificationCenter.default.addObserver(
                    self, selector: #selector(applicationChanged(_:)), name: name, object: NSApp)
            }
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) {
                [weak self] event in
                // AppKit invokes local event monitors on its UI thread. Dispatch
                // through the native selector just like the notification/timer
                // callbacks so modal Save panels do not consult Swift's executor
                // identity through assumeIsolated. Keep event evidence synchronous.
                _ = self?.perform(#selector(NativeUIWindowLifecycleTrace.recordLocalEvent(_:)), with: event)
                return event
            }
            let timer = Timer(
                timeInterval: 0.1, target: self, selector: #selector(presentationChanged), userInfo: nil, repeats: true)
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
            record("trace started")
        }

        func stop() {
            record("trace stopped")
            NotificationCenter.default.removeObserver(self)
            if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
            eventMonitor = nil
            timer?.invalidate()
            timer = nil
        }

        @objc private func windowChanged(_ notification: Notification) {
            record(
                notification.name.rawValue,
                stack: notification.name == NSWindow.willCloseNotification
                    || notification.name == NSWindow.willMiniaturizeNotification)
        }

        @objc private func applicationChanged(_ notification: Notification) {
            record(notification.name.rawValue, stack: notification.name == NSApplication.didHideNotification)
        }

        @objc private func recordLocalEvent(_ event: NSEvent) {
            lastEvent = Self.describe(event)
            record("local event")
        }

        @objc private func presentationChanged() {
            if state != lastState { record("presentation state changed") }
        }

        private var state: String {
            guard let window else { return "workspace deallocated" }
            return
                "window=\(window.windowNumber) visible=\(window.isVisible) miniaturized=\(window.isMiniaturized) key=\(window.isKeyWindow) occlusion=\(window.occlusionState.rawValue) appHidden=\(NSApp.isHidden) active=\(NSApp.isActive) sheet=\(window.attachedSheet?.windowNumber ?? -1)"
        }

        private static func describe(_ event: NSEvent?) -> String {
            guard let event else { return "none" }
            let characters =
                event.type == .keyDown || event.type == .keyUp ? event.charactersIgnoringModifiers ?? "" : ""
            return
                "type=\(event.type.rawValue) characters=\(String(reflecting: characters)) modifiers=\(event.modifierFlags.rawValue) window=\(event.windowNumber) point=\(event.locationInWindow) clickCount=\(event.type == .leftMouseDown || event.type == .rightMouseDown ? event.clickCount : 0)"
        }

        private func record(_ event: String, stack: Bool = false) {
            lastState = state
            lines.append(
                "\(ProcessInfo.processInfo.systemUptime) \(event): \(lastState) current={\(Self.describe(NSApp.currentEvent))} last={\(lastEvent)}"
            )
            if stack { lines.append(contentsOf: Thread.callStackSymbols) }
            try? lines.joined(separator: "\n").write(to: output, atomically: true, encoding: .utf8)
        }
    }

    /// Resolve current native accessibility geometry, then deliver real mouse/key
    /// events. Tests must still assert the resulting model and rendered state.
    @MainActor enum NativeUIAccessibility {
        struct Element {
            let object: NSObject
            var recordedFrame: CGRect? = nil
            var recordedWindow: NSWindow? = nil
            func value(_ key: String) -> Any? {
                guard object.responds(to: NSSelectorFromString(key)) else { return nil }
                return object.value(forKey: key)
            }
            var identifier: String? { value("accessibilityIdentifier") as? String }
            var frame: NSRect { (value("accessibilityFrame") as? NSValue)?.rectValue ?? .zero }
            var text: String {
                ["accessibilityValue", "accessibilityLabel", "accessibilityTitle"].compactMap { value($0) as? String }
                    .joined(separator: " ")
            }
        }

        static func elements(in window: NSWindow) -> [Element] {
            var pending: [Any] = [window]
            var result: [Element] = []
            var visited: Set<ObjectIdentifier> = []
            while let next = pending.popLast(), result.count < 20_000 {
                guard let object = next as? NSObject, visited.insert(ObjectIdentifier(object)).inserted else {
                    continue
                }
                let element = Element(object: object)
                result.append(element)
                pending.append(contentsOf: element.value("accessibilityChildren") as? [Any] ?? [])
            }
            return result
        }

        static func find(_ identifier: String, in window: NSWindow, fallbackLabel: String? = nil) -> Element? {
            // Retained split panes and transcript measurement hosts can contain
            // another copy of the same control. A hidden pane still has a visible
            // window and nonzero bounds, so reject its entire hidden ancestry.
            if let view = NativeUISmokeTargets.frames[identifier]?.compactMap(\.view).first(where: {
                $0.window?.isVisible == true
                    && !$0.isHiddenOrHasHiddenAncestor
                    && $0.bounds.width > 0 && $0.bounds.height > 0
            }), let targetWindow = view.window {
                return Element(
                    object: view, recordedFrame: targetWindow.convertToScreen(view.convert(view.bounds, to: nil)),
                    recordedWindow: targetWindow)
            }
            let windows =
                [window] + NSApp.windows.filter { $0 !== window && $0.isVisible && ($0.isSheet || $0.parent == window) }
            for candidate in windows {
                if var element = elements(in: candidate).first(where: {
                    $0.identifier == identifier
                        || (fallbackLabel != nil && $0.text.contains(fallbackLabel!) && $0.frame.width > 0)
                }) {
                    element.recordedFrame = element.frame
                    element.recordedWindow = candidate
                    return element
                }
            }
            return nil
        }

        static func hasOpenInspector(in window: NSWindow) -> Bool {
            guard let root = window.contentView else { return false }
            var views = [root]
            while let view = views.popLast() {
                if let split = view as? NSSplitView, let controller = split.delegate as? NSSplitViewController,
                    (controller as? BoardConversationSplitController)?.presented == true
                        || controller.splitViewItems.contains(where: { $0.behavior == .inspector && !$0.isCollapsed })
                {
                    return true
                }
                views.append(contentsOf: view.subviews)
            }
            return false
        }

        static func navigationSplitController(in window: NSWindow) -> NSSplitViewController? {
            guard let root = window.contentView else { return nil }
            var views = [root]
            while let view = views.popLast() {
                if let split = view as? NSSplitView, split.isVertical,
                    let controller = split.delegate as? NSSplitViewController,
                    !(controller is BoardConversationSplitController),
                    controller.splitViewItems.first?.behavior == .sidebar
                {
                    return controller
                }
                views.append(contentsOf: view.subviews)
            }
            return nil
        }

        @discardableResult
        static func selectSegment(_ index: Int, identifier: String, in window: NSWindow) -> Bool {
            guard let element = find(identifier, in: window), let host = element.recordedWindow,
                let root = host.contentView
            else { return false }
            var views = [root]
            while let view = views.popLast() {
                if let control = view as? NSSegmentedControl, index < control.segmentCount,
                    let frame = element.recordedFrame,
                    frame.intersects(host.convertToScreen(control.convert(control.bounds, to: nil)))
                {
                    control.selectedSegment = index
                    return control.sendAction(control.action, to: control.target)
                }
                views.append(contentsOf: view.subviews)
            }
            return false
        }

        /// SwiftUI registers sheet controls before AppKit finishes positioning
        /// their window. Wait for stable screen geometry before a mouse fallback.
        static func pressWhenSettled(_ identifier: String, in window: NSWindow) async -> Bool {
            var lastFrame: CGRect?
            var lastWindow: NSWindow?
            var stableSamples = 0
            let settled = await wait(timeout: 5) {
                guard let target = find(identifier, in: window),
                    let host = target.recordedWindow, host.isVisible,
                    let frame = target.recordedFrame, frame.width > 0, frame.height > 0
                else {
                    stableSamples = 0
                    return false
                }
                if frame == lastFrame, host === lastWindow {
                    stableSamples += 1
                } else {
                    stableSamples = 0
                }
                lastFrame = frame
                lastWindow = host
                return stableSamples >= 4
            }
            guard settled, let host = lastWindow else {
                recordMissingTarget(identifier, in: window, reason: "native geometry did not settle")
                return false
            }
            return press(identifier, in: host)
        }

        /// Native toolbar items may be hosted outside the SwiftUI content tree.
        /// Invoke their public accessibility action and assert the resulting UI.
        @discardableResult
        static func press(_ identifier: String, in window: NSWindow, fallbackLabel: String? = nil) -> Bool {
            if let element = elements(in: window).first(where: {
                $0.identifier == identifier || (fallbackLabel != nil && $0.text.contains(fallbackLabel!))
            }), let accessible = element.object as? NSAccessibilityProtocol,
                accessible.accessibilityPerformPress()
            {
                return true
            }
            return click(identifier, in: window, fallbackLabel: fallbackLabel)
        }

        @discardableResult
        static func hover(_ identifier: String, in window: NSWindow) -> Bool {
            guard let element = find(identifier, in: window) else { return false }
            let frame = element.recordedFrame ?? element.frame
            guard frame.width > 0, frame.height > 0 else { return false }
            return movePointer(to: NSPoint(x: frame.midX, y: frame.midY))
        }

        @discardableResult
        static func movePointer(to point: NSPoint) -> Bool {
            let location = CGPoint(x: point.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - point.y)
            guard
                let event = CGEvent(
                    mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: location, mouseButton: .left)
            else { return false }
            guard CGWarpMouseCursorPosition(location) == .success else { return false }
            event.postToPid(ProcessInfo.processInfo.processIdentifier)
            return true
        }

        @discardableResult
        static func click(
            _ identifier: String, in window: NSWindow, horizontalFraction: CGFloat = 0.5, fallbackLabel: String? = nil
        ) -> Bool {
            guard let element = find(identifier, in: window, fallbackLabel: fallbackLabel) else {
                recordMissingTarget(identifier, in: window, reason: "no native click target")
                return false
            }
            let frame = element.recordedFrame ?? element.frame
            guard frame.width > 0, frame.height > 0 else {
                recordMissingTarget(identifier, in: window, reason: "empty native click frame \(frame)")
                return false
            }
            let window = element.recordedWindow ?? window
            let point = window.convertPoint(
                fromScreen: NSPoint(x: frame.minX + frame.width * horizontalFraction, y: frame.midY))
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            for type in [NSEvent.EventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                    pressure: type == .leftMouseDown ? 1 : 0)
                {
                    // Native tracking controls consume mouse-up from the event
                    // queue while handling mouse-down. Queue the complete gesture.
                    NSApp.postEvent(event, atStart: false)
                }
            }
            return true
        }

        private static func recordMissingTarget(_ identifier: String, in window: NSWindow, reason: String) {
            var lines = [
                "target=\(identifier) reason=\(reason)",
                "captured window=\(window.windowNumber) visible=\(window.isVisible) key=\(window.isKeyWindow) frame=\(window.frame) sheet=\(window.attachedSheet?.windowNumber ?? -1) taskCancelled=\(Task.isCancelled)",
                "application active=\(NSApp.isActive)",
            ]
            for candidate in NSApp.windows {
                lines.append(
                    "app window=\(candidate.windowNumber) title=\(candidate.title) visible=\(candidate.isVisible) key=\(candidate.isKeyWindow) frame=\(candidate.frame)"
                )
            }
            let entries = NativeUISmokeTargets.frames[identifier] ?? []
            lines.append("registered anchors=\(entries.count)")
            for entry in entries {
                guard let anchor = entry.view else { lines.append("deallocated anchor"); continue }
                var ancestor: NSView? = anchor
                while let view = ancestor {
                    lines.append(
                        "\(Swift.type(of: view)) frame=\(view.frame) bounds=\(view.bounds) hidden=\(view.isHidden) window=\(view.window?.windowNumber ?? -1)"
                    )
                    ancestor = view.superview
                }
            }
            lines.append("accessibility inventory:")
            lines.append(contentsOf: elements(in: window).map { "\($0.identifier ?? "-") \($0.text.prefix(100))" })
            try? lines.joined(separator: "\n").write(
                to: WorkspaceUISmokeRunner.outputDirectory().appending(
                    path: "missing-" + identifier.replacingOccurrences(of: "/", with: "_") + ".txt"),
                atomically: true, encoding: .utf8)
        }

        static func type(_ text: String, in window: NSWindow) async {
            let pasteboard = NSPasteboard.general
            let saved = (pasteboard.pasteboardItems ?? []).map { item in
                item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) { values, type in
                    values[type] = item.data(forType: type)
                }
            }
            defer {
                pasteboard.clearContents()
                let items = saved.map { values in
                    let item = NSPasteboardItem()
                    for (type, data) in values { item.setData(data, forType: type) }
                    return item
                }
                if !items.isEmpty { pasteboard.writeObjects(items) }
            }
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let event = NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: [.command],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: "v", charactersIgnoringModifiers: "v",
                    isARepeat: false, keyCode: 9)
                {
                    NSApp.postEvent(event, atStart: false)
                }
            }
            try? await DieterTaskSleep.milliseconds(300)
        }

        static func containsText(_ text: String, in window: NSWindow) -> Bool {
            elements(in: window).contains { $0.text.contains(text) } || NativeUISmokeTargets.diffText.contains(text)
        }

        static func horizontalScrollView(_ identifier: String, in window: NSWindow) -> NSScrollView? {
            guard let target = find(identifier, in: window), let root = window.contentView else { return nil }
            let frame = target.recordedFrame ?? target.frame
            var pending = [root]
            while let view = pending.popLast() {
                pending.append(contentsOf: view.subviews)
                if let scroll = view as? NSScrollView,
                    (scroll.documentView?.frame.width ?? 0) > scroll.contentSize.width + 1
                {
                    let screenFrame = window.convertToScreen(scroll.convert(scroll.bounds, to: nil))
                    if frame.contains(NSPoint(x: screenFrame.midX, y: screenFrame.midY)) { return scroll }
                }
            }
            return nil
        }

        @discardableResult
        static func scrollHorizontally(_ identifier: String, in window: NSWindow, delta: Int32) -> Bool {
            guard let scroll = horizontalScrollView(identifier, in: window),
                let cgEvent = CGEvent(
                    scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: delta, wheel3: 0),
                let event = NSEvent(cgEvent: cgEvent)
            else { return false }
            scroll.scrollWheel(with: event)
            return true
        }

        static func arrow(down: Bool, in window: NSWindow) {
            let character = String(UnicodeScalar(down ? 0xF701 : 0xF700)!)
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let event = NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: character,
                    charactersIgnoringModifiers: character, isARepeat: false, keyCode: down ? 125 : 126)
                {
                    NSApp.postEvent(event, atStart: false)
                }
            }
        }

        static func wait(timeout: TimeInterval = 10, until condition: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if condition() { return true }
                try? await DieterTaskSleep.milliseconds(50)
            }
            return condition()
        }
    }
#endif
