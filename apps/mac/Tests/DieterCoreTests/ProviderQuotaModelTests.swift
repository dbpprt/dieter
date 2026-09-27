import DieterAPI
import DieterCore
import Foundation
import Testing

private actor ControlledQuotas: ProviderQuotaRPC {
    var reads: [CheckedContinuation<Dieter_Gateway_V1_ListProviderQuotasResponse, Error>] = []
    var updates: [CheckedContinuation<Dieter_Gateway_V1_SetProviderQuotaSummaryInclusionResponse, Error>] = []
    var readCount: Int { reads.count }
    var updateCount: Int { updates.count }
    func providerQuotas() async throws -> Dieter_Gateway_V1_ListProviderQuotasResponse {
        try await withCheckedThrowingContinuation { reads.append($0) }
    }
    func refreshProviderQuotas() async throws -> Dieter_Gateway_V1_RefreshProviderQuotasResponse {
        throw CancellationError()
    }
    func setProviderQuotaSummaryInclusion(
        provider: Dieter_Gateway_V1_ProviderQuotaProvider, accountKey: String, included: Bool
    ) async throws -> Dieter_Gateway_V1_SetProviderQuotaSummaryInclusionResponse {
        try await withCheckedThrowingContinuation { updates.append($0) }
    }
    func consumeProviderQuotaReset(accountKey: String, idempotencyKey: String) async throws
        -> Dieter_Gateway_V1_ConsumeProviderQuotaResetResponse
    { throw CancellationError() }
    func finishRead(_ index: Int, provider: Dieter_Gateway_V1_ProviderQuotaProvider) {
        var group = Dieter_Gateway_V1_ProviderQuotaGroup(); group.provider = provider
        var response = Dieter_Gateway_V1_ListProviderQuotasResponse(); response.groups = [group]
        reads[index].resume(returning: response)
    }
    func finishUpdate(_ index: Int) { updates[index].resume(returning: .init()) }
}

@Test @MainActor func quotaAccountReplacementRejectsLateReadAndReturnsEveryLease() async {
    let client = ControlledQuotas()
    var returned = 0
    let quotas = ProviderQuotaModel { FeatureClientLease(client: client, release: { returned += 1 }) }
    let old = Task { await quotas.load() }
    while await client.readCount < 1 { await Task.yield() }
    quotas.reset()
    let current = Task { await quotas.load() }
    while await client.readCount < 2 { await Task.yield() }
    await client.finishRead(0, provider: .openaiCodex)
    await old.value
    #expect(quotas.providerQuotasLoading)
    #expect(quotas.providerQuotaGroups.isEmpty)
    await client.finishRead(1, provider: .openaiCodex)
    await current.value
    #expect(!quotas.providerQuotasLoading)
    #expect(quotas.providerQuotaGroups.count == 1)
    #expect(returned == 2)
}

@Test @MainActor func retiringQuotaMutationCannotClearSuccessorForSameAccount() async {
    let client = ControlledQuotas()
    let quotas = ProviderQuotaModel { FeatureClientLease(client: client) }
    let old = Task { await quotas.setInclusion(provider: .openaiCodex, accountKey: "account", included: true) }
    while await client.updateCount < 1 { await Task.yield() }
    quotas.reset()
    let current = Task { await quotas.setInclusion(provider: .openaiCodex, accountKey: "account", included: false) }
    while await client.updateCount < 2 { await Task.yield() }
    await client.finishUpdate(0)
    await old.value
    #expect(quotas.providerQuotaMutatingAccounts == ["account"])
    await client.finishUpdate(1)
    await current.value
    #expect(quotas.providerQuotaMutatingAccounts.isEmpty)
}
