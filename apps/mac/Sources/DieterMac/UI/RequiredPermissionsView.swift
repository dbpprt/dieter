import AppKit
import SwiftUI

struct RequiredPermissionsGate<Content: View>: View {
    @Environment(RequiredPermissions.self) private var permissions
    @ViewBuilder var content: () -> Content
    var body: some View {
        if permissions.isReady { content() } else { RequiredPermissionsView() }
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
                    "Two macOS permissions are required for screen capture, browser context, and keyboard control. Grant access to Dieter in System Settings to continue."
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
                HStack {
                    Button("Check Again") { permissions.refresh() }
                        .accessibilityIdentifier("permissions.check")
                        .smokeTarget("permissions.check")
                    Spacer()
                    Button("Quit Dieter") { NSApp.terminate(nil) }
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
                        .buttonStyle(DieterPrimaryButtonStyle())
                        .accessibilityIdentifier("permissions.grant.\(permission.rawValue)")
                        .smokeTarget("permissions.grant.\(permission.rawValue)")
                }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .background(DieterTheme.raised, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(DieterTheme.border, lineWidth: 1))
    }
}
