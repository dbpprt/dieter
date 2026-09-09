import DieterAPI
@testable import DieterMac
import Testing

struct ProviderOptionTests {
    @Test func modelScopedOptionsOnlyAppearForSupportedModels() {
        var fastMode = Dieter_V1_ProviderOption()
        fastMode.id = "fast_mode"
        fastMode.defaultValue = "false"
        fastMode.models = ["gpt-5.6-sol"]
        var harness = Dieter_V1_Harness()
        harness.defaultModel = "gpt-5.6-sol"
        harness.options = [fastMode]

        #expect(ProviderOptionValues.options(for: harness, model: "gpt-5.6-sol").map(\.id) == ["fast_mode"])
        #expect(
            ProviderOptionValues.normalized(
                for: harness,
                model: "gpt-5.6-sol",
                saved: ["fast_mode": "true"]
            ) == ["fast_mode": "true"])
        #expect(ProviderOptionValues.options(for: harness, model: "gpt-5.3-codex-spark").isEmpty)
        #expect(
            ProviderOptionValues.normalized(
                for: harness,
                model: "gpt-5.3-codex-spark",
                saved: ["fast_mode": "true"]
            ).isEmpty)
    }

    @Test func onlyMutableOptionsRemainEnabledAfterConversationStarts() {
        var fastMode = Dieter_V1_ProviderOption()
        fastMode.id = "fast_mode"
        fastMode.mutable = true
        var sessionMode = Dieter_V1_ProviderOption()
        sessionMode.id = "session_mode"

        #expect(ProviderOptionValues.isEnabled(fastMode, conversationLocked: true))
        #expect(!ProviderOptionValues.isEnabled(sessionMode, conversationLocked: true))
        #expect(ProviderOptionValues.isEnabled(sessionMode, conversationLocked: false))
    }
}
