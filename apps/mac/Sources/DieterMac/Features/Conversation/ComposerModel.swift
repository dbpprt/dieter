import DieterAPI
import Foundation
import Observation
import SharedCore

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
