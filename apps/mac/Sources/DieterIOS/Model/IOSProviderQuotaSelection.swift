import DieterAPI

struct IOSProviderQuotaAccountSelection {
    let provider: Dieter_Gateway_V1_ProviderQuotaProvider
    let account: Dieter_Gateway_V1_ProviderQuotaSnapshot
}

enum IOSProviderQuotaSelection {
    static func account(
        for card: Dieter_V1_Card,
        in groups: [Dieter_Gateway_V1_ProviderQuotaGroup]
    ) -> IOSProviderQuotaAccountSelection? {
        guard !card.providerAccountKey.isEmpty else { return nil }
        for group in groups {
            if let account = group.accounts.first(where: { $0.accountKey == card.providerAccountKey }) {
                return IOSProviderQuotaAccountSelection(provider: group.provider, account: account)
            }
        }
        return nil
    }
}
