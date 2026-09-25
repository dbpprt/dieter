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
    let solidColor: Color
    var paneTitlebarEnabled = false

    func makeNSView(context: Context) -> DieterWindowBackdropView {
        let view = DieterWindowBackdropView()
        view.configure(
            transparencyEnabled: transparencyEnabled, solidColor: solidColor,
            paneTitlebarEnabled: paneTitlebarEnabled)
        return view
    }

    func updateNSView(_ view: DieterWindowBackdropView, context: Context) {
        view.configure(
            transparencyEnabled: transparencyEnabled, solidColor: solidColor,
            paneTitlebarEnabled: paneTitlebarEnabled)
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
    private var paneTitlebarEnabled = false
    private var solidColor = NSColor.windowBackgroundColor
    private var configuredColor: Color?
    private var hasConfiguration = false
    private weak var configuredWindow: NSWindow?
    private var originalWindowStyle:
        (
            opaque: Bool, background: NSColor?, transparentTitlebar: Bool, titleVisibility: NSWindow.TitleVisibility
        )?
    private(set) var resolvedColorCount = 0
    private(set) var appliedConfigurationCount = 0
    private(set) var windowStyleMutationCount = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .underWindowBackground
        blendingMode = .behindWindow
        state = .active
        setAccessibilityIdentifier("workspace.window-backdrop")
    }

    required init?(coder: NSCoder) { nil }

    func configure(transparencyEnabled: Bool, solidColor: Color, paneTitlebarEnabled: Bool = false) {
        let colorChanged = configuredColor != solidColor
        let modeChanged =
            !hasConfiguration || self.transparencyEnabled != transparencyEnabled
            || self.paneTitlebarEnabled != paneTitlebarEnabled
        guard colorChanged || modeChanged else { return }
        if colorChanged || !hasConfiguration {
            configuredColor = solidColor
            self.solidColor = NSColor(solidColor)
            resolvedColorCount += 1
        }
        applyConfiguration(transparencyEnabled: transparencyEnabled, paneTitlebarEnabled: paneTitlebarEnabled)
    }

    func configure(transparencyEnabled: Bool, solidColor: NSColor, paneTitlebarEnabled: Bool = false) {
        let colorChanged = self.solidColor != solidColor || configuredColor != nil
        let modeChanged =
            !hasConfiguration || self.transparencyEnabled != transparencyEnabled
            || self.paneTitlebarEnabled != paneTitlebarEnabled
        guard colorChanged || modeChanged else { return }
        configuredColor = nil
        self.solidColor = solidColor
        applyConfiguration(transparencyEnabled: transparencyEnabled, paneTitlebarEnabled: paneTitlebarEnabled)
    }

    private func applyConfiguration(transparencyEnabled: Bool, paneTitlebarEnabled: Bool) {
        self.transparencyEnabled = transparencyEnabled
        self.paneTitlebarEnabled = paneTitlebarEnabled
        let hidden = !transparencyEnabled
        if isHidden != hidden { isHidden = hidden }
        hasConfiguration = true
        appliedConfigurationCount += 1
        applyWindowStyle()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if configuredWindow !== window {
            restoreWindow()
            if let window {
                configuredWindow = window
                originalWindowStyle = (
                    window.isOpaque, window.backgroundColor, window.titlebarAppearsTransparent, window.titleVisibility
                )
            }
        }
        applyWindowStyle()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func applyWindowStyle() {
        guard let window = configuredWindow else { return }
        let opaque = !transparencyEnabled
        let background: NSColor = transparencyEnabled ? .clear : solidColor
        let transparentTitlebar =
            paneTitlebarEnabled || transparencyEnabled
            || (originalWindowStyle?.transparentTitlebar ?? false)
        let titleVisibility =
            paneTitlebarEnabled
            ? NSWindow.TitleVisibility.hidden
            : (originalWindowStyle?.titleVisibility ?? .visible)
        if window.isOpaque != opaque {
            window.isOpaque = opaque
            windowStyleMutationCount += 1
        }
        if window.backgroundColor != background {
            window.backgroundColor = background
            windowStyleMutationCount += 1
        }
        if window.titlebarAppearsTransparent != transparentTitlebar {
            window.titlebarAppearsTransparent = transparentTitlebar
            windowStyleMutationCount += 1
        }
        if window.titleVisibility != titleVisibility {
            window.titleVisibility = titleVisibility
            windowStyleMutationCount += 1
        }
    }

    func restoreWindow() {
        if let window = configuredWindow, let original = originalWindowStyle {
            window.isOpaque = original.opaque
            window.backgroundColor = original.background
            window.titlebarAppearsTransparent = original.transparentTitlebar
            window.titleVisibility = original.titleVisibility
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

/// Floating content sits above busy, moving views, so ordinary pane translucency
/// does not provide enough separation. Keep the native glass highlight and blur,
/// then add a palette wash whose density matches the size of the floating surface.
private struct DieterFloatingGlassChrome: ViewModifier {
    enum Kind {
        case toast
        case overlay

        var surfaceOpacity: Double {
            switch self {
            case .toast: 0.86
            case .overlay: 0.78
            }
        }

        var ambientShadowOpacity: Double {
            switch self {
            case .toast: 0.28
            case .overlay: 0.38
            }
        }

        var ambientShadowRadius: CGFloat {
            switch self {
            case .toast: 18
            case .overlay: 32
            }
        }

        var ambientShadowY: CGFloat {
            switch self {
            case .toast: 7
            case .overlay: 16
            }
        }
    }

    let cornerRadius: CGFloat
    let kind: Kind

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        content
            .background(
                DieterTheme.opaqueSurface.opacity(DieterTheme.usesTransparency ? kind.surfaceOpacity : 1),
                in: shape
            )
            .glassEffect(DieterTheme.usesTransparency ? .regular : .identity, in: shape)
            .overlay {
                shape.stroke(DieterTheme.strongBorder, lineWidth: 1)
            }
            .overlay {
                shape.stroke(
                    LinearGradient(
                        colors: [
                            .white.opacity(DieterTheme.usesTransparency ? 0.28 : 0.10),
                            .clear,
                            .black.opacity(DieterTheme.usesTransparency ? 0.16 : 0.08),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.75
                )
            }
            .shadow(color: .black.opacity(0.16), radius: 2, y: 1)
            .shadow(
                color: .black.opacity(kind.ambientShadowOpacity),
                radius: kind.ambientShadowRadius,
                y: kind.ambientShadowY
            )
    }
}

extension View {
    func dieterToastChrome(cornerRadius: CGFloat = 13) -> some View {
        modifier(DieterFloatingGlassChrome(cornerRadius: cornerRadius, kind: .toast))
    }

    func dieterOverlayChrome(cornerRadius: CGFloat = 18) -> some View {
        modifier(DieterFloatingGlassChrome(cornerRadius: cornerRadius, kind: .overlay))
    }
}
