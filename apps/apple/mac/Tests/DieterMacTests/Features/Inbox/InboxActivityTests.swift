import DieterAPI
import DieterClientAPI
import Foundation
import Testing
@testable import DieterMacKit

/// The shared core classifies and words activity (its ActivityTest); the
/// Mac maps its rows.
@MainActor
struct InboxActivityTests {
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

    @Test func inboxEntriesComeFromTheCoresActivityRows() {
        let store = DieterStore(liveEnvironment: false)
        store.activity.rows = [
            .with {
                $0.card = card("needs", runtime: "waiting_for_user")
                $0.kind = "ANSWER"
                $0.section = .attention
                $0.needsYou = true
                $0.detail = "Waiting for your answer"
                $0.projectName = "Dieter"
                $0.boardName = "Release"
            },
            .with {
                $0.card = card("busy", runtime: "running", lane: "review")
                $0.kind = "RUNNING"
                $0.section = .running
                $0.detail = "Running tests"
            },
            .with {
                $0.card = card("done", runtime: "idle", lane: "In review")
                $0.kind = "REVIEW"
                $0.section = .recent
                $0.canFinish = true
            },
            .with {
                $0.card = card("unknown", runtime: "idle"); $0.kind = "SOMETHING_NEW"
            },
        ]
        let entries = store.inboxEntries
        #expect(entries.map(\.id) == ["needs", "busy", "done"], "kinds this Mac does not know are skipped")
        #expect(entries.map(\.kind) == [.answer, .running, .review])
        // Needing the user and finishing are the core's, not re-derived from the card.
        #expect(entries.map(\.needsYou) == [true, false, false])
        #expect(entries.map(\.canFinish) == [false, false, true])
        #expect(entries[1].running && entries[1].row.detail == "Running tests")
        // The Inbox lists each entry where the core places it, with the core's names.
        #expect(entries.map(\.section) == [.attention, .running, .recent])
        #expect(entries[0].row.projectName == "Dieter" && entries[0].row.boardName == "Release")
    }

    @Test func statusChangesReplaceTheRenderedRowButKeepTheConversationIdentity() {
        let store = DieterStore(liveEnvironment: false)
        func entry(_ kind: String, section: ClientActivityRow.Section, pinned: Bool = false) -> InboxActivityEntry {
            store.activity.rows = [
                .with {
                    $0.card = card("same-card", runtime: "idle")
                    $0.kind = kind
                    $0.section = section
                    $0.pinned = pinned
                }
            ]
            return store.inboxEntries[0]
        }
        let recent = entry("RECENT", section: .recent)
        let running = entry("RUNNING", section: .running)
        let unread = entry("UNREAD", section: .attention)
        let read = entry("RECENT", section: .recent)
        let pinned = entry("RECENT", section: .recent, pinned: true)
        #expect(recent.id == running.id && running.id == unread.id)
        #expect(recent.rowIdentity != running.rowIdentity)
        #expect(running.rowIdentity != unread.rowIdentity)
        #expect(unread.rowIdentity != read.rowIdentity)
        #expect(recent.rowIdentity == read.rowIdentity)
        #expect(read.id == pinned.id)
        #expect(read.rowIdentity != pinned.rowIdentity)
    }
}
