#if DIETER_UI_SMOKE
    import AppKit
    import Foundation

    /// Interprets the shared runner's bounded plan using native accessibility
    /// and mouse/key events. Fixture setup stays in the host runner.
    @MainActor enum NativeUIFlowRunner {
        private struct Failure: Error, CustomStringConvertible {
            let description: String
            init(_ description: String) { self.description = description }
        }

        static func run(store: DieterStore) async {
            let output = NativeTestSupport.outputDirectory()
            var results: [String: String] = [:]
            var window: NSWindow?
            do {
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                guard let path = NativeTestSupport.argument("--e2e-plan") else { throw Failure("Missing plan") }
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                guard data.count <= 256 * 1024,
                    let plan = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                    plan["version"] as? Int == 1,
                    let test = plan["case"] as? [String: Any], test["platform"] as? String == "mac",
                    let steps = test["steps"] as? [[String: Any]], (1...100).contains(steps.count)
                else { throw Failure("Invalid versioned Mac flow plan") }
                for (index, step) in steps.enumerated() {
                    let start = Date()
                    let actions = step.keys.filter { $0 != "line" }
                    guard actions.count == 1, let action = actions.first else { throw Failure("Invalid step") }
                    try event(index, step, action, "started", start, output)
                    do {
                        if action == "launch" {
                            guard step[action] as? String == "connected",
                                await NativeUIAccessibility.wait(timeout: 30, until: { store.workspaceIsLive })
                            else { throw Failure("Fixture connection did not become live") }
                            let ready = await NativeUIAccessibility.wait {
                                window = NSApp.windows.first {
                                    $0.title == "Dieter" && $0.isVisible && $0.frame.width >= 600
                                }
                                return window != nil
                            }
                            guard ready, let window else { throw Failure("Workspace window unavailable") }
                            NSApp.activate(ignoringOtherApps: true)
                            window.makeKeyAndOrderFront(nil)
                        } else {
                            guard let window else { throw Failure("Launch must precede UI actions") }
                            try await perform(action, step, window, output)
                        }
                        results["step-\(index)"] = "passed"
                        try event(index, step, action, "passed", start, output)
                    } catch {
                        results["step-\(index)"] = "failed: \(test["source"] ?? "plan"):\(step["line"] ?? 0): \(error)"
                        try? event(index, step, action, "failed", start, output)
                        throw error
                    }
                }
                if let window { try capture(window, name: "final", output: output) }
            } catch {
                results["flow"] = "failed: \(error)"
                if let window { try? capture(window, name: "failure", output: output) }
            }
            NativeTestSupport.writeReport(results, to: output)
        }

        private static func perform(_ action: String, _ step: [String: Any], _ window: NSWindow, _ output: URL)
            async throws
        {
            if action == "screenshot" {
                guard let name = step[action] as? String else { throw Failure("Missing screenshot name") }
                try capture(window, name: name, output: output)
                return
            }
            guard let target = step[action] as? [String: Any] else { throw Failure("Missing target for \(action)") }
            if action == "expect" {
                var selectorError: Error?
                let passed = await NativeUIAccessibility.wait(timeout: 15) {
                    let resolved: NativeUIAccessibility.Element?
                    do { resolved = try resolve(target, window) } catch { selectorError = error; return true }
                    guard let element = resolved else { return target["visible"] as? Bool == false }
                    if target["visible"] as? Bool == false { return false }
                    if target["visible"] as? Bool == true && !visible(element, window) { return false }
                    if let expected = target["enabled"] as? Bool,
                        property(element, "isAccessibilityEnabled", window) as? Bool != expected
                    {
                        return false
                    }
                    if let expected = target["selected"] as? Bool,
                        property(element, "isAccessibilitySelected", window) as? Bool != expected
                    {
                        return false
                    }
                    if let expected = target["value"] as? String,
                        property(element, "accessibilityValue", window) as? String != expected
                    {
                        return false
                    }
                    return true
                }
                if let selectorError { throw selectorError }
                guard passed else { throw Failure("Expectation not satisfied: \(target)") }
                return
            }
            guard action == "tap" else { throw Failure("Unsupported action \(action)") }
            var previous: CGRect?
            var stable = 0
            let ready = await NativeUIAccessibility.wait(timeout: 15) {
                guard let element = try? resolve(target, window), visible(element, window) else {
                    stable = 0; return false
                }
                let frame = element.recordedFrame ?? element.frame
                stable = frame == previous ? stable + 1 : 0
                previous = frame
                return stable >= 3
            }
            guard ready, let element = try resolve(target, window), let frame = previous else {
                throw Failure("Target did not settle: \(target)")
            }
            if let accessible = element.object as? NSAccessibilityProtocol, accessible.accessibilityPerformPress() {
                // Native accessibility dispatched exactly one action.
            } else {
                let point = window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    guard
                        let event = NSEvent.mouseEvent(
                            with: type, location: point, modifierFlags: [],
                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                            context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
                    else { throw Failure("Native mouse event unavailable") }
                    NSApp.postEvent(event, atStart: false)
                }
            }
        }

        private static func resolve(_ target: [String: Any], _ window: NSWindow) throws -> NativeUIAccessibility
            .Element?
        {
            if let id = target["id"] as? String { return NativeUIAccessibility.find(id, in: window) }
            let text = target["text"] as? String ?? target["description"] as? String
            guard let text else { throw Failure("Invalid selector") }
            let matches = NativeUIAccessibility.elements(in: window).filter { element in
                ["accessibilityValue", "accessibilityTitle", "accessibilityLabel"].contains {
                    element.value($0) as? String == text
                }
                    && element.frame.width > 0 && element.frame.height > 0
            }
            guard matches.count <= 1 else { throw Failure("Ambiguous selector: \(text)") }
            return matches.first
        }
        private static func property(_ element: NativeUIAccessibility.Element, _ name: String, _ window: NSWindow)
            -> Any?
        {
            if let value = element.value(name) { return value }
            guard let id = element.identifier else { return nil }
            return NativeUIAccessibility.elements(in: window).first { $0.identifier == id && $0.value(name) != nil }?
                .value(name)
        }
        private static func visible(_ element: NativeUIAccessibility.Element, _ window: NSWindow) -> Bool {
            let frame = element.recordedFrame ?? element.frame
            return window.isVisible && frame.width > 0 && frame.height > 0 && window.frame.intersects(frame)
        }
        private static func event(
            _ index: Int, _ step: [String: Any], _ action: String, _ status: String, _ start: Date, _ output: URL
        ) throws {
            let row: [String: Any] = [
                "step": index, "line": step["line"] ?? 0, "action": action, "status": status,
                "elapsedMs": Int(Date().timeIntervalSince(start) * 1000),
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
        private static func capture(_ window: NSWindow, name: String, output: URL) throws {
            NativeUISmokeRunner.capture(window, to: output.appending(path: name + ".png"))
            guard NSImage(contentsOf: output.appending(path: name + ".png")) != nil else {
                throw Failure("Screenshot unavailable")
            }
            let hierarchy = NativeUIAccessibility.elements(in: window).map {
                "\($0.identifier ?? "-") \($0.text.prefix(200))"
            }.joined(separator: "\n")
            try hierarchy.write(to: output.appending(path: name + ".txt"), atomically: true, encoding: .utf8)
        }
    }
#endif
