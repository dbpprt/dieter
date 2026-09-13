import AppKit
import Observation
import SwiftUI

enum DieterTransparency {
    static let storageKey = "DieterWindowTransparency"
    static let defaultEnabled = true

    static func load(from defaults: UserDefaults = DieterAppearance.applicationDefaults()) -> Bool {
        defaults.object(forKey: storageKey) as? Bool ?? defaultEnabled
    }
}

/// Observe the system independently of the app's transparency preference. Turning
/// off transparency in Dieter must never change the macOS accessibility setting.
@MainActor
@Observable
final class DieterTransparencyAccessibility {
    static let shared = DieterTransparencyAccessibility()
    private(set) var reduceTransparency: Bool
    @ObservationIgnored private var observer: NSObjectProtocol?

    private init() {
        reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
                guard reduced != self.reduceTransparency else { return }
                self.reduceTransparency = reduced
                DieterTheme.transparencyAccessibilityDidChange()
            }
        }
    }
}

struct DieterWindowBackdrop: NSViewRepresentable {
    let transparencyEnabled: Bool
    let solidColor: NSColor

    func makeNSView(context: Context) -> DieterWindowBackdropView {
        let view = DieterWindowBackdropView()
        view.configure(transparencyEnabled: transparencyEnabled, solidColor: solidColor)
        return view
    }

    func updateNSView(_ view: DieterWindowBackdropView, context: Context) {
        view.configure(transparencyEnabled: transparencyEnabled, solidColor: solidColor)
    }

    static func dismantleNSView(_ view: DieterWindowBackdropView, coordinator: ()) {
        view.restoreWindow()
    }
}

/// One compositor-owned blur beneath the entire workspace. Never fade the
/// window itself: text, native controls, and content retain their full opacity.
@MainActor
final class DieterWindowBackdropView: NSVisualEffectView {
    private var transparencyEnabled = false
    private var solidColor = NSColor.windowBackgroundColor
    private weak var configuredWindow: NSWindow?
    private var originalWindowStyle: (opaque: Bool, background: NSColor?, transparentTitlebar: Bool)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .underWindowBackground
        blendingMode = .behindWindow
        state = .followsWindowActiveState
        setAccessibilityIdentifier("workspace.window-backdrop")
    }

    required init?(coder: NSCoder) { nil }

    func configure(transparencyEnabled: Bool, solidColor: NSColor) {
        self.transparencyEnabled = transparencyEnabled
        self.solidColor = solidColor
        isHidden = !transparencyEnabled
        applyWindowStyle()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if configuredWindow !== window {
            restoreWindow()
            if let window {
                configuredWindow = window
                originalWindowStyle = (window.isOpaque, window.backgroundColor, window.titlebarAppearsTransparent)
            }
        }
        applyWindowStyle()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func applyWindowStyle() {
        guard let window = configuredWindow else { return }
        window.isOpaque = !transparencyEnabled
        window.backgroundColor = transparencyEnabled ? .clear : solidColor
        window.titlebarAppearsTransparent = transparencyEnabled || (originalWindowStyle?.transparentTitlebar ?? false)
    }

    func restoreWindow() {
        if let window = configuredWindow, let original = originalWindowStyle {
            window.isOpaque = original.opaque
            window.backgroundColor = original.background
            window.titlebarAppearsTransparent = original.transparentTitlebar
        }
        configuredWindow = nil
        originalWindowStyle = nil
    }
}

extension View {
    /// Keep content identity and editor focus while switching the decoration.
    func dieterGlass(_ glass: Glass = .regular, in shape: some Shape, solidColor: Color? = nil) -> some View {
        background(DieterTheme.usesTransparency ? .clear : (solidColor ?? DieterTheme.opaqueSurface), in: shape)
            .glassEffect(DieterTheme.usesTransparency ? glass : .identity, in: shape)
    }
}

struct DieterGlassButtonStyle: PrimitiveButtonStyle {
    var prominent = false

    @ViewBuilder func makeBody(configuration: Configuration) -> some View {
        if DieterTheme.usesTransparency {
            if prominent {
                Button(configuration).buttonStyle(.glassProminent)
            } else {
                Button(configuration).buttonStyle(.glass)
            }
        } else if prominent {
            Button(configuration).buttonStyle(.borderedProminent)
        } else {
            Button(configuration).buttonStyle(.bordered)
        }
    }
}
