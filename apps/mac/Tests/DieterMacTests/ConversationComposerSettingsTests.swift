import DieterAPI
import DieterCore
import Foundation
import Testing
@testable import DieterMac

private func settingsCard() -> Dieter_V1_Card {
    var card = Dieter_V1_Card()
    card.id = "card-settings"; card.provider = "codex"; card.model = "model-a"; card.effort = "high"
    card.providerOptions = ["fast_mode": "false"]
    card.initialPromptSentAt = "2026-09-10T12:00:00Z"
    return card
}

@Test @MainActor func composerSettingsSurviveActiveSnapshotsAndNavigationUntilAdmitted() {
    let model = ComposerModel()
    let first = WorkspaceTarget(endpointID: "machine", projectID: "", conversationID: "first")
    let second = WorkspaceTarget(endpointID: "machine", projectID: "", conversationID: "second")
    var card = settingsCard()
    model.select(first)
    let draft = model.draft
    draft.reconcileSettings(card: card, harness: nil)
    #expect(!draft.hasPendingSettingsChanges)
    draft.model = "model-b"; draft.effort = "low"; draft.providerOptions = ["fast_mode": "true"]

    draft.reconcileSettings(card: card, harness: nil)
    model.select(second); model.select(first)
    #expect(model.draft === draft)
    #expect(draft.model == "model-b" && draft.effort == "low")
    #expect(draft.providerOptions["fast_mode"] == "true")

    card.model = "model-b"; card.effort = "low"; card.providerOptions = ["fast_mode": "true"]
    draft.reconcileSettings(card: card, harness: nil)
    #expect(!draft.hasPendingSettingsChanges)
    model.select(second); model.select(first)
    #expect(model.draft !== draft)
}

@Test @MainActor func composerCleanSettingsFollowRemoteChangesWithoutReplacingPendingChoices() {
    let draft = ConversationDraft()
    var card = settingsCard()
    draft.reconcileSettings(card: card, harness: nil)
    card.model = "model-b"; card.effort = "low"
    draft.reconcileSettings(card: card, harness: nil)
    #expect(draft.model == "model-b" && draft.effort == "low")
    draft.effort = "high"
    card.effort = "medium"
    draft.reconcileSettings(card: card, harness: nil)
    #expect(draft.effort == "high" && draft.hasPendingSettingsChanges)
}

@Test @MainActor func composerAcceptedMessageKeepsNextMessageSettingsAndImmutableRequest() {
    let draft = ConversationDraft()
    let card = settingsCard()
    draft.reconcileSettings(card: card, harness: nil)
    draft.model = "model-b"; draft.effort = ""; draft.providerOptions = ["fast_mode": "true"]
    draft.text = "Use the new model"
    var request = Dieter_V1_SendMessageRequest()
    draft.applySettings(to: &request, fallback: card)
    draft.acceptSend(revision: draft.revision)
    draft.reconcileSettings(card: card, harness: nil)
    #expect(draft.text.isEmpty && draft.model == "model-b" && draft.effort.isEmpty)
    #expect(request.provider == "codex" && request.model == "model-b" && request.effort == "default")
    #expect(request.providerOptions["fast_mode"] == "true")
    draft.model = "model-c"; draft.providerOptions["fast_mode"] = "false"
    #expect(request.model == "model-b" && request.providerOptions["fast_mode"] == "true")
}

@Test @MainActor func composerOutboxCapturesSettingsForChatAndCardMessages() async throws {
    for chat in [false, true] {
        let root = FileManager.default.temporaryDirectory.appending(path: "dieter-settings-outbox-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let outbox = DurableOutbox(
            journal: OutboxJournal(
                url: root.appending(path: "pending.json"), legacyURL: root.appending(path: "legacy.json")))
        let store = DieterStore(outboxOverride: outbox, restoreSync: false)
        let card = settingsCard()
        if chat { store.selectedChatID = card.id } else { store.selectedCardID = card.id }
        var detail = Dieter_V1_CardDetail(); detail.card = card
        store.selectedDetail = detail
        store.composer.draft.reconcileSettings(card: card, harness: nil)
        store.composerModel = "model-b"; store.composerEffort = "low"
        store.composerProviderOptions = ["fast_mode": "true"]
        store.composerText = "Next turn"
        await store.sendComposer()
        let entry = try #require(outbox.entries.first)
        let request = try Dieter_V1_SendMessageRequest(serializedBytes: entry.request)
        #expect(request.cardID == card.id && request.provider == "codex")
        #expect(request.model == "model-b" && request.effort == "low")
        #expect(request.providerOptions["fast_mode"] == "true")
        #expect(store.composerText.isEmpty && store.composerModel == "model-b")
        store.outboxTask?.cancel()
    }
}

@Test @MainActor func composerModelChangesDropUnsupportedFastModeAndPreserveLockedEffort() {
    let draft = ConversationDraft()
    var harness = Dieter_V1_Harness(); harness.id = "codex"
    var option = Dieter_V1_ProviderOption()
    option.id = "fast_mode"; option.type = "bool"; option.defaultValue = "false"; option.models = ["model-a"]
    harness.options = [option]
    draft.reconcileSettings(card: settingsCard(), harness: harness)
    draft.providerOptions["fast_mode"] = "true"
    var next = Dieter_V1_HarnessModel(); next.id = "model-b"; next.defaultEffort = ""
    draft.selectModel(next, harness: harness, allowsEffortChange: true)
    #expect(draft.effort.isEmpty && draft.providerOptions["fast_mode"] == nil)
    draft.effort = "high"; next.defaultEffort = "low"
    draft.selectModel(next, harness: harness, allowsEffortChange: false)
    #expect(draft.effort == "high")
}

@Test @MainActor func composerQueueEditingRestoresThatMessagesSelection() {
    let draft = ConversationDraft()
    draft.reconcileSettings(card: settingsCard(), harness: nil)
    var queued = Dieter_V1_QueuedMessage()
    queued.selection.provider = "codex"; queued.selection.model = "queued-model"
    queued.selection.effort = "low"; queued.selection.providerOptions = ["fast_mode": "true"]
    draft.restoreSettings(from: queued)
    #expect(draft.model == "queued-model" && draft.effort == "low")
    #expect(draft.providerOptions["fast_mode"] == "true")
    // Old daemons have no settings snapshot; editing still preserves the
    // currently selected configuration instead of replacing it with blanks.
    draft.restoreSettings(from: Dieter_V1_QueuedMessage())
    #expect(draft.model == "queued-model" && draft.providerOptions["fast_mode"] == "true")
}

@Test func composerSelectionRespectsAdvertisedProviderCapabilities() {
    var harness = Dieter_V1_Harness()
    #expect(ConversationSelectionPolicy.canChange("model-selection", harness: harness, conversationLocked: false))
    #expect(!ConversationSelectionPolicy.canChange("model-selection", harness: harness, conversationLocked: true))
    var capability = Dieter_V1_HarnessCapability(); capability.id = "model-selection";
    capability.level = "between-turns"
    harness.capabilities = [capability]
    #expect(ConversationSelectionPolicy.canChange("model-selection", harness: harness, conversationLocked: true))
    #expect(!ConversationSelectionPolicy.canChange("effort-selection", harness: harness, conversationLocked: true))
    capability.id = "effort-selection"; harness.capabilities.append(capability)
    #expect(ConversationSelectionPolicy.canChange("effort-selection", harness: harness, conversationLocked: true))
}
