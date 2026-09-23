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
    var text = "" {
        didSet {
            guard text != oldValue else { return }
            revision &+= 1
            onTextChange?(text)
        }
    }
    var attachments: [Dieter_V1_MessagePart] = [] { didSet { if attachments != oldValue { revision &+= 1 } } }
    var provider = ""
    var model = ""
    var effort = ""
    var providerOptions: [String: String] = [:]
    var sending = false
    private(set) var pendingQueueMessageIDs: Set<String> = []
    private(set) var revision: UInt64 = 0
    private(set) var intakeGeneration: UInt64 = 0
    private var savedSelection: HarnessSelection?
    private var onTextChange: ((String) -> Void)?

    init(text: String = "", onTextChange: ((String) -> Void)? = nil) {
        self.text = text
        self.onTextChange = onTextChange
    }

    func observeTextChanges(_ callback: ((String) -> Void)?) {
        onTextChange = callback
    }

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

@MainActor
private final class ConversationDraftTextPersistence {
    private struct StoredDraft: Codable {
        var target: WorkspaceTarget
        var text: String
        var updatedAt: Date
    }

    private struct Store: Codable {
        var version = 1
        var drafts: [StoredDraft]
    }

    private static let storageKey = "DieterConversationDraftTexts"
    private let defaults: UserDefaults
    private let maximumDrafts: Int
    private var drafts: [WorkspaceTarget: StoredDraft]

    init(defaults: UserDefaults, maximumDrafts: Int) {
        self.defaults = defaults
        self.maximumDrafts = maximumDrafts
        let stored = defaults.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode(Store.self, from: $0) }
        drafts = Dictionary(
            (stored?.drafts ?? []).filter { !$0.target.conversationID.isEmpty && !$0.text.isEmpty }
                .map { ($0.target, $0) },
            uniquingKeysWith: { first, second in first.updatedAt >= second.updatedAt ? first : second }
        )
        trimToBound()
    }

    func text(for target: WorkspaceTarget) -> String {
        drafts[target]?.text ?? ""
    }

    func update(_ text: String, for target: WorkspaceTarget) {
        if text.isEmpty {
            drafts.removeValue(forKey: target)
        } else {
            drafts[target] = StoredDraft(target: target, text: text, updatedAt: Date())
        }
        trimToBound()
        save()
    }

    func retarget(from old: WorkspaceTarget, to new: WorkspaceTarget) {
        guard var value = drafts.removeValue(forKey: old) else { return }
        value.target = new
        value.updatedAt = Date()
        drafts[new] = value
        trimToBound()
        save()
    }

    private func trimToBound() {
        guard drafts.count > maximumDrafts else { return }
        let retained = drafts.values.sorted { $0.updatedAt > $1.updatedAt }.prefix(maximumDrafts)
        drafts = Dictionary(retained.map { ($0.target, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func save() {
        guard !drafts.isEmpty else {
            defaults.removeObject(forKey: Self.storageKey)
            return
        }
        let value = Store(drafts: drafts.values.sorted { $0.updatedAt > $1.updatedAt })
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

@MainActor @Observable
final class ComposerModel {
    private(set) var draft = ConversationDraft()
    @ObservationIgnored private var drafts: [WorkspaceTarget: ConversationDraft] = [:]
    @ObservationIgnored private var target: WorkspaceTarget?
    @ObservationIgnored private var persistence: ConversationDraftTextPersistence?

    init(defaults: UserDefaults? = nil, maximumDrafts: Int = 64) {
        if let defaults {
            persistence = ConversationDraftTextPersistence(defaults: defaults, maximumDrafts: maximumDrafts)
        }
    }

    func select(_ target: WorkspaceTarget?) {
        guard self.target != target else { return }
        if let previous = self.target, draft.text.isEmpty, draft.attachments.isEmpty,
            !draft.sending, draft.pendingQueueMessageIDs.isEmpty,
            !draft.hasPendingSettingsChanges
        {
            drafts.removeValue(forKey: previous)
        }
        self.target = target
        guard let target else { draft = ConversationDraft(); return }
        if let existing = drafts[target] {
            draft = existing
        } else {
            let persistence = persistence
            let value = ConversationDraft(
                text: persistence?.text(for: target) ?? "",
                onTextChange: { persistence?.update($0, for: target) }
            )
            drafts[target] = value; draft = value
        }
    }

    func retarget(from old: WorkspaceTarget, to new: WorkspaceTarget) {
        guard let value = drafts.removeValue(forKey: old) else { return }
        persistence?.retarget(from: old, to: new)
        let persistence = persistence
        value.observeTextChanges { persistence?.update($0, for: new) }
        drafts[new] = value
        if target == old { target = new; draft = value }
    }
}
