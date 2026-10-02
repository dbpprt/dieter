import DieterAPI
import Foundation

/// The core's activity kind, which picks a row's colour and symbol.
enum InboxActivityKind: Int, Equatable {
    case running, answer, unread, review, failed, recent

    /// The core's activity kind, by name.
    init?(core name: String) {
        switch name {
        case "ANSWER": self = .answer
        case "RUNNING": self = .running
        case "UNREAD": self = .unread
        case "REVIEW": self = .review
        case "FAILED": self = .failed
        case "RECENT": self = .recent
        default: return nil
        }
    }
}

/// One latest activity per conversation, not a run history, as the shared
/// core classifies and words it.
struct InboxActivityEntry: Identifiable, Equatable {
    let row: ClientActivityRow
    let kind: InboxActivityKind

    var id: String { row.card.id }
    var card: Dieter_V1_Card { row.card }
    var running: Bool { kind == .running }
    var needsYou: Bool { row.needsYou }
    var canFinish: Bool { row.canFinish }
    var section: ClientActivityRow.Section { row.section }
}

extension DieterStore {
    /// One latest activity per conversation, as the shared core classifies it.
    var inboxEntries: [InboxActivityEntry] {
        activity.rows.compactMap { row in
            InboxActivityKind(core: row.kind).map { InboxActivityEntry(row: row, kind: $0) }
        }
    }
}
