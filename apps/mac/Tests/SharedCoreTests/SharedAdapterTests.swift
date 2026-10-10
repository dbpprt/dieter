import DieterAPI
import DieterShared
import Foundation
import Testing

@testable import SharedCore

/// The platform-neutral adapter layer both apps present the core through.
struct SharedAdapterTests {
    private func card(_ id: String, _ title: String = "") -> Dieter_V1_Card {
        .with {
            $0.id = id
            $0.title = title
        }
    }

    @Test func workspaceDeltasReplaceUnkeyedFieldsAndFoldCards() {
        let base = ClientWorkspaceSlice.with {
            $0.cards = [card("a"), card("b"), card("c")]
            $0.loaded = false
            $0.pendingCardIds = ["a"]
            $0.boardAttention = ["board": 2]
        }
        let delta = ClientWorkspaceDelta.with {
            $0.projects = [.with { $0.id = "p" }]
            $0.upsertedCards = [card("b", "renamed"), card("d")]
            $0.removedCardIds = ["a"]
            $0.loaded = true
            $0.retiredBoards = [.with { $0.id = "retired" }]
            $0.projectHosts = ["p": "daemon"]
        }
        let next = base.applying(delta)
        #expect(next.cards.map(\.id) == ["b", "c", "d"])
        #expect(next.cards.first?.title == "renamed")
        #expect(next.projects.map(\.id) == ["p"])
        #expect(next.loaded)
        #expect(next.pendingCardIds.isEmpty)
        #expect(next.boardAttention.isEmpty)
        #expect(next.retiredBoards.map(\.id) == ["retired"])
        #expect(next.projectHosts == ["p": "daemon"])
        // An explicit order wins when it changed.
        let reordered = next.applying(
            .with {
                $0.cardOrder = ["d", "b", "c"]
                $0.orderChanged = true
            })
        #expect(reordered.cards.map(\.id) == ["d", "b", "c"])
        let unordered = next.applying(.with { $0.cardOrder = ["d", "b", "c"] })
        #expect(unordered.cards.map(\.id) == ["b", "c", "d"])
    }

    @Test func conversationDeltasFoldMessagesTimelineAndTheTurnFailure() {
        let base = ClientConversationSlice.with {
            $0.cardID = "local_1"
            $0.messages = [.with { $0.id = "m1" }, .with { $0.id = "m2" }]
            $0.timeline = [.with { $0.id = "t1" }]
            $0.turnFailure = .with { $0.summary = "failed" }
            $0.loading = true
        }
        let delta = ClientConversationDelta.with {
            $0.upsertedMessages = [.with { $0.id = "m3" }]
            $0.removedMessageIds = ["m1"]
            $0.upsertedTimeline = [.with { $0.id = "t2" }]
            $0.timelineOrder = ["t2", "t1"]
            $0.timelineOrderChanged = true
            $0.earlierCount = 4
        }
        let next = base.applying(delta)
        #expect(next.messages.map(\.id) == ["m2", "m3"])
        #expect(next.timeline.map(\.id) == ["t2", "t1"])
        #expect(!next.hasTurnFailure)
        #expect(!next.loading)
        #expect(next.earlierCount == 4)
        // An empty card ID keeps the one the conversation had.
        #expect(next.cardID == "local_1")
        let resolved = next.applying(
            .with {
                $0.cardID = "c_1"
                $0.turnFailure = .with { $0.summary = "again" }
            })
        #expect(resolved.cardID == "c_1")
        #expect(resolved.turnFailure.summary == "again")
        #expect(resolved.messages.map(\.id) == ["m2", "m3"])
    }

    @Test func theMacConfiguresTheCoreForTheDesktop() {
        let file = FileManager.default.temporaryDirectory.appending(path: "dieter-platform-\(UUID().uuidString).json")
        let mac = CoreHostPlatform.mac(credentialsFile: file, notificationsEnabled: { false })
        #expect(mac.secureStore is CoreFileSecureStore)
        #expect(mac.includeLoopbackRoutes && !mac.compactTranscripts && mac.desktopScreens)
        #expect(mac.screenClientName == "Mac" && mac.clientIDPrefix == "mac")
        #expect(mac.oauthRedirectURI == "dieter-mac://oauth/callback")
        #expect(mac.clipboard == nil)
    }

    @MainActor
    @Test func aChatsFixtureHoldsTheCoresListUntilItIsRemoved() {
        let core = ScriptedCoreClient()
        let model = ChatsListModel(scope: "chats-test")
        model.attach(core)
        var held = true
        model.fixture = { query in held ? ClientChatsSlice.with { $0.otherIds = ["fixture:\(query)"] } : nil }
        core.emit(.chats, scope: "chats-test") { $0.chats = .with { $0.otherIds = ["core"] } }
        #expect(model.slice.otherIds.isEmpty)
        model.search("x")
        #expect(model.slice.otherIds == ["fixture:x"])
        held = false
        core.emit(.chats, scope: "chats-test") { $0.chats = .with { $0.otherIds = ["core"] } }
        #expect(model.slice.otherIds == ["core"])
    }
}
