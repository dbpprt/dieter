import SwiftUI

#if DIETER_UI_SMOKE
    @MainActor enum NativeUISmokeTargets {
        final class Entry {
            weak var view: NSView?
            init(view: NSView) { self.view = view }
        }
        static var frames: [String: [Entry]] = [:]
        static var diffText = ""
        static var diffSplit: Bool?
        static let enabled = ProcessInfo.processInfo.arguments.contains { $0.hasSuffix("-ui-smoke") }
        static func register(_ view: NSView, identifier: String) {
            // SwiftUI can reuse a representable when a native list recycles its
            // row. Remove its previous identifier before registering the new one.
            unregister(view)
            frames[identifier, default: []].append(.init(view: view))
        }
        static func unregister(_ view: NSView) {
            frames = frames.compactMapValues { entries in
                let remaining = entries.filter { $0.view != nil && $0.view !== view }
                return remaining.isEmpty ? nil : remaining
            }
        }
    }

    private struct NativeUISmokeTarget: NSViewRepresentable {
        let identifier: String
        final class Anchor: NSView {
            override func hitTest(_ point: NSPoint) -> NSView? { nil }
        }
        func makeNSView(context: Context) -> Anchor {
            let view = Anchor()
            NativeUISmokeTargets.register(view, identifier: identifier)
            return view
        }
        func updateNSView(_ view: Anchor, context: Context) {
            NativeUISmokeTargets.register(view, identifier: identifier)
        }
        static func dismantleNSView(_ view: Anchor, coordinator: ()) {
            NativeUISmokeTargets.unregister(view)
        }
    }
#endif

extension View {
    /// Geometry only, never an action hook. The isolated driver sends native
    /// mouse events to these live frames when system accessibility is inactive.
    @ViewBuilder func smokeTarget(_ identifier: String) -> some View {
        #if DIETER_UI_SMOKE
            if NativeUISmokeTargets.enabled { background(NativeUISmokeTarget(identifier: identifier)) } else { self }
        #else
            self
        #endif
    }
}
