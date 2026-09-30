import CoreBridge
import DieterMessages
import Foundation
import Testing

/// Runs against scripts/isolated-gateway (a disposable gateway and enrolled
/// daemon with the mock harness); never against an operator's gateway. Start
/// it with run-tests.sh, which exports the fixture's environment.
@MainActor
struct CoreBridgeTests {
    let environment = ProcessInfo.processInfo.environment

    func fixture(_ key: String) throws -> String {
        try #require(environment[key], "run harness/apple/run-tests.sh, which exports \(key)")
    }

    func wait(_ what: String, timeout: Duration = .seconds(30), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("timed out waiting for \(what)")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    @Test func swiftUiDrivesTheSharedCoreThroughBytes() async throws {
        let project = try fixture("DIETER_ISOLATED_PROJECT"), board = try fixture("DIETER_ISOLATED_BOARD")
        let daemon = try fixture("DIETER_ISOLATED_DAEMON")
        let directory = FileManager.default.temporaryDirectory.appending(path: "dieter-shared-\(UUID().uuidString)")
        let secrets = MemorySecureStore()
        let store = try SharedStore(stateDirectory: directory, clientVersion: "0.0.0-dev.0", secureStore: secrets)
        store.start()
        try await store.dispatch(.with { $0.setForeground = .with { $0.foreground = true } })

        do {
            try await store.dispatch(.with { $0.adoptSession = .with { $0.gatewayURL = "http://127.0.0.1:9" } })
            Issue.record("an empty session token must be rejected")
        } catch let failure as SharedFailure {
            #expect(failure.kind == .invalid)
        }

        let started = ContinuousClock.now
        try await store.dispatch(.with {
            $0.adoptSession = .with { adopt in
                adopt.gatewayURL = "http://\(try! fixture("DIETER_ISOLATED_ADDR"))"
                adopt.sessionToken = try! fixture("DIETER_ISOLATED_TOKEN")
                adopt.name = "Isolated"
            }
        })
        try await wait("connected") { store.session.phase == .connected }
        try await wait("project") { store.workspace.projects.contains { $0.id == project } }
        print("connected and synced in \(ContinuousClock.now - started)")
        #expect(store.session.attachedMachineID == daemon)
        #expect(store.session.machines.contains { $0.id == daemon && $0.online && $0.attached })

        let created = try await store.dispatch(.with {
            $0.createConversation = .with {
                $0.request = .with { request in
                    request.projectID = project
                    request.boardID = board
                    request.lane = "todo"
                    request.title = "From Swift through DieterShared"
                    request.prompt = "hello"
                    request.deferStart = true
                    request.workspaceMode = "project"
                }
            }
        })
        #expect(!created.card.id.isEmpty)
        try await wait("synced card") {
            store.workspace.cards.contains { $0.title == "From Swift through DieterShared" && !store.workspace.pendingCardIds.contains($0.id) && $0.id.hasPrefix("c_") }
        }
        let cardID = try #require(store.workspace.cards.first { $0.title == "From Swift through DieterShared" }?.id)
        try await store.dispatch(.with { $0.renameCard = .with { $0.cardID = cardID; $0.title = "Renamed from Swift" } })
        try await wait("renamed") { store.workspace.cards.contains { $0.id == cardID && $0.title == "Renamed from Swift" } }

        let chat = try await store.dispatch(.with {
            $0.createConversation = .with {
                $0.chat = true
                $0.request = .with { request in
                    request.projectID = project
                    request.title = "chat"
                    request.prompt = "first"
                    request.provider = "mock"
                    request.model = "mock"
                    request.effort = "low"
                    request.workspaceMode = "project"
                }
            }
        })
        store.observeConversation(chat.card.id)
        func replies() -> Int { store.conversations[chat.card.id]?.messages.filter { $0.role == "assistant" }.count ?? 0 }
        func idle() -> Bool { !["running", "starting"].contains(store.conversations[chat.card.id]?.conversation.status ?? "running") }
        try await wait("first reply", timeout: .seconds(60)) { replies() >= 1 && idle() }
        let conversationCard = try #require(store.conversations[chat.card.id]?.cardID)
        try await store.dispatch(.with {
            $0.sendMessage = .with { $0.cardID = conversationCard; $0.parts = [.with { $0.type = "text"; $0.text = "second" }] }
        })
        try await wait("second reply", timeout: .seconds(60)) { replies() >= 2 && idle() }
        let userTexts = store.conversations[chat.card.id]?.messages.filter { $0.role == "user" }.flatMap(\.parts).map(\.text)
        #expect(userTexts == ["first", "second"])
        #expect(store.resubscriptions == 0)
        store.stopObservingConversation(chat.card.id)
        try await store.shutdown()

        // The next launch renders the cached workspace before any network access.
        let restarted = try SharedStore(stateDirectory: directory, clientVersion: "0.0.0-dev.0", secureStore: secrets)
        restarted.start()
        try await wait("cached workspace") { restarted.workspace.cards.contains { $0.id == cardID && $0.title == "Renamed from Swift" } }
        #expect(restarted.session.phase == .disconnected)
        try await restarted.shutdown()
    }
}
