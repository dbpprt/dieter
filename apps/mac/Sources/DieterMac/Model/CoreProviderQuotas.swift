import DieterAPI
import Foundation
import Observation
import SharedCore

/// Provider quota snapshots, which the shared core watches on the gateway
/// rather than polling; changes are deduplicated per account there.
@MainActor @Observable
final class CoreProviderQuotas {
    private(set) var providerQuotaGroups: [Dieter_Gateway_V1_ProviderQuotaGroup] = []
    private(set) var providerQuotasLoading = false
    private(set) var providerQuotaError: String?
    private(set) var providerQuotaMutatingAccounts: Set<String> = []
    @ObservationIgnored private let core: CoreClient
    @ObservationIgnored private var subscription: SliceSubscription?
    /// Groups a UI fixture installed; the core's do not replace them.
    @ObservationIgnored private var installed = false

    init(core: CoreClient) {
        self.core = core
    }

    private func start() {
        guard subscription == nil else { return }
        subscription = SliceSubscription(client: core, slice: .quotas, scope: "") { [weak self] update in
            guard let self, case .quotas(let slice) = update.value else { return }
            self.fold(slice)
        }
    }

    private func fold(_ slice: ClientQuotasSlice) {
        guard !installed else { return }
        if providerQuotaGroups != slice.groups { providerQuotaGroups = slice.groups }
        if providerQuotasLoading != slice.loading { providerQuotasLoading = slice.loading }
        let error = slice.error.isEmpty ? nil : slice.error
        if providerQuotaError != error { providerQuotaError = error }
        let mutating = Set(slice.mutating)
        if providerQuotaMutatingAccounts != mutating { providerQuotaMutatingAccounts = mutating }
    }

    /// Shows fixture groups, e.g. in UI smoke runs.
    func install(_ groups: [Dieter_Gateway_V1_ProviderQuotaGroup]) {
        installed = true
        providerQuotaGroups = groups
    }

    func load(requestRefresh: Bool = false) async {
        start()
        await run { $0.load = .with { $0.refresh = requestRefresh } }
    }

    func setInclusion(provider: Dieter_Gateway_V1_ProviderQuotaProvider, accountKey: String, included: Bool) async {
        await run { command in
            command.setIncluded = .with {
                $0.provider = provider
                $0.accountKey = accountKey
                $0.included = included
            }
        }
    }

    func consumeReset(accountKey: String) async {
        await run { command in command.consumeReset = .with { $0.accountKey = accountKey } }
    }

    private func run(_ build: (inout ClientQuotasCommand) -> Void) async {
        var command = ClientQuotasCommand()
        build(&command)
        let sent = command
        do {
            _ = try await core.dispatch(.with { $0.quotas = sent })
        } catch let failure as CoreFailure {
            providerQuotaError = failure.message
        } catch {}
    }
}
