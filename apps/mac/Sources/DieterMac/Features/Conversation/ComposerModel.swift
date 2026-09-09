import DieterAPI
import DieterCore
import Foundation
import Observation

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
    private(set) var revision: UInt64 = 0
    private(set) var intakeGeneration: UInt64 = 0

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
            draft.comment.isEmpty, !draft.sending
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
