import DieterAPI
import Testing

@testable import DieterIOS

@Test func conversationQuotaSelectsOnlyTheCardsProviderAccount() throws {
    var otherAccount = Dieter_Gateway_V1_ProviderQuotaSnapshot()
    otherAccount.accountKey = "other-account"

    var selectedAccount = Dieter_Gateway_V1_ProviderQuotaSnapshot()
    selectedAccount.accountKey = "selected-account"

    var openAI = Dieter_Gateway_V1_ProviderQuotaGroup()
    openAI.provider = .openaiCodex
    openAI.accounts = [otherAccount, selectedAccount]

    var claude = Dieter_Gateway_V1_ProviderQuotaGroup()
    claude.provider = .anthropicClaude
    claude.accounts = [otherAccount]

    var card = Dieter_V1_Card()
    card.provider = "codex"
    card.providerAccountKey = selectedAccount.accountKey

    let selection = try #require(IOSProviderQuotaSelection.account(for: card, in: [claude, openAI]))
    #expect(selection.provider == .openaiCodex)
    #expect(selection.account.accountKey == selectedAccount.accountKey)
}

@Test func conversationQuotaStaysHiddenWithoutAnExactProviderAccount() {
    var account = Dieter_Gateway_V1_ProviderQuotaSnapshot()
    account.accountKey = "available-account"

    var group = Dieter_Gateway_V1_ProviderQuotaGroup()
    group.provider = .openaiCodex
    group.accounts = [account]

    var card = Dieter_V1_Card()
    #expect(IOSProviderQuotaSelection.account(for: card, in: [group])?.account.accountKey == nil)

    card.providerAccountKey = "missing-account"
    #expect(IOSProviderQuotaSelection.account(for: card, in: [group])?.account.accountKey == nil)
}
