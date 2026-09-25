import DieterAPI
import Foundation

/// Mirrors Android ActivityModel: one latest activity per conversation, not a run history.
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

struct InboxActivityDetail: Equatable {
    let runtimeUpdatedAt: String
    let start: Date?
    let label: String
}

struct InboxActivityInterval: Identifiable {
    let entry: InboxActivityEntry
    let from: Double
    let to: Double
    let point: Bool
    var id: String { entry.id }
}

enum InboxActivity {
    static func entries(
        cards: [Dieter_V1_Card], details: [String: InboxActivityDetail] = [:], excludedIDs: Set<String> = []
    ) -> [InboxActivityEntry] {
        var freshest: [String: (card: Dieter_V1_Card, date: Date)] = [:]
        for card in cards where !card.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let date =
                [card.updatedAt, card.runtimeUpdatedAt, card.lastActivityAt]
                .compactMap(DieterTimestamp.date(from:)).max() ?? .distantPast
            // Equal timestamps prefer the later source (selected-project optimistic metadata).
            if freshest[card.id].map({ date >= $0.date }) ?? true { freshest[card.id] = (card, date) }
        }
        return freshest.values.compactMap { value -> InboxActivityEntry? in
            let card = value.card
            guard !card.archived, !excludedIDs.contains(card.id) else { return nil }
            let runtime = card.runtime.lowercased()
            let active = ConversationActivityPresentation.isActive(conversationStatus: "", cardRuntime: runtime)
            let kind: InboxActivityKind
            if runtime == "waiting_for_user" {
                kind = .answer
            } else if active {
                kind = .running
            } else if card.responseSeq > card.seenResponseSeq {
                kind = .unread
            } else if card.scope != "chat", card.lane == "review" {
                kind = .review
            } else if runtime == "failed" {
                kind = .failed
            } else if !runtime.isEmpty, runtime != "pending", !card.initialPromptSentAt.isEmpty,
                !card.runtimeUpdatedAt.isEmpty
            {
                kind = .recent
            } else {
                return nil
            }
            let at =
                DieterTimestamp.date(from: card.runtimeUpdatedAt)
                ?? DieterTimestamp.date(from: card.lastActivityAt)
                ?? DieterTimestamp.date(from: card.phaseChangedAt)
            let cached = details[card.id].flatMap { $0.runtimeUpdatedAt == card.runtimeUpdatedAt ? $0 : nil }
            let recordedStart = cached?.start.flatMap { start in at.map { start <= $0 ? start : nil } ?? nil }
            let start = recordedStart ?? (active ? DieterTimestamp.date(from: card.runtimeUpdatedAt) : nil)
            let detail: String
            if runtime == "cancelling" {
                detail = "Stopping…"
            } else if active {
                if let label = cached?.label, !label.isEmpty {
                    detail = label
                } else {
                    detail = card.summary.isEmpty ? "Working on your request" : card.summary
                }
            } else if kind == .unread {
                detail = "New reply"
            } else if kind == .answer {
                detail = "Waiting for your answer"
            } else if kind == .review {
                detail = "Ready for review"
            } else if kind == .failed {
                detail = "Agent failed"
            } else if ["cancelled", "canceled", "stopped", "interrupted"].contains(runtime) {
                detail = "Stopped"
            } else {
                detail = card.scope == "chat" ? "Replied" : "Finished"
            }
            return InboxActivityEntry(card: card, kind: kind, at: at, start: start, detail: detail)
        }.sorted {
            if $0.kind != $1.kind { return $0.kind.rawValue < $1.kind.rawValue }
            if $0.at != $1.at { return ($0.at ?? .distantPast) > ($1.at ?? .distantPast) }
            return $0.id < $1.id
        }
    }

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

/// Only the already bounded in-memory snapshot cache is inspected. No transcript
/// fetches, disk decoding, or history pages are performed by the Inbox.
@MainActor
final class InboxActivityProjection {
    private var snapshots: [String: Dieter_V1_ConversationSnapshot] = [:]
    private var details: [String: InboxActivityDetail] = [:]
    private var cards: [Dieter_V1_Card] = []
    private var excludedIDs: Set<String> = []
    private var omittedMessageIDs: Set<String> = []
    private var showReasoning = true
    private var projected: [InboxActivityEntry] = []

    func resolve(
        cards nextCards: [Dieter_V1_Card], snapshots incoming: [Dieter_V1_ConversationSnapshot],
        excludedIDs nextExcludedIDs: Set<String>, omittedMessageIDs nextOmittedMessageIDs: Set<String>,
        showReasoning nextShowReasoning: Bool
    ) -> [InboxActivityEntry] {
        var nextSnapshots: [String: Dieter_V1_ConversationSnapshot] = [:]
        for snapshot in incoming.suffix(cachedConversationLimit + 1) where !snapshot.detail.card.id.isEmpty {
            nextSnapshots[snapshot.detail.card.id] = snapshot
        }
        let preferencesChanged = showReasoning != nextShowReasoning || omittedMessageIDs != nextOmittedMessageIDs
        var nextDetails: [String: InboxActivityDetail] = [:]
        for (id, snapshot) in nextSnapshots {
            if !preferencesChanged, snapshots[id] == snapshot, let detail = details[id] {
                nextDetails[id] = detail
                continue
            }
            let conversation = snapshot.conversation
            let queuedIDs = Set(conversation.queue.map(\.id)).union(nextOmittedMessageIDs)
            let messages = conversation.messages.filter { !queuedIDs.contains($0.id) }
            nextDetails[id] = InboxActivityDetail(
                runtimeUpdatedAt: snapshot.detail.card.runtimeUpdatedAt,
                start: ConversationActivityPresentation.turnStart(messages: messages, runtimeUpdatedAt: ""),
                label: ConversationActivityPresentation.liveLabel(
                    messages: messages, pendingTools: conversation.pendingTools, plans: conversation.taskPlans,
                    showReasoning: nextShowReasoning, conversationStatus: conversation.status,
                    cardRuntime: snapshot.detail.card.runtime))
        }
        snapshots = nextSnapshots
        omittedMessageIDs = nextOmittedMessageIDs
        showReasoning = nextShowReasoning
        if cards != nextCards || details != nextDetails || excludedIDs != nextExcludedIDs {
            cards = nextCards
            details = nextDetails
            excludedIDs = nextExcludedIDs
            projected = InboxActivity.entries(cards: nextCards, details: nextDetails, excludedIDs: nextExcludedIDs)
        }
        return projected
    }
}

extension DieterStore {
    var inboxEntries: [InboxActivityEntry] {
        // Source order is stable for ties; newest timestamp wins before filtering archived copies.
        let cards =
            navigationCards.keys.sorted().flatMap { navigationCards[$0] ?? [] }
            + chats + state.cards + state.chats
        var snapshots = syncSnapshot?.conversations ?? []
        if let conversation { snapshots.append(conversation) }
        return inboxActivityProjection.resolve(
            cards: cards, snapshots: snapshots, excludedIDs: pendingCardIDs,
            omittedMessageIDs: pendingMessageIDs.union(failedOutboxIDs), showReasoning: showReasoning)
    }
}
