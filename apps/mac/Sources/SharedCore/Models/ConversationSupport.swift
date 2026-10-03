import DieterAPI
import DieterShared
import Foundation
import Observation

/// A conversation's loaded messages, keyed as the core's timeline steps name
/// them: by ID, else "position:<index>".
package struct ConversationMessages: Equatable, Sendable {
    package private(set) var byKey: [String: Dieter_V1_UiMessage] = [:]

    package init(_ messages: [Dieter_V1_UiMessage] = []) {
        for (index, message) in messages.enumerated() {
            byKey[message.id.isEmpty ? "position:\(index)" : message.id] = message
        }
    }

    /// The message a timeline step renders.
    package func message(for step: ClientTimelineStep) -> Dieter_V1_UiMessage? {
        if !step.messageID.isEmpty, let message = byKey[step.messageID] { return message }
        let key = step.id.components(separatedBy: ":part:").first ?? ""
        return byKey[key]
    }

    /// The part a timeline step renders: its message's part, with coalesced prose as its text.
    package func part(for step: ClientTimelineStep) -> Dieter_V1_MessagePart? {
        guard let message = message(for: step), message.parts.indices.contains(Int(step.partIndex)) else {
            return nil
        }
        var part = message.parts[Int(step.partIndex)]
        if !step.text.isEmpty { part.text = step.text }
        return part
    }

    /// What a row's "copy message" action copies, as the core words it.
    package func copyText(_ row: ClientTimelineItem) -> String {
        let messages = ClientTimelineMessages.with { value in
            value.messages = row.messageIds.compactMap { byKey[$0] }
        }
        return SharedRules.shared.doCopyText(messages: messages.rulesData)
    }
}

extension Dieter_V1_Conversation {
    /// The task plans a row shows, at their latest revision.
    package func taskPlans(ids: [String]) -> [Dieter_V1_TaskPlan] {
        guard !ids.isEmpty else { return [] }
        return ids.compactMap { id in taskPlans.filter { $0.id == id }.max { $0.revision < $1.revision } }
    }

    /// The delegated agents a row shows, in the row's order.
    package func subagents(ids: [String]) -> [Dieter_V1_Subagent] {
        guard !ids.isEmpty else { return [] }
        return ids.compactMap { id in subagents.first { $0.id == id } }
    }
}

/// History paging: a page command, then waiting for the update that carries
/// it, so the view can keep its reading position across the new messages.
@MainActor
package enum ConversationPaging {
    /// Sends `command` and, once the core loaded a page, waits up to two
    /// seconds until `arrived` sees it folded while `current` still holds.
    package static func load(
        _ command: ClientCommand, core: CoreClient, current: () -> Bool = { true }, arrived: () -> Bool
    ) async throws -> Bool {
        let result = try await core.dispatch(command)
        guard result.pageLoaded.loaded, current() else { return false }
        let deadline = ContinuousClock.now + .seconds(2)
        while current(), !arrived(), ContinuousClock.now < deadline {
            try await DieterTaskSleep.milliseconds(16)
        }
        return current()
    }
}

/// A conversation's composer draft, kept across navigation. Async intake and
/// send completions retain this object rather than resolving the selected
/// conversation. The agent a send uses is the core's composer choice.
@MainActor
@Observable
package final class ConversationDraft {
    package var text = "" {
        didSet {
            guard text != oldValue else { return }
            revision &+= 1
            onTextChange?(text)
        }
    }
    package var attachments: [Dieter_V1_MessagePart] = [] {
        didSet { if attachments != oldValue { revision &+= 1 } }
    }
    package var sending = false
    package private(set) var pendingQueueMessageIDs: Set<String> = []
    /// Advances with every text or attachment change, so a send clears only what it sent.
    package private(set) var revision: UInt64 = 0
    package private(set) var intakeGeneration: UInt64 = 0
    @ObservationIgnored private var onTextChange: ((String) -> Void)?

    package init(text: String = "", onTextChange: ((String) -> Void)? = nil) {
        self.text = text
        self.onTextChange = onTextChange
    }

    /// Whether the composer holds something to send.
    package var hasContent: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    package func observeTextChanges(_ callback: ((String) -> Void)?) {
        onTextChange = callback
    }

    /// Fills an untouched draft with saved text, without counting as an edit.
    package func adopt(saved: String) {
        guard revision == 0, text.isEmpty, !saved.isEmpty else { return }
        let callback = onTextChange
        onTextChange = nil
        text = saved
        revision = 0
        onTextChange = callback
    }

    /// Removes a queued message through `remove`; editing brings its text and
    /// attachments back ahead of the draft, as the core restores them. The
    /// draft is retained across the request, so changing conversations does
    /// not lose a message the machine already removed.
    package func removeQueuedMessage(
        _ message: Dieter_V1_QueuedMessage, edit: Bool,
        remove: @MainActor (String) async throws -> Dieter_V1_QueuedMessage
    ) async throws -> Bool {
        guard !message.id.isEmpty, pendingQueueMessageIDs.isEmpty, !sending else { return false }
        pendingQueueMessageIDs.insert(message.id)
        defer { pendingQueueMessageIDs.remove(message.id) }
        let removed = try await remove(message.id)
        if edit {
            let restored = Dieter_V1_QueuedMessage(
                rules: SharedRules.shared.restoredDraft(message: removed.rulesData, currentText: text))
            text = restored.text
            attachments = restored.parts + attachments
        }
        return true
    }

    /// Sends the draft through `send`, which receives its text and
    /// attachments; the draft clears unless it changed while sending.
    package func send(
        _ send: @MainActor (_ text: String, _ attachments: [Dieter_V1_MessagePart]) async throws -> Void
    ) async throws {
        guard hasContent, !sending else { return }
        sending = true
        defer { sending = false }
        let revision = revision
        try await send(text, attachments)
        acceptSend(revision: revision)
    }

    package func acceptSend(revision: UInt64) {
        intakeGeneration &+= 1
        guard self.revision == revision else { return }
        text = ""
        attachments = []
    }
}
