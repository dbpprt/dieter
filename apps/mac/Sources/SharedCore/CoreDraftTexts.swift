import DieterAPI
import Foundation

/// Where unsent draft text lives between launches.
@MainActor
package protocol DraftTextStore: AnyObject {
    func text(for target: WorkspaceTarget) -> String
    func update(_ text: String, for target: WorkspaceTarget)
    func retarget(from old: WorkspaceTarget, to new: WorkspaceTarget)
}

/// Draft text kept by the shared core on this device, per conversation on
/// the machine that holds it. Every saved draft is loaded once so composers
/// open without waiting; typing is saved in short batches.
@MainActor
package final class CoreDraftTexts: DraftTextStore {
    private struct Key: Hashable {
        let daemonID: String
        let cardID: String
    }

    private let core: CoreClient
    private var texts: [Key: String] = [:]
    private var unsaved: [Key: String] = [:]
    private var saving: Task<Void, Never>?
    package private(set) var loaded = false

    package init(core: CoreClient) {
        self.core = core
    }

    /// The core keys drafts by daemon.
    private static func key(_ target: WorkspaceTarget) -> Key {
        Key(daemonID: target.daemonID, cardID: target.conversationID)
    }

    /// Loads every saved draft; text typed before it arrived wins.
    package func load() async {
        guard let result = try? await core.dispatch({ $0.listDrafts = ClientListDrafts() }) else { return }
        for draft in result.drafts.drafts {
            let key = Key(daemonID: draft.daemonID, cardID: draft.cardID)
            if unsaved[key] == nil, texts[key] == nil { texts[key] = draft.text }
        }
        loaded = true
    }

    package func text(for target: WorkspaceTarget) -> String {
        texts[Self.key(target)] ?? ""
    }

    package func update(_ text: String, for target: WorkspaceTarget) {
        let key = Self.key(target)
        guard !key.cardID.isEmpty else { return }
        texts[key] = text.isEmpty ? nil : text
        unsaved[key] = text
        scheduleSave()
    }

    /// The core moves a created conversation's draft to its server ID itself.
    package func retarget(from old: WorkspaceTarget, to new: WorkspaceTarget) {
        let from = Self.key(old), to = Self.key(new)
        guard from != to, let text = texts.removeValue(forKey: from) else { return }
        texts[to] = text
    }

    /// Saves what was typed since the last save now.
    package func save() async {
        saving?.cancel()
        saving = nil
        let batch = unsaved
        unsaved = [:]
        for (key, text) in batch {
            _ = try? await core.dispatch {
                $0.setDraftText = .with {
                    $0.daemonID = key.daemonID
                    $0.cardID = key.cardID
                    $0.text = text
                }
            }
        }
    }

    private func scheduleSave() {
        guard saving == nil else { return }
        saving = Task { [weak self] in
            try? await DieterTaskSleep.milliseconds(250)
            guard !Task.isCancelled, let self else { return }
            self.saving = nil
            await self.save()
        }
    }
}
