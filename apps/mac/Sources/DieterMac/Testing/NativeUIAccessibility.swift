#if DIETER_UI_SMOKE
    import AppKit

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
            // Transcript measurement hosts can contain an offscreen copy of the
            // same control. Only interact with a view mounted in a visible window.
            if let view = NativeUISmokeTargets.frames[identifier]?.compactMap(\.view).first(where: {
                $0.window?.isVisible == true && $0.bounds.width > 0 && $0.bounds.height > 0
            }), let targetWindow = view.window {
                return Element(
                    object: view, recordedFrame: targetWindow.convertToScreen(view.convert(view.bounds, to: nil)),
                    recordedWindow: targetWindow)
            }
            return elements(in: window).first {
                $0.identifier == identifier || (fallbackLabel != nil && $0.text == fallbackLabel && $0.frame.width > 0)
            }
        }

        @discardableResult
        static func click(
            _ identifier: String, in window: NSWindow, horizontalFraction: CGFloat = 0.5, fallbackLabel: String? = nil
        ) -> Bool {
            guard let element = find(identifier, in: window, fallbackLabel: fallbackLabel) else {
                let inventory = elements(in: window).map { "\($0.identifier ?? "-") \($0.text.prefix(100))" }.joined(
                    separator: "\n")
                try? inventory.write(
                    to: WorkspaceUISmokeRunner.outputDirectory().appending(
                        path: "missing-" + identifier.replacingOccurrences(of: "/", with: "_") + ".txt"),
                    atomically: true, encoding: .utf8)
                return false
            }
            let frame = element.recordedFrame ?? element.frame
            guard frame.width > 0, frame.height > 0 else { return false }
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
