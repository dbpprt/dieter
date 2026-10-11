import DieterClientAPI
import DieterCore
import SwiftUI

/// The window controls and the show-sidebar button while the sidebar card is
/// hidden. Top bars move right by this capsule's width.
struct DieterWindowControlsCapsule: View {
    static let width: CGFloat = 132
    let showSidebar: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            DieterWindowTrafficLights()
                .frame(width: 76, height: 36)
            Button(action: showSidebar) {
                Image(systemName: "sidebar.left").font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(DieterBarButtonStyle(shape: .circle, size: 28))
            .help("Show sidebar (⌃⌘S)")
            .accessibilityLabel("Show sidebar")
            .accessibilityIdentifier("workspace.sidebar.show")
            Spacer(minLength: 0)
        }
        .padding(.trailing, 6)
        .frame(width: Self.width, height: 36)
        .dieterCapsuleChrome(interactive: false)
    }
}

/// How far top bars move right so they clear the floating window controls.
private struct DieterTitleBandLeadingInsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var dieterTitleBandLeadingInset: CGFloat {
        get { self[DieterTitleBandLeadingInsetKey.self] }
        set { self[DieterTitleBandLeadingInsetKey.self] = newValue }
    }
}

/// A floating glass notice while synchronized views show cached data.
struct WorkspaceFreshnessBanner: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let notice: ClientWorkspaceNotice
    let lastSyncedAt: Date?

    private var isWorking: Bool { notice.working }
    private var accent: Color { notice.offline ? DieterTheme.coral : DieterTheme.amber }
    private var title: String { notice.title }
    private var detail: String { notice.detail }

    private func updated(now: Date) -> String {
        SharedRules.shared.workspaceUpdated(atMillis: lastSyncedAt?.epochMillis ?? 0, nowMillis: now.epochMillis)
    }

    var body: some View {
        let now = Date()
        HStack(spacing: 9) {
            Group {
                if isWorking {
                    if reduceMotion {
                        Image(systemName: "hourglass").font(.system(size: 10))
                    } else {
                        ProgressView().controlSize(.mini).accessibilityLabel(title)
                    }
                } else {
                    Image(systemName: "wifi.slash")
                        .font(.system(size: 10, weight: .semibold))
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(accent)
            .frame(width: 16)
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(DieterTheme.subtle)
                .lineLimit(1)
            Text(updated(now: now))
                .font(DieterFont.monoSmall)
                .foregroundStyle(DieterTheme.tertiary)
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .dieterCapsuleChrome(interactive: false)
        .overlay { Capsule().strokeBorder(accent.opacity(0.35), lineWidth: 1).allowsHitTesting(false) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(title). \(detail) \(updated(now: now))."
        )
        .accessibilityIdentifier("workspace.cached")
    }
}
