import DieterAPI
import Foundation
import Testing
@testable import DieterMac

struct InboxActivityTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func card(_ id: String, runtime: String, scope: String = "card", lane: String = "working") -> Dieter_V1_Card
    {
        var card = Dieter_V1_Card()
        card.id = id
        card.title = id
        card.runtime = runtime
        card.scope = scope
        card.lane = lane
        card.runtimeUpdatedAt = "2026-09-24T10:00:00Z"
        card.initialPromptSentAt = "2026-09-24T09:00:00Z"
        return card
    }

    @Test func runningPrecedesAttentionWithoutIncludingDrafts() {
        var draft = card("draft", runtime: "idle")
        draft.initialPromptSentAt = ""
        let entries = InboxActivity.entries(cards: [
            card("answer", runtime: "waiting_for_user", lane: "review"),
            card("working", runtime: "running", lane: "review"),
            card("review", runtime: "failed", lane: "review"),
            card("chat", runtime: "completed", scope: "chat", lane: "review"),
            card("pending", runtime: "pending"), draft,
        ])
        #expect(entries.map(\.id) == ["answer", "chat", "review", "working"])
        #expect(entries.map(\.kind) == [.answer, .recent, .review, .running])
        #expect(entries.filter(\.needsYou).map(\.id) == ["answer"])
        #expect(entries.filter(\.running).map(\.id) == ["working"])
    }

    @Test func finishingReviewKeepsRecentChronological() {
        var review = card("review", runtime: "idle", lane: "review")
        var failed = card("failed", runtime: "failed")
        failed.runtimeUpdatedAt = "2026-09-24T11:00:00Z"
        let recent = card("recent", runtime: "idle")
        let before = InboxActivity.entries(cards: [review, failed, recent]).map(\.id)
        review.lane = "done"
        #expect(InboxActivity.entries(cards: [review, failed, recent]).map(\.id) == before)
        #expect(before == ["failed", "recent", "review"])
    }

    @Test func unreadRepliesNeedAttentionUntilSeenAcrossCardsAndChats() {
        for scope in ["board", "chat"] {
            var reply = card("reply", runtime: "idle", scope: scope, lane: "review")
            reply.responseSeq = 30
            reply.seenResponseSeq = 10
            #expect(InboxActivity.entries(cards: [reply]).first?.kind == .unread)
            #expect(InboxActivity.entries(cards: [reply]).first?.needsYou == true)
            reply.seenResponseSeq = 30
            #expect(InboxActivity.entries(cards: [reply]).first?.needsYou == false)
            reply.responseSeq = 50
            #expect(InboxActivity.entries(cards: [reply]).first?.needsYou == true)
            reply.runtime = "running"
            #expect(InboxActivity.entries(cards: [reply]).first?.kind == .running)
            reply.archived = true
            #expect(InboxActivity.entries(cards: [reply]).isEmpty)
        }
    }

    @Test func freshestIdentityWinsBeforeArchivedFiltering() {
        var old = card("same", runtime: "running")
        old.updatedAt = "2026-09-24T11:00:00+02:00"
        var newest = old
        newest.runtime = "completed"
        newest.lastActivityAt = "2026-09-24T10:01:00Z"
        #expect(InboxActivity.entries(cards: [newest, old]).map(\.kind) == [.recent])
        newest.archived = true
        #expect(InboxActivity.entries(cards: [newest, old]).isEmpty)
        #expect(InboxActivity.entries(cards: [old], excludedIDs: [old.id]).isEmpty)
    }

    @Test func missingAndTiedTimestampsHaveDeterministicIdentityOrder() {
        var a = card("a", runtime: "failed")
        a.runtimeUpdatedAt = "invalid"
        var b = a
        b.id = "b"
        let c = card("c", runtime: "failed")
        #expect(InboxActivity.entries(cards: [b, c, a]).map(\.id) == ["c", "a", "b"])
    }

    @Test func staleAndFutureTurnStartsCannotInventCompletedDurations() throws {
        let finished = card("finished", runtime: "completed")
        let at = try #require(DieterTimestamp.date(from: finished.runtimeUpdatedAt))
        let stale = InboxActivityDetail(
            runtimeUpdatedAt: "old-turn", start: at.addingTimeInterval(-600), label: "Old work")
        let future = InboxActivityDetail(
            runtimeUpdatedAt: finished.runtimeUpdatedAt, start: at.addingTimeInterval(1), label: "")
        let valid = InboxActivityDetail(
            runtimeUpdatedAt: finished.runtimeUpdatedAt, start: at.addingTimeInterval(-600), label: "")
        #expect(InboxActivity.entries(cards: [finished], details: [finished.id: stale]).first?.start == nil)
        #expect(InboxActivity.entries(cards: [finished], details: [finished.id: future]).first?.start == nil)
        #expect(
            InboxActivity.entries(cards: [finished], details: [finished.id: valid]).first?.start
                == at.addingTimeInterval(-600))
        let running = card("running", runtime: "streaming")
        #expect(InboxActivity.entries(cards: [running], details: [running.id: stale]).first?.start == at)
    }

    @Test func timelineClipsDurationsKeepsBoundaryEventsAndOmitsOutsideEvents() throws {
        func entry(_ id: String, at: Date, start: Date? = nil, running: Bool = false) -> InboxActivityEntry {
            InboxActivityEntry(
                card: card(id, runtime: running ? "running" : "completed"),
                kind: running ? .running : .recent, at: at, start: start, detail: "")
        }
        let boundary = now.addingTimeInterval(-3600)
        let entries = [
            entry("clipped", at: now.addingTimeInterval(-60), start: now.addingTimeInterval(-7200)),
            entry("boundary", at: boundary),
            entry("old", at: boundary.addingTimeInterval(-1)),
            entry("future", at: now.addingTimeInterval(1)),
            entry("live", at: now.addingTimeInterval(-60), start: now.addingTimeInterval(-120), running: true),
        ]
        let intervals = InboxActivity.timeline(entries: entries, now: now, hours: 1)
        #expect(Set(intervals.map(\.id)) == ["clipped", "boundary", "live"])
        let clipped = try #require(intervals.first { $0.id == "clipped" })
        #expect(clipped.from == 0)
        #expect(clipped.to == 3540.0 / 3600)
        #expect(!clipped.point)
        let point = try #require(intervals.first { $0.id == "boundary" })
        #expect(point.from == 0 && point.to == 0 && point.point)
        #expect(intervals.first { $0.id == "live" }?.to == 1)
        #expect(InboxActivity.timeline(entries: entries, now: now, hours: 6).contains { $0.id == "old" })
    }

    @Test @MainActor func cachedDetailsExcludeQueuedMessagesAndEvictRemovedSnapshots() throws {
        let projection = InboxActivityProjection()
        let running = card("running", runtime: "running")
        var snapshot = Dieter_V1_ConversationSnapshot()
        snapshot.detail.card = running
        var sent = Dieter_V1_UiMessage()
        sent.id = "sent"
        sent.role = "user"
        sent.metadataJson = Data(#"{"createdAt":"2026-09-24T09:30:00Z"}"#.utf8)
        var queued = sent
        queued.id = "queued"
        queued.metadataJson = Data(#"{"createdAt":"2026-09-24T09:59:00Z"}"#.utf8)
        var queue = Dieter_V1_QueuedMessage()
        queue.id = queued.id
        snapshot.conversation.messages = [sent, queued]
        snapshot.conversation.queue = [queue]
        let first = projection.resolve(
            cards: [running], snapshots: [snapshot], excludedIDs: [], omittedMessageIDs: [], showReasoning: true)
        #expect(first.first?.start == DieterTimestamp.date(from: "2026-09-24T09:30:00Z"))
        let evicted = projection.resolve(
            cards: [running], snapshots: [], excludedIDs: [], omittedMessageIDs: [], showReasoning: true)
        #expect(evicted.first?.start == DieterTimestamp.date(from: running.runtimeUpdatedAt))
    }
}
