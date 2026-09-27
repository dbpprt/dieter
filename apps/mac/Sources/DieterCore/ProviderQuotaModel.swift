import DieterAPI
import Foundation
import Observation

@MainActor @Observable package final class ProviderQuotaModel {
    package private(set) var providerQuotaGroups: [Dieter_Gateway_V1_ProviderQuotaGroup] = []
    package private(set) var providerQuotasLoading = false
    package private(set) var providerQuotaError: String?
    package private(set) var providerQuotaMutatingAccounts: Set<String> = []
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var readID: UUID?
    @ObservationIgnored private var read: Task<Void, Never>?
    @ObservationIgnored private var mutations: [String: Task<Void, Never>] = [:]
    private let acquire: @MainActor () async throws -> FeatureClientLease<any ProviderQuotaRPC>

    package init(acquire: @escaping @MainActor () async throws -> FeatureClientLease<any ProviderQuotaRPC>) {
        self.acquire = acquire
    }

    package func install(_ groups: [Dieter_Gateway_V1_ProviderQuotaGroup]) { providerQuotaGroups = groups }

    package func reset() { pause(); providerQuotaGroups = [] }

    package func pause() {
        generation &+= 1
        readID = nil; read?.cancel(); read = nil
        mutations.values.forEach { $0.cancel() }; mutations.removeAll()
        providerQuotaMutatingAccounts = []
        providerQuotasLoading = false; providerQuotaError = nil
    }

    package func load(requestRefresh: Bool = false) async {
        guard !providerQuotasLoading, providerQuotaMutatingAccounts.isEmpty else { return }
        let owner = generation
        let id = UUID()
        readID = id
        providerQuotasLoading = true
        let task = Task { [self] in
            defer { if owner == generation, readID == id { providerQuotasLoading = false; readID = nil; read = nil } }
            do {
                let lease = try await acquire()
                defer { lease.release() }
                guard !Task.isCancelled, owner == generation, readID == id else { return }
                let groups =
                    if requestRefresh { try await lease.client.refreshProviderQuotas().groups } else {
                        try await lease.client.providerQuotas().groups
                    }
                guard !Task.isCancelled, owner == generation, readID == id else { return }
                providerQuotaGroups = groups; providerQuotaError = nil
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled, owner == generation, readID == id {
                    providerQuotaError = DieterRPCFailure.message(for: error)
                }
            }
        }
        read = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    package func setInclusion(provider: Dieter_Gateway_V1_ProviderQuotaProvider, accountKey: String, included: Bool)
        async
    {
        await mutate(accountKey: accountKey, provider: provider) { client in
            (
                try await client.setProviderQuotaSummaryInclusion(
                    provider: provider, accountKey: accountKey, included: included
                ).groups, nil
            )
        }
    }
    package func consumeReset(accountKey: String) async {
        let key = UUID().uuidString.lowercased()
        await mutate(accountKey: accountKey, provider: .openaiCodex) { client in
            let response = try await client.consumeProviderQuotaReset(accountKey: accountKey, idempotencyKey: key)
            return (
                response.groups,
                response.accepted ? nil : "No online machine with access to this OpenAI account accepted the reset."
            )
        }
    }
    private func mutate(
        accountKey: String, provider: Dieter_Gateway_V1_ProviderQuotaProvider,
        operation:
            @escaping @MainActor (any ProviderQuotaRPC) async throws -> (
                [Dieter_Gateway_V1_ProviderQuotaGroup], String?
            )
    ) async {
        guard providerQuotaMutatingAccounts.insert(accountKey).inserted else { return }
        let owner = generation
        readID = nil; read?.cancel(); read = nil; providerQuotasLoading = false
        let task = Task { [self] in
            defer {
                if owner == generation {
                    providerQuotaMutatingAccounts.remove(accountKey); mutations.removeValue(forKey: accountKey)
                }
            }
            do {
                let lease = try await acquire()
                defer { lease.release() }
                guard !Task.isCancelled, owner == generation else { return }
                let (groups, error) = try await operation(lease.client)
                guard !Task.isCancelled, owner == generation else { return }
                providerQuotaGroups.removeAll { $0.provider == provider }
                providerQuotaGroups.append(contentsOf: groups)
                providerQuotaGroups.sort { $0.provider.rawValue < $1.provider.rawValue }
                providerQuotaError = error
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled, owner == generation { providerQuotaError = DieterRPCFailure.message(for: error) }
            }
        }
        mutations[accountKey] = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }
}
