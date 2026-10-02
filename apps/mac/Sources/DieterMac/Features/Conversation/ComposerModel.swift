import DieterAPI
import Foundation
import Observation

/// A conversation keeps its own draft across navigation. Async intake and send
/// completions retain this object rather than resolving the selected
/// conversation. The agent a send uses is the core's composer choice.
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
    var sending = false
    private(set) var pendingQueueMessageIDs: Set<String> = []
    private(set) var revision: UInt64 = 0
    private(set) var intakeGeneration: UInt64 = 0
    private var onTextChange: ((String) -> Void)?

    init(text: String = "", onTextChange: ((String) -> Void)? = nil) {
        self.text = text
        self.onTextChange = onTextChange
    }

    func observeTextChanges(_ callback: ((String) -> Void)?) {
        onTextChange = callback
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
    @ObservationIgnored private let store: DraftTextStore?

    /// `store` keeps unsent text between launches; without one, drafts live
    /// only as long as this model.
    init(store: DraftTextStore? = nil) {
        self.store = store
    }

    func select(_ target: WorkspaceTarget?) {
        guard self.target != target else { return }
        if let previous = self.target, draft.text.isEmpty, draft.attachments.isEmpty,
            !draft.sending, draft.pendingQueueMessageIDs.isEmpty
        {
            drafts.removeValue(forKey: previous)
        }
        self.target = target
        guard let target else { draft = ConversationDraft(); return }
        if let existing = drafts[target] {
            draft = existing
        } else {
            let value = makeDraft(for: target)
            drafts[target] = value; draft = value
        }
    }

    /// Fills drafts opened before the saved text arrived, unless typed in.
    func adoptSavedTexts() {
        for (target, existing) in drafts where existing.revision == 0 && existing.text.isEmpty {
            let saved = store?.text(for: target) ?? ""
            guard !saved.isEmpty else { continue }
            let value = makeDraft(for: target)
            drafts[target] = value
            if self.target == target { draft = value }
        }
    }

    func retarget(from old: WorkspaceTarget, to new: WorkspaceTarget) {
        guard let value = drafts.removeValue(forKey: old) else { return }
        store?.retarget(from: old, to: new)
        let store = store
        value.observeTextChanges { store?.update($0, for: new) }
        drafts[new] = value
        if target == old { target = new; draft = value }
    }

    private func makeDraft(for target: WorkspaceTarget) -> ConversationDraft {
        let store = store
        return ConversationDraft(text: store?.text(for: target) ?? "", onTextChange: { store?.update($0, for: target) })
    }
}
