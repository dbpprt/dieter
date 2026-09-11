import AppKit
import SwiftUI

extension View {
    /// Immediate hover labels; an optional width wraps longer details. Accessibility stays on the actual control;
    /// no system tooltip is registered, so a delayed second tooltip cannot appear.
    func quickHelp(_ title: String, maximumWidth: CGFloat? = nil) -> some View {
        background {
            GeometryReader { geometry in
                QuickHelp(title: title, maximumWidth: maximumWidth)
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }
            .accessibilityHidden(true)
        }
    }
}

struct QuickHelp: NSViewRepresentable {
    let title: String
    var maximumWidth: CGFloat?

    func makeNSView(context: Context) -> QuickHelpView { QuickHelpView() }

    func updateNSView(_ view: QuickHelpView, context: Context) {
        view.title = title
        view.maximumWidth = maximumWidth
    }

    static func dismantleNSView(_ view: QuickHelpView, coordinator: ()) {
        view.dismissHelp()
    }
}

final class QuickHelpView: NSView {
    var title = "" {
        didSet { if title != oldValue { dismissHelp() } }
    }
    var maximumWidth: CGFloat? {
        didSet { if maximumWidth != oldValue { dismissHelp() } }
    }
    private(set) var helpWindow: NSPanel?
    private var hoverArea: NSTrackingArea?
    private var dismissalMonitor: Any?
    private static weak var activeOwner: QuickHelpView?

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

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let activation: NSTrackingArea.Options =
            window?.styleMask.contains(.nonactivatingPanel) == true ? .activeAlways : .activeInKeyWindow
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, activation, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
        positionHelp()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        dismissHelp()
        NotificationCenter.default.removeObserver(self)
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTrackingAreas()
        guard let window else { return }
        for name in [
            NSWindow.didResignKeyNotification, NSWindow.willCloseNotification, NSWindow.willMiniaturizeNotification,
        ] {
            NotificationCenter.default.addObserver(self, selector: #selector(dismissHelp), name: name, object: window)
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(dismissHelp), name: NSApplication.didResignActiveNotification, object: NSApp)
    }

    override func mouseEntered(with event: NSEvent) {
        guard let window, window.isVisible, !isHiddenOrHasHiddenAncestor, !title.isEmpty else { return }
        Self.activeOwner?.dismissHelp()
        Self.activeOwner = self

        let nonactivatingHost = window.styleMask.contains(.nonactivatingPanel)
        let content = NSHostingController(rootView: QuickHelpBubble(title: title, maximumWidth: maximumWidth))
        content.sizingOptions = []
        let panel = QuickHelpPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.setAccessibilityElement(false)
        panel.hidesOnDeactivate = !nonactivatingHost
        panel.animationBehavior = .none
        panel.level = .popUpMenu
        panel.appearance = window.effectiveAppearance
        panel.contentViewController = content
        // An unconstrained NSHostingView.fittingSize can report one line even
        // when the bubble's maximum width clips it. Measure with that width as
        // a proposal so SwiftUI accounts for every wrapped line before showing.
        panel.setContentSize(
            content.sizeThatFits(
                in: NSSize(width: maximumWidth ?? .greatestFiniteMagnitude, height: .greatestFiniteMagnitude)))
        helpWindow = panel
        positionHelp()
        window.addChildWindow(panel, ordered: .above)
        if nonactivatingHost {
            panel.orderFrontRegardless()
        } else {
            panel.orderFront(nil)
        }

        // Do not leave a label above an opened menu or interfere with its events.
        dismissalMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .scrollWheel]
        ) { [weak self] event in
            MainActor.assumeIsolated { self?.dismissHelp() }
            return event
        }
    }

    override func mouseExited(with event: NSEvent) { dismissHelp() }

    @objc func dismissHelp() {
        if let dismissalMonitor { NSEvent.removeMonitor(dismissalMonitor) }
        dismissalMonitor = nil
        if let panel = helpWindow {
            panel.parent?.removeChildWindow(panel)
            panel.close()
        }
        helpWindow = nil
        if Self.activeOwner === self { Self.activeOwner = nil }
    }

    private func positionHelp() {
        guard let window, let panel = helpWindow else { return }
        let anchor = window.convertToScreen(convert(bounds, to: nil))
        let screen = window.screen?.visibleFrame ?? anchor.insetBy(dx: -200, dy: -200)
        let size = panel.frame.size
        let x = min(max(anchor.midX - size.width / 2, screen.minX + 4), screen.maxX - size.width - 4)
        let above = anchor.maxY + 2
        let y = above + size.height <= screen.maxY ? above : anchor.minY - size.height - 2
        panel.setFrameOrigin(NSPoint(x: x, y: max(screen.minY + 4, y)))
    }
}

private final class QuickHelpPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct QuickHelpBubble: View {
    let title: String
    let maximumWidth: CGFloat?

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.primary)
            .fixedSize(horizontal: maximumWidth == nil, vertical: true)
            .frame(maxWidth: maximumWidth.map { max(1, $0 - 28) }, alignment: .leading)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 7))
            .fixedSize(horizontal: maximumWidth == nil, vertical: true)
            .padding(5)
            .accessibilityHidden(true)
    }
}
