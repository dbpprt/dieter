import DieterAPI
import DieterCore
import Foundation

/// Retains a bounded, contiguous tail. Paging prepends without replacing the
/// viewport's message IDs; live updates replace messages by their durable ID.
struct IOSTranscript {
    static let maximumMessages = 240
    private(set) var conversation: Dieter_V1_Conversation?
    private(set) var page = Dieter_V1_ConversationPage()

    mutating func reset(_ snapshot: Dieter_V1_ConversationSnapshot) {
        conversation = snapshot.conversation
        page = snapshot.page
        trim()
    }

    mutating func apply(_ update: Dieter_V1_ConversationUpdate) {
        if update.hasSnapshot { reset(update.snapshot); return }
        guard var current = conversation, update.lastSeq >= current.lastSeq else { return }
        let removed = Set(update.removedMessageIds)
        var messages = current.messages.filter { !removed.contains($0.id) }
        var indexes = Dictionary(
            messages.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        for message in update.changedMessages {
            if let index = indexes[message.id] {
                messages[index] = message
            } else {
                indexes[message.id] = messages.count; messages.append(message)
            }
        }
        current.messages = messages
        current.status = update.status
        current.pendingTools = update.pendingTools
        current.queue = update.queue
        current.lastSeq = update.lastSeq
        current.updatedAt = update.updatedAt
        current.subagents = update.subagents
        current.taskPlans = update.taskPlans
        current.draftAttachments = update.draftAttachments
        current.presentedContent = update.presentedContent
        conversation = current
        if update.hasPage {
            page = update.page
            page.start = max(0, page.end - Int32(messages.count))
            page.hasMore_p = page.start > 0
        }
        trim()
    }

    @discardableResult
    mutating func prepend(_ snapshot: Dieter_V1_ConversationSnapshot, expectedSequence: Int64) -> Bool {
        guard var current = conversation, current.lastSeq == expectedSequence,
            snapshot.conversation.cardID == current.cardID, snapshot.page.end == page.start
        else { return false }
        let currentIDs = Set(current.messages.map(\.id))
        current.messages = snapshot.conversation.messages.filter { !currentIDs.contains($0.id) } + current.messages
        conversation = current
        page.start = snapshot.page.start
        page.hasMore_p = page.start > 0
        trim()
        return true
    }

    @discardableResult
    mutating func trimToLatest() -> Bool {
        guard var current = conversation, current.messages.count > 60 else { return false }
        current.messages = Array(current.messages.suffix(60))
        conversation = current
        page.start = max(0, page.end - Int32(current.messages.count))
        page.hasMore_p = page.start > 0
        return true
    }

    private mutating func trim() {
        guard var current = conversation, current.messages.count > Self.maximumMessages else { return }
        current.messages = Array(current.messages.suffix(Self.maximumMessages))
        conversation = current
        page.start = max(0, page.end - Int32(current.messages.count))
        page.hasMore_p = page.start > 0
    }
}

/// A response may update the UI only while both the remote node and navigation
/// request still belong to the initiating operation.
struct IOSRequestScope: Equatable {
    let connection: UUID
    let selection: UUID

    func accepts(connection: UUID, selection: UUID, active: Bool) -> Bool {
        active && self.connection == connection && self.selection == selection
    }
}

/// Retrying an uncertain mutation keeps its command identity until that exact
/// operation is acknowledged. Field boundaries are preserved, including pipes
/// or newlines typed by the user, and a different node cannot reuse the command.
struct IOSMutationIdentity {
    private var fields: [String]?
    private var id: String?

    mutating func command(for fields: [String]) -> String {
        if self.fields == fields, let id { return id }
        let value = UUID().uuidString.lowercased()
        self.fields = fields
        id = value
        return value
    }

    mutating func acknowledge(command: String) {
        guard id == command else { return }
        fields = nil
        id = nil
    }
}

enum IOSMachinePolicy {
    static let apiVersion = "3"

    static func isCompatible(_ machine: DieterEndpoint) -> Bool {
        machine.apiVersion.isEmpty || machine.apiVersion == apiVersion
    }

    static func preferred(in machines: [DieterEndpoint], preferredID: String?) -> DieterEndpoint? {
        let available = machines.filter { $0.online && isCompatible($0) }
        return available.first { $0.daemonID == preferredID } ?? available.first
    }

    static func isLoopbackTestEndpoint(_ endpoint: DieterEndpoint) -> Bool {
        let host = endpoint.host.lowercased()
        if host == "localhost" || host == "::1" { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.first == "127"
            && parts.allSatisfy { part in
                guard !part.isEmpty, part.allSatisfy(\.isNumber), let value = UInt8(part) else { return false }
                return String(value) == part
            }
    }
}
