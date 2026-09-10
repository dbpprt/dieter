import DieterAPI
import DieterCore
import Foundation
import Observation

enum ConversationSelectionPolicy {
    static func canChange(_ capability: String, harness: Dieter_V1_Harness?, conversationLocked: Bool) -> Bool {
        !conversationLocked
            || harness?.capabilities.contains { $0.id == capability && $0.level == "between-turns" } == true
    }
}

/// A conversation keeps its own draft across navigation. Async intake and send
/// completions retain this object rather than resolving the selected conversation.
@MainActor @Observable
final class ConversationDraft {
    var text = "" { didSet { if text != oldValue { revision &+= 1 } } }
    var attachments: [Dieter_V1_MessagePart] = [] { didSet { if attachments != oldValue { revision &+= 1 } } }
    var provider = ""
    var model = ""
    var effort = ""
    var providerOptions: [String: String] = [:]
    var comment = ""
    var sending = false
    private(set) var pendingQueueMessageIDs: Set<String> = []
    private(set) var revision: UInt64 = 0
    private(set) var intakeGeneration: UInt64 = 0
    private var savedSelection: HarnessSelection?

    var selection: HarnessSelection {
        get { HarnessSelection(provider: provider, model: model, effort: effort, providerOptions: providerOptions) }
        set {
            provider = newValue.provider; model = newValue.model; effort = newValue.effort
            providerOptions = newValue.providerOptions
        }
    }

    var hasPendingSettingsChanges: Bool {
        if let savedSelection { return selection != savedSelection }
        return !provider.isEmpty || !model.isEmpty || !effort.isEmpty || !providerOptions.isEmpty
    }

    /// Active-turn snapshots must not replace settings chosen for a later
    /// message. Once the card catches up, an empty draft can be released again.
    func reconcileSettings(card: Dieter_V1_Card, harness: Dieter_V1_Harness?) {
        let preserveSelection = hasPendingSettingsChanges
        let latest = HarnessSelection(
            provider: card.provider, model: card.model, effort: card.effort,
            providerOptions: harness == nil
                ? card.providerOptions
                : ProviderOptionValues.normalized(
                    for: harness, model: card.model, saved: card.providerOptions))
        savedSelection = latest
        if !preserveSelection || (!card.initialPromptSentAt.isEmpty && provider != latest.provider) {
            selection = latest
        }
    }

    func applySettings(to request: inout Dieter_V1_SendMessageRequest, fallback card: Dieter_V1_Card?) {
        request.provider = provider.isEmpty ? (card?.provider ?? "") : provider
        request.model = model.isEmpty ? (card?.model ?? "") : model
        // Empty effort is a valid model default. The explicit sentinel prevents
        // the daemon from inheriting an incompatible effort from the old model.
        request.effort =
            effort.isEmpty && !provider.isEmpty
            ? "default" : (effort.isEmpty ? (card?.effort ?? "") : effort)
        request.providerOptions = provider.isEmpty ? (card?.providerOptions ?? providerOptions) : providerOptions
    }

    func selectModel(_ value: Dieter_V1_HarnessModel, harness: Dieter_V1_Harness?, allowsEffortChange: Bool) {
        model = value.id
        if allowsEffortChange { effort = value.defaultEffort }
        providerOptions = ProviderOptionValues.normalized(for: harness, model: model, saved: providerOptions)
    }

    func restoreSettings(from message: Dieter_V1_QueuedMessage) {
        guard message.hasSelection else { return }
        let value = message.selection
        selection = HarnessSelection(
            provider: value.provider, model: value.model, effort: value.effort, providerOptions: value.providerOptions)
    }

    /// Retain this draft across the dequeue request: changing conversations
    /// must not discard the message once the daemon has removed it.
    func removeQueuedMessage(
        _ message: Dieter_V1_QueuedMessage,
        edit: Bool,
        remove: @MainActor (String) async throws -> Dieter_V1_QueuedMessage
    ) async throws -> Bool {
        guard !message.id.isEmpty, pendingQueueMessageIDs.isEmpty, !sending else { return false }
        pendingQueueMessageIDs.insert(message.id)
        defer { pendingQueueMessageIDs.remove(message.id) }
        let removed = try await remove(message.id)
        if edit {
            let restored = ConversationQueuePresentation.editableDraft(for: removed)
            restoreSettings(from: removed)
            text = [restored.text, text].filter { !$0.isEmpty }.joined(separator: "\n\n")
            attachments = restored.attachments + attachments
        }
        return true
    }

    func acceptSend(revision: UInt64) {
        intakeGeneration &+= 1
        guard self.revision == revision else { return }
        text = ""; attachments = []
    }
}

@MainActor @Observable
final class ComposerModel {
    private(set) var draft = ConversationDraft()
    @ObservationIgnored private var drafts: [WorkspaceTarget: ConversationDraft] = [:]
    @ObservationIgnored private var target: WorkspaceTarget?

    func select(_ target: WorkspaceTarget?) {
        guard self.target != target else { return }
        if let previous = self.target, draft.text.isEmpty, draft.attachments.isEmpty,
            draft.comment.isEmpty, !draft.sending, draft.pendingQueueMessageIDs.isEmpty,
            !draft.hasPendingSettingsChanges
        {
            drafts.removeValue(forKey: previous)
        }
        self.target = target
        guard let target else { draft = ConversationDraft(); return }
        if let existing = drafts[target] {
            draft = existing
        } else {
            let value = ConversationDraft(); drafts[target] = value; draft = value
        }
    }

    func retarget(from old: WorkspaceTarget, to new: WorkspaceTarget) {
        guard let value = drafts.removeValue(forKey: old) else { return }
        drafts[new] = value
        if target == old { target = new; draft = value }
    }
}
