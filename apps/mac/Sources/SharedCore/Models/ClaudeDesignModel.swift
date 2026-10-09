import DieterAPI
import Foundation
import Observation

/// Claude Design settings for one machine at a time, as the shared core reads
/// them: its status, a running sign-in, and whether the machine's Claude Code
/// turns may use Claude Design. Claude Code keeps every credential on that
/// machine.
@MainActor @Observable package final class ClaudeDesignModel {
    package private(set) var slice = ClientClaudeDesignSlice()
    /// The code the manual sign-in page shows, as the user types it.
    package var code = ""
    /// Why the last command could not reach the core.
    package private(set) var commandError: String?

    private let core: CoreClient
    @ObservationIgnored private var subscription: SliceSubscription?
    /// Commands reach the core in the order they were made.
    @ObservationIgnored private var queued: Task<Void, Never>?

    package init(core: CoreClient) {
        self.core = core
    }

    package var daemonID: String { slice.daemonID }
    package var status: Dieter_V1_ClaudeDesignStatus? { slice.hasStatus ? slice.status : nil }
    package var signIn: ClientClaudeDesignSignIn? { slice.hasSignIn ? slice.signIn : nil }
    package var signInRunning: Bool { signIn?.active == true }
    package var accessEnabled: Bool { status?.accessEnabled == true }
    /// The error to show: a refused command, else the core's.
    package var error: String? { commandError ?? (slice.error.isEmpty ? nil : slice.error) }

    /// Shows `daemonID`'s Claude Design; nil leaves the settings and ends a
    /// running sign-in.
    package func show(daemonID: String?) {
        if daemonID != nil { subscribe() }
        if daemonID != slice.daemonID { code = "" }
        commandError = nil
        enqueue { $0.select = .with { $0.daemonID = daemonID ?? "" } }
    }

    package func refresh() { enqueue { $0.refresh = ClientStep() } }

    package func startSignIn() {
        code = ""
        commandError = nil
        enqueue { $0.signIn = ClientStep() }
    }

    package func cancelSignIn() { enqueue { $0.cancelSignIn = ClientStep() } }

    package func submitCode() {
        let value = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        enqueue { $0.submitCode = .with { $0.code = value } }
    }

    /// Allows or stops Claude Design in the machine's Claude Code turns;
    /// `revokeGrant` also withdraws the Claude account's agent access.
    package func setAccess(_ enabled: Bool, revokeGrant: Bool = false) {
        commandError = nil
        enqueue {
            $0.setAccess = .with {
                $0.enabled = enabled
                $0.revokeGrant = revokeGrant && !enabled
            }
        }
    }

    private func subscribe() {
        guard subscription == nil else { return }
        subscription = SliceSubscription(client: core, slice: .claudeDesign, scope: "") { [weak self] update in
            guard let self, case .claudeDesign(let slice) = update.value, self.slice != slice else { return }
            self.slice = slice
        }
    }

    private func enqueue(_ build: (inout ClientClaudeDesignCommand) -> Void) {
        var command = ClientClaudeDesignCommand()
        build(&command)
        let sent = command, previous = queued, core = core
        queued = Task { [weak self] in
            await previous?.value
            do {
                _ = try await core.dispatch(.with { $0.claudeDesign = sent })
            } catch {
                self?.commandError = (error as? CoreFailure)?.message ?? error.localizedDescription
            }
        }
    }
}
