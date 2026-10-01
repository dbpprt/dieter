import DieterAPI
import DieterCore
import Foundation

/// One latest activity per conversation, not a run history; the shared core classifies it.
enum InboxActivityKind: Int, Equatable {
    case running, answer, unread, review, failed, recent

    var label: String {
        switch self {
        case .unread: "Unread reply"
        case .answer: "Answer"
        case .running: "Running"
        case .review: "Review"
        case .failed: "Failed"
        case .recent: "Recent"
        }
    }
}

struct InboxActivityEntry: Identifiable, Equatable {
    let card: Dieter_V1_Card
    let kind: InboxActivityKind
    let at: Date?
    let start: Date?
    let detail: String

    var id: String { card.id }
    var needsYou: Bool { kind == .answer || kind == .unread }
    var running: Bool { kind == .running }
    var canFinish: Bool { card.scope != "chat" && card.lane == "review" && !running && kind != .answer }
}

struct InboxActivityInterval: Identifiable {
    let entry: InboxActivityEntry
    let from: Double
    let to: Double
    let point: Bool
    var id: String { entry.id }
}

enum InboxActivity {
    static func timeline(entries: [InboxActivityEntry], now: Date, hours: Int) -> [InboxActivityInterval] {
        precondition([1, 6, 24].contains(hours))
        let duration = Double(hours * 3600)
        let window = now.addingTimeInterval(-duration)
        func fraction(_ date: Date) -> Double { min(1, max(0, date.timeIntervalSince(window) / duration)) }
        return entries.compactMap { entry in
            guard let end = entry.running ? now : entry.at else { return nil }
            let start = entry.start ?? end
            guard end >= window, start <= now else { return nil }
            return InboxActivityInterval(
                entry: entry, from: fraction(start), to: fraction(end), point: entry.start == nil)
        }.sorted {
            if $0.entry.at != $1.entry.at { return ($0.entry.at ?? .distantPast) > ($1.entry.at ?? .distantPast) }
            return $0.id < $1.id
        }
    }

    static func age(_ date: Date?, now: Date) -> String {
        guard let date else { return "Time unavailable" }
        let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
        if minutes < 1 { return "Just now" }
        if minutes < 60 { return "\(minutes)m" }
        if minutes < 1440 { return "\(minutes / 60)h" }
        return "\(minutes / 1440)d"
    }
}

extension InboxActivityKind {
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

extension DieterStore {
    /// One latest activity per conversation, as the shared core classifies it.
    var inboxEntries: [InboxActivityEntry] {
        activityRows.compactMap { row in
            guard let kind = InboxActivityKind(core: row.kind) else { return nil }
            func date(_ millis: Int64) -> Date? {
                millis > 0 ? Date(timeIntervalSince1970: Double(millis) / 1_000) : nil
            }
            return InboxActivityEntry(
                card: row.card, kind: kind, at: date(row.atMillis), start: date(row.startedAtMillis), detail: row.detail
            )
        }
    }
}
