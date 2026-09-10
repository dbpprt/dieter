import AppKit
import SwiftUI

extension View {
    /// Keeps accessible SwiftUI help while registering hover help with AppKit,
    /// including for controls that SwiftUI currently disables.
    func nativeHelp(_ text: String) -> some View {
        help(text)
            .background {
                GeometryReader { geometry in
                    NativeHelp(text: text)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
                .accessibilityHidden(true)
            }
    }
}

struct NativeHelp: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NativeHelpView { NativeHelpView() }

    func updateNSView(_ view: NativeHelpView, context: Context) {
        if view.toolTip != text { view.toolTip = text }
    }

    static func dismantleNSView(_ view: NativeHelpView, coordinator: ()) {
        view.toolTip = nil
    }
}

final class NativeHelpView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setAccessibilityElement(false)
    }

    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
