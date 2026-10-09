import DieterAPI
import SwiftUI

/// Claude Design (claude.ai/design) on one machine. Claude Code keeps the
/// claude.ai login and the design credential on that machine; Dieter only
/// allows or stops Claude Design in the machine's Claude Code turns. The
/// shared core words the status; a sign-in runs while this page is shown.
struct ClaudeDesignSettings: View {
    @Environment(DieterStore.self) private var store
    @Environment(\.openURL) private var openURL
    @State private var machineID = ""
    @State private var confirmingRevoke = false
    @State private var browserSignOut = BrowserSignOut.idle

    private enum BrowserSignOut { case idle, signingOut, signedOut }

    private var design: ClaudeDesignModel { store.claudeDesign }
    private var machines: [MachineEndpoint] { store.machines.filter(store.machineIsAvailable) }

    var body: some View {
        SettingsPage {
            VStack(spacing: 14) {
                SettingsPanel(
                    title: "Machine", subtitle: "Claude Design uses the Claude account signed in on this machine."
                ) {
                    if machines.isEmpty {
                        Text("No machines are available.").font(.caption).foregroundStyle(DieterTheme.tertiary)
                    } else {
                        Picker("Machine", selection: $machineID) {
                            ForEach(machines) { machine in
                                Text(machine.name).tag(machine.daemonID ?? "")
                            }
                        }
                        .labelsHidden().frame(width: 220)
                        .accessibilityIdentifier("settings.claudeDesign.machine")
                    }
                }
                if !design.daemonID.isEmpty {
                    account
                    access
                }
                browser
            }
        }
        .onAppear {
            if !machines.contains(where: { $0.daemonID == machineID }) {
                machineID = machines.first?.daemonID ?? ""
            }
            design.show(daemonID: machineID.isEmpty ? nil : machineID)
        }
        .onChange(of: machineID) { _, id in design.show(daemonID: id.isEmpty ? nil : id) }
        .onDisappear { design.show(daemonID: nil) }
        .confirmationDialog(
            "Revoke Claude Design access for this Claude account?", isPresented: $confirmingRevoke,
            titleVisibility: .visible
        ) {
            Button("Revoke Access", role: .destructive) { design.setAccess(false, revokeGrant: true) }
                .accessibilityIdentifier("settings.claudeDesign.revokeConfirm")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Every Claude Code session of this account loses agent access to Claude Design projects, not only Dieter's. Allowing Claude Design here grants it again."
            )
        }
    }

    private var account: some View {
        SettingsPanel(title: "Account", subtitle: design.slice.headline) {
            VStack(alignment: .leading, spacing: 9) {
                Text(design.slice.detail)
                    .font(.system(size: 12)).foregroundStyle(DieterTheme.subtle)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.claudeDesign.detail")
                if let status = design.status, !status.claudeCodeVersion.isEmpty {
                    SettingsValueRow(title: "Claude Code", value: status.claudeCodeVersion)
                }
                if let signIn = design.signIn, signIn.active {
                    signInProgress(signIn)
                } else {
                    if let signIn = design.signIn, !signIn.message.isEmpty {
                        Label(
                            signIn.message,
                            systemImage: signIn.phase == .succeeded ? "checkmark.circle" : "xmark.octagon"
                        )
                        .font(.caption)
                        .foregroundStyle(
                            signIn.phase == .succeeded ? DieterTheme.machineOnline : DieterTheme.machineOffline
                        )
                        .accessibilityIdentifier("settings.claudeDesign.signInResult")
                    }
                    HStack(spacing: 8) {
                        Button(design.status?.signedIn == true ? "Sign In Again" : "Sign In") { design.startSignIn() }
                            .buttonStyle(DieterBarButtonStyle(prominent: design.status?.signedIn != true, size: 28))
                            .disabled(!design.slice.canSignIn)
                            .accessibilityIdentifier("settings.claudeDesign.signIn")
                            .smokeTarget("settings.claudeDesign.signIn")
                        Button("Refresh", systemImage: "arrow.clockwise") { design.refresh() }
                            .buttonStyle(DieterBarButtonStyle(size: 28))
                            .disabled(design.slice.loading)
                            .accessibilityIdentifier("settings.claudeDesign.refresh")
                        if design.slice.loading { ProgressView().controlSize(.small) }
                    }
                }
                if let error = design.error {
                    Text(error).font(.caption).foregroundStyle(DieterTheme.machineOffline)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings.claudeDesign.error")
                }
            }
        }
    }

    @ViewBuilder
    private func signInProgress(_ signIn: ClientClaudeDesignSignIn) -> some View {
        @Bindable var design = design
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                if signIn.phase != .waiting { ProgressView().controlSize(.small) }
                Text(progressText(signIn)).font(.system(size: 12, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.claudeDesign.signInPhase")
            }
            HStack(spacing: 8) {
                Button("Open Sign-In Page", systemImage: "arrow.up.forward.app") {
                    if let url = URL(string: signIn.openURL) { openURL(url) }
                }
                .buttonStyle(DieterBarButtonStyle(prominent: true, size: 28))
                .disabled(signIn.openURL.isEmpty)
                .accessibilityIdentifier("settings.claudeDesign.openPage")
                Button("Cancel") { design.cancelSignIn() }
                    .buttonStyle(DieterBarButtonStyle(size: 28))
                    .accessibilityIdentifier("settings.claudeDesign.cancelSignIn")
            }
            if signIn.codeRequired {
                HStack(spacing: 8) {
                    TextField("Authorization code", text: $design.code)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                        .onSubmit { design.submitCode() }
                        .disabled(signIn.phase != .waiting)
                        .accessibilityIdentifier("settings.claudeDesign.code")
                    Button("Submit Code") { design.submitCode() }
                        .buttonStyle(DieterBarButtonStyle(size: 28))
                        .disabled(signIn.phase != .waiting || design.code.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("settings.claudeDesign.submitCode")
                }
            }
            if !signIn.message.isEmpty, signIn.phase == .waiting {
                Text(signIn.message).font(.caption).foregroundStyle(DieterTheme.machineOffline)
            }
        }
    }

    private func progressText(_ signIn: ClientClaudeDesignSignIn) -> String {
        switch signIn.phase {
        case .preparing: signIn.message.isEmpty ? "Installing Claude Code on this machine…" : signIn.message
        case .waiting:
            signIn.codeRequired
                ? "Open the sign-in page, then paste the code it shows."
                : "Finish signing in in your browser. This page updates when it is done."
        case .checkingCode: "Checking the code…"
        default: "Starting the sign-in…"
        }
    }

    private var access: some View {
        SettingsPanel(title: "Claude Code turns") {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text("Allow in Claude Code turns").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    if design.slice.accessPending { ProgressView().controlSize(.small) }
                    Toggle(
                        "Allow in Claude Code turns",
                        isOn: Binding(get: { design.accessEnabled }, set: { design.setAccess($0) })
                    )
                    .labelsHidden().toggleStyle(.switch)
                    .disabled(!design.slice.canChangeAccess)
                    .accessibilityLabel("Allow Claude Design in Claude Code turns")
                    .accessibilityIdentifier("settings.claudeDesign.access")
                    .smokeTarget("settings.claudeDesign.access")
                }
                Text(design.slice.accessDetail)
                    .font(.caption).foregroundStyle(DieterTheme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if design.status?.signedIn == true || design.accessEnabled {
                    Button("Revoke Account Access…", role: .destructive) { confirmingRevoke = true }
                        .buttonStyle(DieterBarButtonStyle(destructive: true, size: 28))
                        .disabled(design.slice.accessPending)
                        .accessibilityIdentifier("settings.claudeDesign.revoke")
                }
            }
        }
    }

    /// The Mac's own claude.ai session, which shows artifacts and designs in
    /// the conversation workspace. It is separate from every machine's login.
    private var browser: some View {
        SettingsPanel(title: "Workspace browser") {
            VStack(alignment: .leading, spacing: 9) {
                Text(
                    "Claude artifacts and designs open in a workspace tab signed in to claude.ai on this Mac. Sign in there once, with your email address; that tab never leaves claude.ai and other pages keep a private session."
                )
                .font(.caption).foregroundStyle(DieterTheme.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Sign Out of claude.ai in Dieter") {
                        browserSignOut = .signingOut
                        Task {
                            await ClaudeBrowserSession.signOut()
                            browserSignOut = .signedOut
                        }
                    }
                    .buttonStyle(DieterBarButtonStyle(size: 28))
                    .disabled(browserSignOut == .signingOut)
                    .accessibilityIdentifier("settings.claudeDesign.browserSignOut")
                    if browserSignOut == .signingOut { ProgressView().controlSize(.small) }
                    if browserSignOut == .signedOut {
                        Text("Signed out").font(.caption).foregroundStyle(DieterTheme.tertiary)
                    }
                }
            }
        }
    }
}
