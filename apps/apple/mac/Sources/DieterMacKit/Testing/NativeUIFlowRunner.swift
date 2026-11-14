#if DIETER_E2E
    import AppKit
    import Foundation

    /// Runs one Maestro flow in-process. Maestro has no macOS driver and
    /// external accessibility cannot see inside SwiftUI hosting views, so the
    /// pipeline converts the YAML into a bounded JSON plan that this runner
    /// interprets against the app's own accessibility hierarchy. It writes
    /// `report.json`, `events.jsonl` and screenshots to `--e2e-output`, then quits.
    @MainActor enum NativeUIFlowRunner {
        struct Failure: Error, CustomStringConvertible {
            let description: String
            init(_ description: String) { self.description = description }
        }

        /// A Maestro selector. `id` and `text` are regular expressions that
        /// match the whole identifier or text; both must match when given.
        struct ElementSelector: CustomStringConvertible {
            struct Pattern {
                let source: String
                let regex: NSRegularExpression

                init(_ source: String) throws {
                    guard let regex = try? NSRegularExpression(pattern: "\\A(?:\(source))\\z") else {
                        throw Failure("Invalid regular expression \(String(reflecting: source))")
                    }
                    self.source = source
                    self.regex = regex
                }

                /// Maestro also accepts the literal pattern and text with line breaks as spaces.
                func matches(_ value: String) -> Bool {
                    let flattened = value.replacingOccurrences(of: "\n", with: " ")
                    return [value, flattened].contains { candidate in
                        candidate == source
                            || regex.firstMatch(in: candidate, range: NSRange(candidate.startIndex..., in: candidate))
                                != nil
                    }
                }
            }

            let id: Pattern?
            let text: Pattern?
            let index: Int

            init(_ value: Any) throws {
                if let text = value as? String {
                    id = nil
                    self.text = try Pattern(text)
                    index = 0
                    return
                }
                guard let fields = value as? [String: Any] else { throw Failure("Invalid selector") }
                if let key = fields.keys.sorted().first(where: { !["id", "text", "index"].contains($0) }) {
                    throw Failure("Unsupported selector \(key) on macOS")
                }
                func pattern(_ key: String) throws -> Pattern? {
                    guard let value = fields[key] else { return nil }
                    guard let source = value as? String, !source.isEmpty else {
                        throw Failure("Invalid \(key) selector")
                    }
                    return try Pattern(source)
                }
                id = try pattern("id")
                text = try pattern("text")
                guard id != nil || text != nil else { throw Failure("Selector needs id or text") }
                if let value = fields["index"] {
                    guard let index = value as? Int, index >= 0 else { throw Failure("Invalid selector index") }
                    self.index = index
                } else {
                    index = 0
                }
            }

            var description: String {
                var parts: [String] = []
                if let id { parts.append("id: \(String(reflecting: id.source))") }
                if let text { parts.append("text: \(String(reflecting: text.source))") }
                if index > 0 { parts.append("index: \(index)") }
                return parts.joined(separator: ", ")
            }

            func matches(_ element: NativeUIAccessibility.Element) -> Bool {
                if let id, !(element.identifier.map(id.matches) ?? false) { return false }
                if let text, !element.texts.contains(where: text.matches) { return false }
                return true
            }

            /// The visible match Maestro would pick: the `index`th in document order.
            @MainActor func resolve(in window: NSWindow) -> NativeUIAccessibility.Element? {
                var remaining = index
                for host in NativeUIAccessibility.windows(from: window) {
                    for element in NativeUIAccessibility.elements(in: host)
                    where element.isVisible && matches(element) {
                        if remaining == 0 { return element }
                        remaining -= 1
                    }
                }
                return nil
            }
        }

        enum Key: String {
            case enter, tab, backspace, escape

            var event: (characters: String, code: UInt16) {
                switch self {
                case .enter: ("\r", 36)
                case .tab: ("\t", 48)
                case .backspace: ("\u{7f}", 51)
                case .escape: ("\u{1b}", 53)
                }
            }
        }

        enum Command {
            case launchApp
            case tapOn(ElementSelector)
            case assertVisible(ElementSelector, visible: Bool)
            case inputText(String)
            case extendedWaitUntil(ElementSelector, visible: Bool, timeout: TimeInterval)
            case takeScreenshot(String)
            case pressKey(Key)
            case scroll
        }

        struct Step {
            let name: String
            let line: Int
            let command: Command
        }

        /// Maestro waits this long for an element before failing a step.
        static let elementTimeout: TimeInterval = 15

        static func run(store: DieterStore) async {
            let output = NativeTestSupport.outputDirectory
            var results: [String: String] = [:]
            var window: NSWindow?
            do {
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                try await NativeTestSupport.awaitForeground()
                let (source, raw) = try loadPlan()
                var steps: [Step] = []
                for (index, value) in raw.enumerated() {
                    do {
                        steps.append(try parse(value))
                    } catch {
                        let line = (value as? [String: Any])?["line"] as? Int ?? 0
                        let failure = "failed: \(source):\(line): \(error)"
                        results["step-\(index)"] = failure
                        throw Failure("\(source):\(line): \(error)")
                    }
                }
                await store.connect()
                for (index, step) in steps.enumerated() {
                    let start = Date()
                    try event(index, step, "started", start, output)
                    do {
                        try await perform(step.command, store: store, window: &window, output: output)
                        results["step-\(index)"] = "passed"
                        try event(index, step, "passed", start, output)
                    } catch {
                        results["step-\(index)"] = "failed: \(source):\(step.line): \(error)"
                        try? event(index, step, "failed", start, output)
                        throw Failure("\(source):\(step.line): \(error)")
                    }
                }
            } catch {
                results["flow"] = "failed: \(error)"
                if let failed = window ?? workspaceWindow() {
                    try? capture(failed, name: "failure", output: output)
                }
            }
            NativeTestSupport.finish(results, to: output)
        }

        private static func loadPlan() throws -> (source: String, steps: [Any]) {
            guard let path = NativeTestSupport.argument("--e2e-flow") else { throw Failure("Missing --e2e-flow") }
            let url = URL(fileURLWithPath: path)
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 256 * 1_024 else { throw Failure("Flow plan exceeds 256 KiB") }
            guard let plan = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
                plan["version"] as? Int == 1,
                let steps = plan["steps"] as? [Any], (1...100).contains(steps.count)
            else { throw Failure("Invalid flow plan: expected version 1 with 1…100 steps") }
            return (plan["source"] as? String ?? url.lastPathComponent, steps)
        }

        /// One Maestro command. Bare commands arrive as `true`; string
        /// shorthands select by text.
        static func parse(_ value: Any) throws -> Step {
            guard let fields = value as? [String: Any] else { throw Failure("Invalid step") }
            let line = fields["line"] as? Int ?? 0
            let names = fields.keys.filter { $0 != "line" }
            guard names.count == 1, let name = names.first, let argument = fields[name] else {
                throw Failure("A step needs exactly one command")
            }
            func options(_ allowed: Set<String>) throws -> [String: Any] {
                guard let options = argument as? [String: Any] else { throw Failure("Invalid \(name) options") }
                if let key = options.keys.sorted().first(where: { !allowed.contains($0) }) {
                    throw Failure("Unsupported \(name) option \(key) on macOS")
                }
                return options
            }
            let command: Command
            switch name {
            case "launchApp":
                if argument as? Bool != true { _ = try options(["appId"]) }
                command = .launchApp
            case "tapOn":
                command = .tapOn(try ElementSelector(argument))
            case "assertVisible", "assertNotVisible":
                command = .assertVisible(try ElementSelector(argument), visible: name == "assertVisible")
            case "inputText":
                guard let text = argument as? String, !text.isEmpty else { throw Failure("Invalid inputText") }
                command = .inputText(text)
            case "extendedWaitUntil":
                let fields = try options(["visible", "notVisible", "timeout"])
                let target = fields["visible"] ?? fields["notVisible"]
                guard let target, (fields["visible"] == nil) != (fields["notVisible"] == nil) else {
                    throw Failure("extendedWaitUntil needs visible or notVisible")
                }
                guard let timeout = fields["timeout"] as? Int, (1...300_000).contains(timeout) else {
                    throw Failure("extendedWaitUntil needs a timeout of 1…300000 ms")
                }
                command = .extendedWaitUntil(
                    try ElementSelector(target), visible: fields["visible"] != nil, timeout: Double(timeout) / 1_000)
            case "takeScreenshot":
                let path = try (argument as? String) ?? (options(["path"])["path"] as? String)
                guard let path, path.range(of: "^[A-Za-z0-9._-]{1,100}$", options: .regularExpression) != nil,
                    !path.hasPrefix(".")
                else { throw Failure("Invalid screenshot name") }
                command = .takeScreenshot(path)
            case "pressKey":
                guard let keyName = argument as? String, let key = Key(rawValue: keyName.lowercased()) else {
                    throw Failure("Unsupported key \(argument) on macOS")
                }
                command = .pressKey(key)
            case "scroll":
                guard argument as? Bool == true else { throw Failure("scroll takes no options on macOS") }
                command = .scroll
            default:
                throw Failure("Unsupported Maestro command \(name) on macOS")
            }
            return Step(name: name, line: line, command: command)
        }

        private static func perform(
            _ command: Command, store: DieterStore, window: inout NSWindow?, output: URL
        ) async throws {
            if case .launchApp = command {
                window = try await launch(store: store)
                return
            }
            guard let window else { throw Failure("launchApp must precede UI commands") }
            switch command {
            case .launchApp:
                return
            case .tapOn(let selector):
                try await tap(selector, in: window)
            case .assertVisible(let selector, let visible):
                try await waitFor(selector, visible: visible, timeout: elementTimeout, in: window)
            case .extendedWaitUntil(let selector, let visible, let timeout):
                try await waitFor(selector, visible: visible, timeout: timeout, in: window)
            case .inputText(let text):
                // A preceding tap's posted click focuses the field asynchronously.
                var input: NSTextInputClient?
                let focused = try await NativeUIAccessibility.wait(timeout: elementTimeout) {
                    input = (NSApp.keyWindow ?? window).firstResponder as? NSTextInputClient
                    return input != nil
                }
                guard focused, let input else { throw Failure("No focused text input") }
                input.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
            case .takeScreenshot(let name):
                // A posted mouse/key event must be consumed before a screenshot
                // can represent the step that just finished.
                guard
                    try await NativeUIAccessibility.wait(
                        timeout: elementTimeout,
                        until: {
                            NSApp.nextEvent(
                                matching: [.leftMouseDown, .leftMouseUp, .keyDown, .keyUp],
                                until: .distantPast, inMode: .default, dequeue: false) == nil
                        })
                else { throw Failure("Input events did not drain before capture") }
                await withCheckedContinuation { continuation in
                    DispatchQueue.main.async { continuation.resume() }
                }
                window.displayIfNeeded()
                try capture(window, name: name, output: output)
            case .scroll:
                // A real wheel event follows the nested reader's responder
                // chain into the outer page scroller, just like a trackpad.
                guard let content = window.contentView,
                    let wheel = CGEvent(
                        scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                        wheel1: -600, wheel2: 0, wheel3: 0),
                    let event = NSEvent(cgEvent: wheel)
                else { throw Failure("Native scroll event unavailable") }
                let point = NSPoint(x: content.bounds.midX, y: content.bounds.midY)
                content.hitTest(point)?.scrollWheel(with: event)
            case .pressKey(let key):
                let target = NSApp.keyWindow ?? window
                for type in [NSEvent.EventType.keyDown, .keyUp] {
                    guard
                        let event = NSEvent.keyEvent(
                            with: type, location: .zero, modifierFlags: [],
                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: target.windowNumber,
                            context: nil, characters: key.event.characters,
                            charactersIgnoringModifiers: key.event.characters, isARepeat: false,
                            keyCode: key.event.code)
                    else { throw Failure("Native key event unavailable") }
                    NSApp.postEvent(event, atStart: false)
                }
            }
        }

        /// The fixture connection is live and the workspace window is key.
        private static func launch(store: DieterStore) async throws -> NSWindow {
            // The fixture's machine approves the launch's pairing code before
            // any machine is reachable.
            guard try await NativeUIAccessibility.wait(timeout: 60, until: { store.workspaceIsLive }) else {
                throw Failure("Fixture connection did not become live (device trust \(store.session.deviceTrust))")
            }
            var window: NSWindow?
            guard
                try await NativeUIAccessibility.wait(
                    timeout: 10,
                    until: {
                        window = workspaceWindow()
                        return window != nil
                    }), let window
            else { throw Failure("Workspace window unavailable") }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return window
        }

        private static func workspaceWindow() -> NSWindow? {
            NSApp.windows.first { $0.title == "Dieter" && $0.isVisible && $0.frame.width >= 600 }
        }

        private static func waitFor(
            _ selector: ElementSelector, visible: Bool, timeout: TimeInterval, in window: NSWindow
        )
            async throws
        {
            let satisfied = try await NativeUIAccessibility.wait(timeout: timeout) {
                (selector.resolve(in: window) != nil) == visible
            }
            guard satisfied else { throw Failure("\(visible ? "No visible" : "Still visible"): \(selector)") }
        }

        /// Waits for the element's frame to settle, then presses it through
        /// accessibility. Text inputs and elements without a press action get
        /// a native click at their center.
        private static func tap(_ selector: ElementSelector, in window: NSWindow) async throws {
            var previous: CGRect?
            var stable = 0
            var target: NativeUIAccessibility.Element?
            let settled = try await NativeUIAccessibility.wait(timeout: elementTimeout) {
                guard let element = selector.resolve(in: window) else {
                    stable = 0
                    return false
                }
                let frame = element.frame
                stable = frame == previous ? stable + 1 : 0
                previous = frame
                target = element
                return stable >= 2
            }
            guard settled, let element = target else { throw Failure("No visible element: \(selector)") }
            let textInput = [NSAccessibility.Role.textField, .textArea, .comboBox].contains(element.role)
            // Anchors never handle events; click the control they cover.
            if !textInput, element.anchor == nil, let accessible = element.object as? NSAccessibilityProtocol,
                accessible.accessibilityPerformPress()
            {
                return
            }
            try click(element)
        }

        private static func click(_ element: NativeUIAccessibility.Element) throws {
            let host = element.window
            // A tall reader may extend well beyond the window. Click its
            // visible portion so subsequent key events reach the reader.
            let frame = element.frame.intersection(host.frame)
            guard !frame.isNull, !frame.isEmpty else { throw Failure("Element is outside its window") }
            let point = host.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard
                    let event = NSEvent.mouseEvent(
                        with: type, location: point, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: host.windowNumber,
                        context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
                else { throw Failure("Native mouse event unavailable") }
                NSApp.postEvent(event, atStart: false)
            }
        }

        private static func event(_ index: Int, _ step: Step, _ status: String, _ start: Date, _ output: URL) throws {
            let row: [String: Any] = [
                "step": index, "line": step.line, "action": step.name, "status": status,
                "elapsedMs": Int(Date().timeIntervalSince(start) * 1_000),
            ]
            let path = output.appending(path: "events.jsonl")
            if !FileManager.default.fileExists(atPath: path.path) {
                FileManager.default.createFile(atPath: path.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: path)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(
                contentsOf: JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) + Data([10]))
        }

        /// `NAME.png` and its accessibility hierarchy as `NAME.txt`.
        private static func capture(_ window: NSWindow, name: String, output: URL) throws {
            try NativeTestSupport.capture(window, to: output.appending(path: name + ".png"))
            let hierarchy = NativeUIAccessibility.windows(from: window).flatMap {
                NativeUIAccessibility.elements(in: $0)
            }
            .map { element in
                let frame = element.frame
                let geometry =
                    element.isVisible
                    ? "\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))" : "hidden"
                let text = element.texts.joined(separator: " | ").replacingOccurrences(of: "\n", with: "⏎")
                return "\(element.identifier ?? "-") [\(element.role?.rawValue ?? "-")] \(geometry) \(text.prefix(200))"
            }
            try hierarchy.joined(separator: "\n").write(
                to: output.appending(path: name + ".txt"), atomically: true, encoding: .utf8)
        }
    }
#endif
