import DieterAPI
import Foundation
import Testing

@testable import SharedCore

/// Drives the real DieterShared framework against tools/fixtures/gateway (a
/// disposable gateway and enrolled daemon running the mock harness), never an
/// operator's gateway. `just pipeline check component:mac operation:core_test` starts the fixture and exports its
/// DIETER_ISOLATED_* environment; without it these tests are skipped.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["DIETER_ISOLATED_ADDR"] != nil))
struct SharedCoreIntegrationTests {
    let environment = ProcessInfo.processInfo.environment

    func fixture(_ key: String) throws -> String {
        try #require(environment[key], "run `just pipeline check component:mac operation:core_test`, which exports \(key)")
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

    /// A minimal fold of the slices this test reads.
    @MainActor
    final class Folded {
        var session = ClientSessionSlice()
        var workspace = ClientWorkspaceSlice()
        var conversation: ClientConversationSlice?
        var subscriptions: [SliceSubscription] = []

        init(_ core: CoreClient) {
            subscriptions.append(
                SliceSubscription(client: core, slice: .session) { [unowned self] update in
                    if case .session(let value) = update.value { session = value }
                })
            subscriptions.append(
                SliceSubscription(client: core, slice: .workspace) { [unowned self] update in
                    switch update.value {
                    case .workspace(let value): workspace = value
                    case .workspaceDelta(let delta):
                        workspace.projects = delta.projects
                        workspace.boards = delta.boards
                        workspace.cards = KeyedList.apply(
                            workspace.cards, upserted: delta.upsertedCards, removed: delta.removedCardIds,
                            order: delta.orderChanged ? delta.cardOrder : nil, key: \.id)
                        workspace.pendingCardIds = delta.pendingCardIds
                        workspace.loaded = delta.loaded
                    default: break
                    }
                })
        }

        func observeConversation(_ core: CoreClient, _ cardID: String) {
            subscriptions.append(
                SliceSubscription(client: core, slice: .conversation, scope: cardID) { [unowned self] update in
                    switch update.value {
                    case .conversation(let value): conversation = value
                    case .conversationDelta(let delta):
                        guard var slice = conversation else { return }
                        slice.card = delta.card
                        slice.conversation = delta.conversation
                        if !delta.cardID.isEmpty { slice.cardID = delta.cardID }
                        slice.messages = KeyedList.apply(
                            slice.messages, upserted: delta.upsertedMessages, removed: delta.removedMessageIds,
                            order: delta.orderChanged ? delta.messageOrder : nil, key: \.id)
                        conversation = slice
                    default: break
                    }
                })
        }

        var resubscriptions: Int { subscriptions.map(\.resubscriptions).reduce(0, +) }

        func close() { subscriptions.forEach { $0.close() } }
    }

    func host(root: URL, defaults: UserDefaults) throws -> CoreHost {
        try CoreHost(
            configuration: CoreHostConfiguration(
                root: root, clientVersion: "0.0.0-dev.0", logSubsystem: "com.dbpprt.dieter.mac.tests"),
            platform: .mac(
                credentialsFile: root.appending(path: "gateway-sessions.json"), notificationsEnabled: { false }),
            defaults: defaults)
    }

    @Test func theMacDrivesTheSharedCoreOverAPinnedDirectRoute() async throws {
        let project = try fixture("DIETER_ISOLATED_PROJECT")
        let board = try fixture("DIETER_ISOLATED_BOARD")
        let daemon = try fixture("DIETER_ISOLATED_DAEMON")
        let root = FileManager.default.temporaryDirectory.appending(path: "dieter-shared-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "SharedCoreIntegration.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let host = try host(root: root, defaults: defaults)
        let core = host.client
        let folded = Folded(core)
        host.start()
        try await core.dispatch { $0.setForeground = .with { $0.foreground = true } }

        await #expect(throws: CoreFailure.self) {
            try await core.dispatch { $0.adoptSession = .with { $0.gatewayURL = "http://127.0.0.1:9" } }
        }

        try await core.dispatch {
            $0.adoptSession = .with { adopt in
                adopt.gatewayURL = "http://\(try! fixture("DIETER_ISOLATED_ADDR"))"
                adopt.sessionToken = try! fixture("DIETER_ISOLATED_TOKEN")
                adopt.name = "Isolated"
            }
        }
        try await wait("connected") { folded.session.phase == .connected }
        try await wait("project") { folded.workspace.projects.contains { $0.id == project } }
        #expect(folded.session.attachedMachineID == daemon)
        // The daemon's loopback TLS route is pinned by the Swift bridge.
        try await wait("direct route") {
            folded.session.machines.contains { $0.id == daemon && ["Local", "Direct TLS"].contains($0.route) }
        }

        let created = try await core.dispatch {
            $0.createConversation = .with {
                $0.intent = .with { intent in
                    intent.projectID = project
                    intent.boardID = board
                    intent.lane = "todo"
                    intent.title = "From the Mac through DieterShared"
                    intent.prompt = "hello"
                    intent.workspaceMode = "project"
                }
            }
        }
        #expect(!created.card.id.isEmpty)
        try await wait("synced card") {
            folded.workspace.cards.contains {
                $0.title == "From the Mac through DieterShared" && $0.id.hasPrefix("c_")
                    && !folded.workspace.pendingCardIds.contains($0.id)
            }
        }
        let cardID = try #require(folded.workspace.cards.first { $0.title == "From the Mac through DieterShared" }?.id)
        try await core.dispatch {
            $0.renameCard = .with {
                $0.cardID = cardID; $0.title = "Renamed on the Mac"
            }
        }
        try await wait("renamed") {
            folded.workspace.cards.contains { $0.id == cardID && $0.title == "Renamed on the Mac" }
        }

        let chat = try await core.dispatch {
            $0.createConversation = .with {
                $0.chat = true
                $0.intent = .with { intent in
                    intent.projectID = project
                    intent.title = "chat"
                    intent.prompt = "first"
                    intent.selection = .with {
                        $0.provider = "mock"; $0.model = "mock"; $0.effort = "low"
                    }
                    intent.workspaceMode = "project"
                }
            }
        }
        folded.observeConversation(core, chat.card.id)
        func replies() -> Int { folded.conversation?.messages.filter { $0.role == "assistant" }.count ?? 0 }
        func idle() -> Bool {
            !["running", "starting"].contains(folded.conversation?.conversation.status ?? "running")
        }
        try await wait("first reply", timeout: .seconds(60)) { replies() >= 1 && idle() }
        let conversationCard = try #require(folded.conversation?.cardID)
        #expect(conversationCard.hasPrefix("c_"), "deltas carry the server ID once the creation is accepted")
        try await core.dispatch {
            $0.sendMessage = .with {
                $0.cardID = conversationCard;
                $0.parts = [
                    .with {
                        $0.type = "text"; $0.text = "second"
                    }
                ]
            }
        }
        try await wait("second reply", timeout: .seconds(60)) { replies() >= 2 && idle() }
        #expect(
            folded.conversation?.messages.filter { $0.role == "user" }.flatMap(\.parts).map(\.text) == [
                "first", "second",
            ])
        #expect(folded.resubscriptions == 0)
        folded.close()
        await host.shutdown()

        // The next launch shows the cached workspace before any network access,
        // and the session survives in the shared credentials file.
        let restarted = try self.host(root: root, defaults: defaults)
        let refolded = Folded(restarted.client)
        restarted.start()
        try await wait("cached workspace") {
            refolded.workspace.cards.contains { $0.id == cardID && $0.title == "Renamed on the Mac" }
        }
        try await restarted.client.dispatch { $0.setForeground = .with { $0.foreground = true } }
        try await wait("signed in again") { [.syncing, .connected].contains(refolded.session.phase) }
        refolded.close()
        await restarted.shutdown()
    }
}
