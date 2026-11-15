import AppKit
import DieterClientAPI
import DieterCore
import SwiftUI

/// Signs a provider account in on one machine, step by step as the core's
/// session says: open the provider's page on this Mac, then paste the code
/// it shows, enter a device code there, or paste the address the browser
/// could not open. During "all machines" the core moves on to the next
/// machine by itself after each success.
struct ProviderSignInSheet: View {
    @Environment(DieterStore.self) private var store
    let sessionID: String
    /// A retry started a new session.
    let replace: (String) -> Void
    let close: () -> Void
    @State private var code = ""
    @State private var callbackURL = ""
    @State private var showsCallback = false
    @State private var submitting = false

    private var providers: ProvidersModel { store.providersModel }
    private var session: ClientProviderSignInSession? { providers.session(sessionID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let session {
                header(session)
                step(session)
                if let failure = providers.failure {
                    Text(failure)
                        .font(.caption).foregroundStyle(DieterTheme.coral)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("providers.signin.failure")
                }
                footer(session)
            } else {
                Text("Sign in").font(.title2.weight(.bold))
                Text("This sign-in is no longer open.")
                    .font(.callout).foregroundStyle(DieterTheme.subtle)
                HStack {
                    Spacer()
                    Button("Close") { finish() }
                        .buttonStyle(DieterBarButtonStyle(prominent: true))
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 500)
        .onAppear { providers.observe() }
        .onDisappear { providers.release() }
        .onChange(of: session?.daemonID) { _, _ in
            // The next machine of "all machines" asks for its own input.
            code = ""
            callbackURL = ""
            showsCallback = false
        }
        .accessibilityIdentifier("providers.signin")
        .e2eTarget("providers.signin")
    }

    private func header(_ session: ClientProviderSignInSession) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(session.title).font(.title2.weight(.bold))
                .e2eTarget("providers.signin.title", text: session.title)
            HStack(spacing: 6) {
                if !session.accountLabel.isEmpty {
                    Text(session.accountLabel).font(.callout.weight(.semibold))
                }
                if session.remainingMachines > 0 {
                    Text(
                        session.remainingMachines == 1
                            ? "Then 1 more machine" : "Then \(session.remainingMachines) more machines"
                    )
                    .font(.caption).foregroundStyle(DieterTheme.tertiary)
                }
            }
        }
    }

    @ViewBuilder private func step(_ session: ClientProviderSignInSession) -> some View {
        switch session.phase {
        case "succeeded":
            Label(session.instructions, systemImage: "checkmark.circle.fill")
                .font(.callout).foregroundStyle(DieterTheme.running)
                .e2eTarget("providers.signin.status", text: "Signed in")
        case "failed":
            Label(session.error.isEmpty ? session.instructions : session.error, systemImage: "xmark.circle.fill")
                .font(.callout).foregroundStyle(DieterTheme.coral)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .e2eTarget("providers.signin.status", text: "Failed")
        case "canceled":
            Label(session.instructions, systemImage: "minus.circle")
                .font(.callout).foregroundStyle(DieterTheme.subtle)
        case "waiting":
            VStack(alignment: .leading, spacing: 12) {
                Text(session.instructions).font(.callout).foregroundStyle(DieterTheme.subtle)
                    .fixedSize(horizontal: false, vertical: true)
                if let url = session.pageURL {
                    Button("Open sign-in page", systemImage: "safari") { NSWorkspace.shared.open(url) }
                        .buttonStyle(
                            DieterBarButtonStyle(prominent: session.expects != "code" || code.isEmpty, size: 30)
                        )
                        .help(url.absoluteString)
                        .accessibilityIdentifier("providers.signin.open")
                        .e2eTarget("providers.signin.open")
                }
                input(session)
            }
        default:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(session.instructions).font(.callout).foregroundStyle(DieterTheme.subtle)
            }
            .e2eTarget("providers.signin.status", text: session.phase)
        }
    }

    @ViewBuilder private func input(_ session: ClientProviderSignInSession) -> some View {
        switch session.expects {
        case "code":
            codeField(session)
            DisclosureGroup("The browser couldn't open a page?", isExpanded: $showsCallback) {
                callbackField(session).padding(.top, 6)
            }
            .font(.caption)
        case "none":
            deviceCode(session)
        case "callback":
            if !session.sameHost { callbackField(session) }
        default:
            EmptyView()
        }
    }

    private func codeField(_ session: ClientProviderSignInSession) -> some View {
        HStack(spacing: 8) {
            TextField("Paste the code", text: $code)
                .font(.system(size: 13, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .onSubmit { submitCode(session) }
                .accessibilityIdentifier("providers.signin.code")
                .e2eTarget("providers.signin.code")
            Button("Continue") { submitCode(session) }
                .buttonStyle(DieterBarButtonStyle(prominent: true, size: 28))
                .disabled(submitting || code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("providers.signin.submit")
                .e2eTarget("providers.signin.submit")
        }
    }

    private func callbackField(_ session: ClientProviderSignInSession) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Paste the address your browser couldn't open")
                .font(.caption).foregroundStyle(DieterTheme.subtle)
            HStack(spacing: 8) {
                TextField("http://localhost:…", text: $callbackURL)
                    .font(.system(size: 12, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { submitCallback(session) }
                    .accessibilityIdentifier("providers.signin.callback")
                    .e2eTarget("providers.signin.callback")
                Button("Continue") { submitCallback(session) }
                    .buttonStyle(DieterBarButtonStyle(prominent: session.expects == "callback", size: 28))
                    .disabled(submitting || callbackURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier(
                        session.expects == "callback" ? "providers.signin.submit" : "providers.signin.callback-submit"
                    )
                    .e2eTarget(
                        session.expects == "callback" ? "providers.signin.submit" : "providers.signin.callback-submit")
            }
        }
    }

    private func deviceCode(_ session: ClientProviderSignInSession) -> some View {
        let display = SharedRules.shared.providerDeviceCode(code: session.userCode)
        return HStack(alignment: .center, spacing: 12) {
            Text(display)
                .font(.system(size: 26, weight: .semibold, design: .monospaced)).tracking(2)
                .textSelection(.enabled)
                .accessibilityLabel("Device code \(display)")
                .e2eTarget("providers.signin.user-code", text: display)
            Button("Copy", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(session.userCode, forType: .string)
            }
            .buttonStyle(DieterBarButtonStyle(size: 26))
            .accessibilityIdentifier("providers.signin.copy-code")
            .e2eTarget("providers.signin.copy-code")
            Spacer(minLength: 0)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(
                    SharedRules.shared.providerCodeExpiry(
                        expiresAt: session.expiresAt, nowMillis: context.date.epochMillis)
                )
                .font(.caption.monospacedDigit()).foregroundStyle(DieterTheme.tertiary)
            }
        }
    }

    private func footer(_ session: ClientProviderSignInSession) -> some View {
        HStack {
            if session.phase == "failed" || session.phase == "canceled" {
                Button("Try again") { retry(session) }
                    .buttonStyle(DieterBarButtonStyle())
                    .disabled(providers.working)
                    .accessibilityIdentifier("providers.signin.retry")
            }
            Spacer()
            if session.isLive {
                Button("Cancel") {
                    Task {
                        await providers.cancel(sessionID: session.id)
                        finish()
                    }
                }
                .buttonStyle(DieterBarButtonStyle())
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("providers.signin.cancel")
            } else {
                Button("Done") { finish() }
                    .buttonStyle(DieterBarButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("providers.signin.done")
                    .e2eTarget("providers.signin.done")
            }
        }
    }

    private func submitCode(_ session: ClientProviderSignInSession) {
        let typed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty, !submitting, session.acceptsInput else { return }
        submitting = true
        Task {
            await providers.submit(sessionID: session.id, code: typed)
            submitting = false
        }
    }

    private func submitCallback(_ session: ClientProviderSignInSession) {
        let typed = callbackURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty, !submitting, session.acceptsInput else { return }
        submitting = true
        Task {
            await providers.submit(sessionID: session.id, callbackURL: typed)
            submitting = false
        }
    }

    /// Signs in on the same machine again, in a new session.
    private func retry(_ session: ClientProviderSignInSession) {
        Task {
            guard let next = await providers.signIn(accountID: session.accountID, daemonID: session.daemonID),
                next != session.id
            else { return }
            replace(next)
            await providers.dismiss(sessionID: session.id)
        }
    }

    /// Drops the session (canceling it when still live) and closes.
    private func finish() {
        let id = sessionID
        close()
        Task { await providers.dismiss(sessionID: id) }
    }
}
