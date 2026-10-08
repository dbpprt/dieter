import AppKit
import SwiftUI

struct RequiredPermissionsGate<Content: View>: View {
    @Environment(RequiredPermissions.self) private var permissions
    @ViewBuilder var content: () -> Content
    var body: some View {
        if permissions.canUseApp { content() } else { RequiredPermissionsView() }
    }
}

struct RequiredPermissionsView: View {
    @Environment(RequiredPermissions.self) private var permissions

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Image(systemName: "lock.shield").font(.system(size: 40)).foregroundStyle(.tint)
                Text("Set up Dieter on this Mac").font(.largeTitle.bold())
                Text(
                    "These macOS permissions enable screen capture, browser context, and keyboard control. Grant access now, or skip and continue without those features."
                )
                .foregroundStyle(DieterTheme.subtle)
                permissionRow(
                    .accessibility, granted: permissions.accessibility,
                    detail:
                        "Lets Dieter read browser context and forward system shortcuts while you control a remote screen."
                )
                permissionRow(
                    .screenRecording, granted: permissions.screenRecording,
                    detail: "Lets Dieter capture your screen when you use Capture task. Audio is not recorded.")
                Text("In each pane, turn on Dieter. If it is missing, use + to add this application:")
                    .font(.callout).foregroundStyle(DieterTheme.subtle)
                Text(Bundle.main.bundlePath).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                Text(
                    "Return here after granting access. Dieter checks automatically. If macOS asks you to quit and reopen, reopen Dieter after quitting."
                )
                .font(.callout).foregroundStyle(DieterTheme.subtle)
                if let error = permissions.settingsError { Text(error).foregroundStyle(.red) }
                HStack(spacing: 8) {
                    Button("Check Again") { permissions.refresh() }
                        .buttonStyle(DieterBarButtonStyle())
                        .accessibilityIdentifier("permissions.check")
                        .smokeTarget("permissions.check")
                    Spacer()
                    Button("Skip for Now") { permissions.skipSetup() }
                        .buttonStyle(DieterBarButtonStyle())
                        .accessibilityIdentifier("permissions.skip")
                        .smokeTarget("permissions.skip")
                    Button("Quit Dieter") { NSApp.terminate(nil) }
                        .buttonStyle(DieterBarButtonStyle())
                }
                Text(
                    "Sharing this Mac through its daemon requires separate permission for the daemon. On that Mac, run dieter daemon permissions for guided setup."
                )
                .font(.caption).foregroundStyle(DieterTheme.subtle)
            }
            .padding(40)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .foregroundStyle(DieterTheme.text)
        .background(DieterTheme.opaqueSurface)
        .accessibilityIdentifier("permissions.onboarding")
    }

    private func permissionRow(_ permission: RequiredPermissions.Permission, granted: Bool, detail: String) -> some View
    {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: granted ? "checkmark.circle.fill" : "lock.circle")
                .font(.title2).foregroundStyle(granted ? Color.green : Color.secondary)
                .accessibilityLabel(granted ? "Granted" : "Required")
            VStack(alignment: .leading, spacing: 6) {
                Text(permission.title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(DieterTheme.subtle)
                if granted {
                    Text("Granted").font(.callout).foregroundStyle(.green)
                } else {
                    Button("Grant \(permission.title)…") { permissions.grant(permission) }
                        .buttonStyle(DieterBarButtonStyle(prominent: true))
                        .accessibilityIdentifier("permissions.grant.\(permission.rawValue)")
                        .smokeTarget("permissions.grant.\(permission.rawValue)")
                }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .dieterTile(radius: 14)
    }
}
