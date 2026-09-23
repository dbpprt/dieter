import AppKit
import SwiftUI

/// Window actions remain in the sidebar when SwiftUI hides the toolbar to let
/// pane headers occupy the top edge. SwiftUI removes the standard window-button
/// views with that toolbar, so these controls must own their own views.
struct DieterWindowTrafficLights: NSViewRepresentable {
    func makeNSView(context: Context) -> DieterWindowTrafficLightsView {
        DieterWindowTrafficLightsView()
    }

    func updateNSView(_ view: DieterWindowTrafficLightsView, context: Context) {}
}

@MainActor
final class DieterWindowTrafficLightsView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityIdentifier("workspace.traffic-lights")
        addButton(
            at: 14, color: NSColor(srgbRed: 1, green: 0.38, blue: 0.35, alpha: 1),
            label: "Close window", action: #selector(closeWindow))
        addButton(
            at: 34, color: NSColor(srgbRed: 1, green: 0.74, blue: 0.27, alpha: 1),
            label: "Minimize window", action: #selector(minimizeWindow))
        addButton(
            at: 54, color: NSColor(srgbRed: 0.31, green: 0.79, blue: 0.36, alpha: 1),
            label: "Enter full screen", action: #selector(toggleFullScreen))
    }

    required init?(coder: NSCoder) { nil }

    private func addButton(at x: CGFloat, color: NSColor, label: String, action: Selector) {
        let button = DieterTrafficLightButton(frame: NSRect(x: x, y: 11, width: 14, height: 14))
        button.color = color
        button.title = ""
        button.isBordered = false
        button.target = self
        button.action = action
        button.setAccessibilityLabel(label)
        addSubview(button)
    }

    @objc private func closeWindow() { window?.performClose(nil) }
    @objc private func minimizeWindow() { window?.miniaturize(nil) }
    @objc private func toggleFullScreen() { window?.toggleFullScreen(nil) }
}

@MainActor
private final class DieterTrafficLightButton: NSButton {
    var color = NSColor.clear

    override func draw(_ dirtyRect: NSRect) {
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5))
        color.setFill()
        circle.fill()
        NSColor.black.withAlphaComponent(0.22).setStroke()
        circle.lineWidth = 0.75
        circle.stroke()
    }
}
