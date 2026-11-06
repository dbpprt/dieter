import AppKit
import SwiftUI

/// Window actions sit inside the floating sidebar card (or the collapsed
/// window capsule) because every section hides the toolbar to let its glass top
/// bar occupy the title band. SwiftUI removes the standard window-button views
/// with that toolbar, so these controls own their views and mirror the system
/// behaviour: hover glyphs, the inactive-window grey, and Option-click zoom.
struct DieterWindowTrafficLights: NSViewRepresentable {
    func makeNSView(context: Context) -> DieterWindowTrafficLightsView {
        DieterWindowTrafficLightsView()
    }

    func updateNSView(_ view: DieterWindowTrafficLightsView, context: Context) {}
}

@MainActor
final class DieterWindowTrafficLightsView: NSView {
    private var buttons: [DieterTrafficLightButton] = []
    private var hovering = false {
        didSet { if hovering != oldValue { buttons.forEach { $0.showsGlyph = hovering } } }
    }
    private var observers: [NSObjectProtocol] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityIdentifier("workspace.traffic-lights")
        addButton(
            at: 12, kind: .close, color: NSColor(srgbRed: 1, green: 0.38, blue: 0.35, alpha: 1),
            label: "Close window", action: #selector(closeWindow))
        addButton(
            at: 32, kind: .minimize, color: NSColor(srgbRed: 1, green: 0.74, blue: 0.27, alpha: 1),
            label: "Minimize window", action: #selector(minimizeWindow))
        addButton(
            at: 52, kind: .zoom, color: NSColor(srgbRed: 0.31, green: 0.79, blue: 0.36, alpha: 1),
            label: "Enter full screen", action: #selector(toggleFullScreen))
    }

    required init?(coder: NSCoder) { nil }

    private func addButton(
        at x: CGFloat, kind: DieterTrafficLightButton.Kind, color: NSColor, label: String, action: Selector
    ) {
        let button = DieterTrafficLightButton(frame: NSRect(x: x, y: 11, width: 14, height: 14))
        button.kind = kind
        button.color = color
        button.title = ""
        button.isBordered = false
        button.target = self
        button.action = action
        button.setAccessibilityLabel(label)
        addSubview(button)
        buttons.append(button)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard let window else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            observers.append(
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) {
                    [weak self] _ in
                    MainActor.assumeIsolated { self?.updateActiveState() }
                })
        }
        updateActiveState()
    }

    private func updateActiveState() {
        let active = window?.isKeyWindow ?? true
        buttons.forEach { $0.windowActive = active }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        guard let first = buttons.first, let last = buttons.last else { return }
        addTrackingArea(
            NSTrackingArea(
                rect: first.frame.union(last.frame).insetBy(dx: -2, dy: -2),
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    @objc private func closeWindow() { window?.performClose(nil) }
    @objc private func minimizeWindow() { window?.miniaturize(nil) }
    @objc private func toggleFullScreen() {
        if NSEvent.modifierFlags.contains(.option) {
            window?.zoom(nil)
        } else {
            window?.toggleFullScreen(nil)
        }
    }
}

@MainActor
private final class DieterTrafficLightButton: NSButton {
    enum Kind {
        case close
        case minimize
        case zoom
    }

    var kind = Kind.close
    var color = NSColor.clear
    var windowActive = true { didSet { needsDisplay = true } }
    var showsGlyph = false { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5))
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let lit = windowActive || showsGlyph
        (lit ? color : NSColor(white: dark ? 0.36 : 0.82, alpha: 1)).setFill()
        circle.fill()
        NSColor.black.withAlphaComponent(lit ? 0.22 : 0.12).setStroke()
        circle.lineWidth = 0.75
        circle.stroke()
        guard showsGlyph else { return }
        NSColor.black.withAlphaComponent(0.55).set()
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        switch kind {
        case .close:
            let glyph = NSBezierPath()
            glyph.lineWidth = 1.2
            glyph.lineCapStyle = .round
            glyph.move(to: NSPoint(x: center.x - 3, y: center.y - 3))
            glyph.line(to: NSPoint(x: center.x + 3, y: center.y + 3))
            glyph.move(to: NSPoint(x: center.x - 3, y: center.y + 3))
            glyph.line(to: NSPoint(x: center.x + 3, y: center.y - 3))
            glyph.stroke()
        case .minimize:
            let glyph = NSBezierPath()
            glyph.lineWidth = 1.3
            glyph.lineCapStyle = .round
            glyph.move(to: NSPoint(x: center.x - 3.5, y: center.y))
            glyph.line(to: NSPoint(x: center.x + 3.5, y: center.y))
            glyph.stroke()
        case .zoom:
            let upper = NSBezierPath()
            upper.move(to: NSPoint(x: center.x - 3.2, y: center.y + 3.2))
            upper.line(to: NSPoint(x: center.x + 1.6, y: center.y + 3.2))
            upper.line(to: NSPoint(x: center.x - 3.2, y: center.y - 1.6))
            upper.close()
            upper.fill()
            let lower = NSBezierPath()
            lower.move(to: NSPoint(x: center.x + 3.2, y: center.y - 3.2))
            lower.line(to: NSPoint(x: center.x - 1.6, y: center.y - 3.2))
            lower.line(to: NSPoint(x: center.x + 3.2, y: center.y + 1.6))
            lower.close()
            lower.fill()
        }
    }
}
