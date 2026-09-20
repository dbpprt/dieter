import AppKit
@preconcurrency import ApplicationServices
import CoreGraphics
import Observation

/// OS grants are the source of truth. Never persist a completed-onboarding flag.
@MainActor
@Observable
final class RequiredPermissions {
    enum Permission: String, CaseIterable {
        case accessibility, screenRecording

        var title: String {
            switch self {
            case .accessibility: "Accessibility"
            case .screenRecording: "Screen & System Audio Recording"
            }
        }
        var pane: String {
            switch self {
            case .accessibility: "Privacy_Accessibility"
            case .screenRecording: "Privacy_ScreenCapture"
            }
        }
    }

    private(set) var accessibility = false
    private(set) var screenRecording = false
    private(set) var settingsError: String?
    var isReady: Bool { accessibility && screenRecording }
    @ObservationIgnored private let check: (Permission) -> Bool
    @ObservationIgnored private let request: (Permission) -> Void
    @ObservationIgnored private let openSettings: (Permission) -> Bool

    init(
        check: @escaping (Permission) -> Bool,
        request: @escaping (Permission) -> Void,
        openSettings: @escaping (Permission) -> Bool
    ) {
        self.check = check
        self.request = request
        self.openSettings = openSettings
        refresh()
    }

    func refresh() {
        accessibility = check(.accessibility)
        screenRecording = check(.screenRecording)
    }

    func grant(_ permission: Permission) {
        // Only an explicit user action may trigger an OS prompt.
        request(permission)
        settingsError =
            openSettings(permission) ? nil : "Open System Settings → Privacy & Security → \(permission.title)."
        refresh()
    }

    static func live() -> RequiredPermissions {
        #if DIETER_UI_SMOKE
            if ProcessInfo.processInfo.arguments.contains(where: { $0.hasSuffix("-ui-smoke") }) {
                return RequiredPermissions(check: { _ in true }, request: { _ in }, openSettings: { _ in true })
            }
        #endif
        return RequiredPermissions(
            check: { permission in
                switch permission {
                case .accessibility: AXIsProcessTrusted()
                case .screenRecording: CGPreflightScreenCaptureAccess()
                }
            },
            request: { permission in
                switch permission {
                case .accessibility:
                    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                    _ = AXIsProcessTrustedWithOptions(options)
                case .screenRecording:
                    _ = CGRequestScreenCaptureAccess()
                }
            },
            openSettings: { permission in
                guard
                    let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(permission.pane)")
                else { return false }
                return NSWorkspace.shared.open(url)
            }
        )
    }
}
