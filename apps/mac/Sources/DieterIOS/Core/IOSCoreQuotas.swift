#if os(iOS)
    import DieterAPI
    import Observation

    @MainActor
    @Observable
    final class IOSCoreQuotas {
        @ObservationIgnored private unowned let core: IOSCoreStore

        init(core: IOSCoreStore) { self.core = core }

        var providerQuotaGroups: [Dieter_Gateway_V1_ProviderQuotaGroup] {
            core.quotas.groups
        }
        var providerQuotasLoading: Bool { core.quotas.loading }
        var providerQuotaError: String? {
            core.quotas.error.isEmpty ? nil : core.quotas.error
        }
        var providerQuotaMutatingAccounts: Set<String> {
            Set(core.quotas.mutating)
        }

        func load(requestRefresh: Bool = false) async throws {
            var payload = ClientQuotasLoad()
            payload.refresh = requestRefresh
            var quotas = ClientQuotasCommand()
            quotas.load = payload
            var command = ClientCommand()
            command.quotas = quotas
            _ = try await core.dispatch(command)
        }

        func setSummaryInclusion(
            provider: Dieter_Gateway_V1_ProviderQuotaProvider,
            accountKey: String,
            included: Bool
        ) async throws {
            var payload = ClientQuotaInclusion()
            payload.provider = provider
            payload.accountKey = accountKey
            payload.included = included
            var quotas = ClientQuotasCommand()
            quotas.setIncluded = payload
            var command = ClientCommand()
            command.quotas = quotas
            _ = try await core.dispatch(command)
        }

        func consumeReset(accountKey: String) async throws {
            var payload = ClientQuotaAccount()
            payload.accountKey = accountKey
            var quotas = ClientQuotasCommand()
            quotas.consumeReset = payload
            var command = ClientCommand()
            command.quotas = quotas
            _ = try await core.dispatch(command)
        }
    }
#endif
