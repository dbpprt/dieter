import DieterAPI
import Testing
@testable import DieterCore

private func providerStatus(_ state: String, attempt: Int32 = 0, maxAttempts: Int32 = 0) -> Dieter_V1_ProviderStatus {
    var status = Dieter_V1_ProviderStatus()
    status.state = state
    status.attempt = attempt
    status.maxAttempts = maxAttempts
    status.message = "Reconnecting... (stream disconnected before completion)"
    return status
}

@Test func providerRetryStatesUseOneSharedLabel() {
    #expect(
        ProviderStatusPresentation.label(providerStatus("reconnecting", attempt: 2, maxAttempts: 5))
            == "Reconnecting to provider (2/5)…")
    #expect(ProviderStatusPresentation.label(providerStatus("reconnecting")) == "Reconnecting to provider…")
    #expect(
        ProviderStatusPresentation.label(providerStatus("waiting-for-network"))
            == "Reconnecting to provider (waiting for network)…")
    #expect(ProviderStatusPresentation.label(providerStatus("future-state")) == nil)
}

@Test func conversationUpdateWithoutProviderStatusClearsIt() {
    var conversation = Dieter_V1_Conversation()
    #expect(conversation.activeProviderStatus == nil)
    var update = Dieter_V1_ConversationUpdate()
    update.providerStatus = providerStatus("reconnecting", attempt: 1, maxAttempts: 5)
    conversation.applyProviderStatus(from: update)
    #expect(conversation.activeProviderStatus?.attempt == 1)
    // The stream recovered: the daemon's next update omits the status.
    conversation.applyProviderStatus(from: Dieter_V1_ConversationUpdate())
    #expect(!conversation.hasProviderStatus)
    #expect(conversation.activeProviderStatus == nil)
}
