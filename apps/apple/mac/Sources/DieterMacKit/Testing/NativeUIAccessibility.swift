#if DIETER_E2E
    import AppKit

    /// Registered E2E anchors first, then the app's own accessibility
    /// hierarchy, read in-process: no accessibility client sees inside SwiftUI
    /// hosting views, and in-process they publish only some containers.
    @MainActor enum NativeUIAccessibility {
        struct Element {
            let object: NSObject
            /// The window that hosts the element.
            let window: NSWindow
            /// A registered `e2eTarget` anchor's identifier and text.
            var anchor: (identifier: String, text: String?)? = nil

            func value(_ key: String) -> Any? {
                guard object.responds(to: NSSelectorFromString(key)) else { return nil }
                return object.value(forKey: key)
            }
            func string(_ key: String) -> String? {
                switch value(key) {
                case let text as String: text
                case let text as NSAttributedString: text.string
                default: nil
                }
            }
            var identifier: String? { anchor?.identifier ?? string("accessibilityIdentifier") }
            /// Maestro's text: the anchor's text, or the element's value, title,
            /// label or placeholder.
            var texts: [String] {
                if let anchor { return anchor.text.map { [$0] } ?? [] }
                return [
                    "accessibilityValue", "accessibilityTitle", "accessibilityLabel", "accessibilityPlaceholderValue",
                ]
                .compactMap { string($0) }.filter { !$0.isEmpty }
            }
            var role: NSAccessibility.Role? {
                anchor == nil ? string("accessibilityRole").map(NSAccessibility.Role.init(rawValue:)) : nil
            }
            /// Screen coordinates.
            var frame: NSRect {
                if anchor != nil, let view = object as? NSView {
                    return window.convertToScreen(view.convert(view.bounds, to: nil))
                }
                return (value("accessibilityFrame") as? NSValue)?.rectValue ?? .zero
            }
            var isVisible: Bool {
                let frame = frame
                return window.isVisible && frame.width > 0 && frame.height > 0 && window.frame.intersects(frame)
            }
        }

        /// The workspace window first, then its sheets, child windows and popovers.
        static func windows(from window: NSWindow) -> [NSWindow] {
            var result = [window]
            var index = 0
            while index < result.count {
                let current = result[index]
                index += 1
                let related = current.sheets + (current.childWindows ?? [])
                for candidate in related where candidate.isVisible && !result.contains(candidate) {
                    result.append(candidate)
                }
            }
            for candidate in NSApp.windows
            where candidate.isVisible && !result.contains(candidate)
                && (candidate.isSheet || String(describing: type(of: candidate)).contains("Popover"))
            {
                result.append(candidate)
            }
            return result
        }

        /// Registered anchors, then every accessibility element in document
        /// order, i.e. a parent before its children.
        static func elements(in window: NSWindow, limit: Int = 20_000) -> [Element] {
            anchors(in: window) + accessibility(in: window, limit: limit)
        }

        static func anchors(in window: NSWindow) -> [Element] {
            E2ETargets.visible(in: window).compactMap { entry in
                entry.view.map { Element(object: $0, window: window, anchor: (entry.identifier, entry.text)) }
            }
        }

        private static func accessibility(in window: NSWindow, limit: Int) -> [Element] {
            var pending: [Any] = [window]
            var result: [Element] = []
            var visited: Set<ObjectIdentifier> = []
            while let next = pending.popLast(), result.count < limit {
                guard let object = next as? NSObject, visited.insert(ObjectIdentifier(object)).inserted else {
                    continue
                }
                let element = Element(object: object, window: window)
                result.append(element)
                let children = element.value("accessibilityChildren") as? [Any] ?? []
                pending.append(contentsOf: children.reversed())
            }
            return result
        }

        static func wait(timeout: TimeInterval, until condition: () throws -> Bool) async throws -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if try condition() { return true }
                try await DieterTaskSleep.milliseconds(50)
            }
            return try condition()
        }
    }
#endif
