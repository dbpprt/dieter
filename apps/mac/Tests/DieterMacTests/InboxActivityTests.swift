import DieterAPI
import Foundation
import Testing
@testable import DieterMac

/// The shared core classifies activity (its ActivityTest); the Mac maps its
/// rows and lays out the timeline.
@MainActor
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

    @Test func inboxEntriesComeFromTheCoresActivityRows() {
        let store = DieterStore(restoreSync: false)
        store.activityRows = [
            .with {
                $0.card = card("needs", runtime: "waiting_for_user")
                $0.kind = "ANSWER"
                $0.detail = "Waiting for your answer"
                $0.atMillis = 1_800_000_000_000
            },
            .with {
                $0.card = card("busy", runtime: "running")
                $0.kind = "RUNNING"
                $0.detail = "Running tests"
                $0.startedAtMillis = 1_799_999_000_000
            },
            .with {
                $0.card = card("unknown", runtime: "idle"); $0.kind = "SOMETHING_NEW"
            },
        ]
        let entries = store.inboxEntries
        #expect(entries.map(\.id) == ["needs", "busy"], "kinds this Mac does not know are skipped")
        #expect(entries[0].needsYou && entries[0].at == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(entries[1].running && entries[1].detail == "Running tests" && entries[1].at == nil)
        #expect(entries[1].start == Date(timeIntervalSince1970: 1_799_999_000))
    }
}
