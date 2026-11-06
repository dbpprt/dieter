import SwiftUI

#if DIETER_E2E
    /// Live geometry for Maestro selectors. SwiftUI does not publish its
    /// accessibility tree in-process, so views register a zero-hit anchor
    /// with their identifier and, where a flow selects by text, that text.
    @MainActor enum E2ETargets {
        final class Entry {
            weak var view: NSView?
            let identifier: String
            let text: String?
            init(view: NSView, identifier: String, text: String?) {
                self.view = view
                self.identifier = identifier
                self.text = text
            }
        }

        private static var entries: [ObjectIdentifier: Entry] = [:]

        static func register(_ view: NSView, identifier: String, text: String?) {
            // SwiftUI can reuse a representable when a native list recycles its
            // row, so the latest identifier replaces the previous one.
            entries[ObjectIdentifier(view)] = Entry(view: view, identifier: identifier, text: text)
        }

        static func unregister(_ view: NSView) {
            entries[ObjectIdentifier(view)] = nil
        }

        /// Anchors shown in `window`: retained split panes and measurement
        /// hosts keep hidden copies, which never match.
        static func visible(in window: NSWindow) -> [Entry] {
            entries = entries.filter { $0.value.view != nil }
            return entries.values.filter {
                guard let view = $0.view else { return false }
                return view.window === window && !view.isHiddenOrHasHiddenAncestor && !view.visibleRect.isEmpty
            }
        }
    }

    private struct E2ETarget: NSViewRepresentable {
        let identifier: String
        let text: String?

        final class Anchor: NSView {
            override func hitTest(_ point: NSPoint) -> NSView? { nil }
        }

        func makeNSView(context: Context) -> Anchor {
            let view = Anchor()
            E2ETargets.register(view, identifier: identifier, text: text)
            return view
        }

        func updateNSView(_ view: Anchor, context: Context) {
            E2ETargets.register(view, identifier: identifier, text: text)
        }

        static func dismantleNSView(_ view: Anchor, coordinator: ()) {
            E2ETargets.unregister(view)
        }
    }
#endif

extension View {
    /// Geometry only, never an action hook: debug E2E flows select this view by
    /// its identifier (and optional text) and send native events to its frame.
    /// Release builds compile it away without evaluating `text`.
    @ViewBuilder func e2eTarget(_ identifier: String, text: @autoclosure () -> String? = nil) -> some View {
        #if DIETER_E2E
            if NativeTestSupport.isE2E { background(E2ETarget(identifier: identifier, text: text())) } else { self }
        #else
            self
        #endif
    }
}
