import AppKit
import DieterAPI
import Foundation
import OSLog
import SharedCore

/// Connection commands go to the shared core, which owns gateways, routes,
/// reconnects, and sign-in.
extension DieterStore {
    /// Connects to the active gateway, or makes `gateway` active first. The
    /// core streams every machine of the gateway; none is chosen. Returns
    /// once the core is connected, fails, or the attempt times out.
    func connect(to gateway: MachineEndpoint? = nil) async {
        await startCore()
        if let gateway, gateway.credentialID != activeGateway.credentialID {
            await useGateway(gateway)
        }
        await perform { $0.setConnected = .with { $0.connected = true } }
        _ = await awaitCore { phase.isConnected || settled }
    }

    /// The core reached an outcome other than connected: it needs the user
    /// or an update, or it is retrying after a failed attempt.
    private var settled: Bool {
        switch session.phase {
        case .authRequired, .updateRequired: true
        case .reconnecting: !session.error.isEmpty
        default: false
        }
    }

    /// Opens the gateway's GitHub sign-in in the browser; the callback URL
    /// returns through `completeAuthentication(url:)`.
    func signIn() async {
        await startCore()
        guard
            let started = await perform({ $0.beginSignIn = .with { $0.gatewayURL = activeGateway.address } }),
            let url = URL(string: started.signInStarted.authorizeURL)
        else { return }
        if !NSWorkspace.shared.open(url) { errorMessage = "Could not open the browser to sign in." }
    }

    func completeAuthentication(url: URL) {
        guard CoreHostPlatform.isNativeOAuthCallback(url) else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.startCore()
            do {
                try await self.core.dispatch { $0.completeSignIn = .with { $0.callbackURL = url.absoluteString } }
            } catch {
                self.errorMessage =
                    "Could not finish sign-in: \((error as? CoreFailure)?.message ?? error.localizedDescription)"
            }
        }
    }

    func disconnect() {
        Task { await perform { $0.setConnected = .with { $0.connected = false } } }
    }

    /// Replays every machine's changes from scratch; the workspace stays shown
    /// until each machine has caught up.
    func cleanSync() async {
        await perform { $0.resync = ClientResync() }
    }

    func chooseGateway(_ gateway: MachineEndpoint) async {
        guard gateway.daemonID == nil else { return }
        await useGateway(gateway)
        await connect()
    }

    func saveEndpoint(_ endpoint: MachineEndpoint) async {
        guard await useGateway(endpoint) else { return }
        await connect()
    }

    /// Removes a configured gateway; the core keeps at least one.
    func deleteEndpoint(_ endpoint: MachineEndpoint) {
        guard endpoint.daemonID == nil else { return }
        Task { await perform { $0.removeGateway = .with { $0.origin = endpoint.credentialID } } }
    }

    /// Makes `gateway` active, adding it to the configured gateways when it is new.
    @discardableResult
    private func useGateway(_ gateway: MachineEndpoint) async -> Bool {
        await perform {
            $0.useGateway = .with {
                $0.url = gateway.address
                $0.name = gateway.name
            }
        } != nil
    }

    func revokeDaemon(_ endpoint: MachineEndpoint) async {
        guard let daemonID = endpoint.daemonID else { return }
        await perform { $0.revokeMachine = .with { $0.daemonID = daemonID } }
    }

    func renameMachine(_ endpoint: MachineEndpoint, name: String) async {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let daemonID = endpoint.daemonID, !normalized.isEmpty else { return }
        await perform {
            $0.renameMachine = .with {
                $0.daemonID = daemonID
                $0.name = normalized
            }
        }
    }

    /// Shared project and board edits go through the core, which reaches the
    /// machines that hold them; this only reports when the Mac is offline.
    @discardableResult
    func ensureConnected(reportOffline: Bool = true) async -> Bool {
        guard !Task.isCancelled else { return false }
        if phase.isConnected { return true }
        if reportOffline {
            errorMessage = "Dieter is offline. Changes to this project are available once it reconnects."
        }
        return false
    }

    /// Keeps connection state current when the app returns to the foreground.
    func applicationDidBecomeActive() {
        Task { await perform { $0.setForeground = .with { $0.foreground = true } } }
    }

    /// The Mac stays connected in the background; see `startCore()`. Draft
    /// text typed in the last moments is saved now.
    func applicationDidResignActive() {
        Task { await composerDrafts.save() }
    }

    func loadProviderQuotas(requestRefresh: Bool = false) async { await quotas.load(requestRefresh: requestRefresh) }
    func setProviderQuotaSummaryInclusion(
        provider: Dieter_Gateway_V1_ProviderQuotaProvider, accountKey: String, included: Bool
    ) async {
        await quotas.setInclusion(provider: provider, accountKey: accountKey, included: included)
    }
    func consumeProviderQuotaReset(accountKey: String) async { await quotas.consumeReset(accountKey: accountKey) }

}
