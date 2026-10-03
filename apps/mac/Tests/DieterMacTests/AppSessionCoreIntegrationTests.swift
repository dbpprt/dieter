import DieterAPI
import Foundation
import Testing

@testable import DieterMac

/// Drives the whole Mac session — AppSession over the real DieterShared
/// framework — against tools/fixtures/gateway, never an operator's
/// gateway or daemon. `just pipeline check component:mac operation:core_test` starts the fixture and exports its
/// DIETER_ISOLATED_* environment; without it these tests are skipped.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["DIETER_ISOLATED_ADDR"] != nil))
final class AppSessionCoreIntegrationTests {
    let environment = ProcessInfo.processInfo.environment

    func fixture(_ key: String) throws -> String {
        try #require(environment[key], "run `just pipeline check component:mac operation:core_test`, which exports \(key)")
    }

    /// The session as the core last described it, for failure messages.
    var state: String {
        guard let store = current else { return "no session" }
        return
            "phase \(store.session.phase) error '\(store.session.error)' attached '\(store.session.attachedMachineID)' "
            + "gateways \(store.session.gateways.map(\.origin)) machines \(store.machines.map(\.name)) "
            + "projects \(store.projectDirectory.count) app error '\(store.errorMessage ?? "")'"
    }
    var current: AppSession?

    func wait(_ what: String, timeout: Duration = .seconds(30), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("timed out waiting for \(what): \(state)")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// A launch as the e2e runner does it: an isolated state root, preference
    /// suite, and the fixture's session from the command line.
    func launch(root: URL, suite: String) throws -> AppSession {
        let tokenFile = root.appending(path: "session-token")
        if !FileManager.default.fileExists(atPath: tokenFile.path) {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data(try fixture("DIETER_ISOLATED_TOKEN").utf8).write(to: tokenFile)
        }
        let defaults = try #require(UserDefaults(suiteName: suite))
        let arguments = [
            "DieterMac", "--dieter-endpoint", "http://\(try fixture("DIETER_ISOLATED_ADDR"))",
            "--dieter-access-token-file", tokenFile.path,
        ]
        // An isolated storage root; the live core never sees an operator's state.
        return AppSession(
            environment: DieterAppEnvironment(
                arguments: arguments, defaults: defaults, storageRoot: root.appending(path: "client")),
            liveCore: true, themeDefaultsOverride: defaults)
    }

    @Test func theMacSessionConnectsSyncsAndChatsThroughTheSharedCore() async throws {
        let project = try fixture("DIETER_ISOLATED_PROJECT")
        let board = try fixture("DIETER_ISOLATED_BOARD")
        let daemon = try fixture("DIETER_ISOLATED_DAEMON")
        let root = FileManager.default.temporaryDirectory.appending(path: "dieter-session-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "AppSessionCoreIntegration.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }

        let store = try launch(root: root, suite: suite)
        current = store
        #expect(store.coreHost != nil, "a live launch runs the shared core")
        await store.connect()
        try await wait("connected") { store.phase.isConnected && store.connectedMachineID == store.endpoint.id }
        #expect(store.endpoint.daemonID == daemon)
        try await wait("project") { store.projectDirectory[project] != nil }
        try await wait("selected board") { store.selectedProjectID == project && store.selectedBoardID == board }
        #expect(store.machines.contains { $0.daemonID == daemon && $0.online })
        #expect(store.machineEntry(store.endpoint)?.route.isEmpty == false)
        try await wait("agents") { store.harnessCatalog.harnesses.contains { $0.id == "mock" } }

        // The project's files are listed, created, opened, and saved on its
        // checkout's machine through a core files surface.
        #expect(await store.loadFiles(), "files: \(store.filesModel.filesError ?? "")")
        #expect(!store.filesModel.files.isEmpty)
        await store.createFile(name: "mac-session-notes.txt", directory: false)
        #expect(store.filesModel.files.contains { $0.name == "mac-session-notes.txt" })
        await store.openFile(path: "mac-session-notes.txt")
        #expect(store.filesModel.fileDocument?.path == "mac-session-notes.txt")
        let saved = await store.saveFile(content: "written by the Mac session\n")
        #expect(saved?.content == "written by the Mac session\n")
        #expect(store.filesModel.fileDocument?.revision == saved?.revision)
        await store.openFile(path: "mac-session-notes.txt")
        #expect(store.filesModel.fileDocument?.content == "written by the Mac session\n")

        // A board card is created through the outbox and edited on the board.
        let created = await store.createConversation(
            .with {
                $0.projectID = store.selectedProjectID
                $0.boardID = store.selectedBoardID
                $0.lane = "todo"
                $0.title = "From the Mac session"
                $0.prompt = "hello"
                $0.selection = .with {
                    $0.provider = "mock"; $0.model = "mock"; $0.effort = "low"
                }
                $0.workspaceMode = "project"
            }, chat: false)
        #expect(created)
        try await wait("synced card") {
            store.state.cards.contains { $0.title == "From the Mac session" && store.isConversationServerBacked($0.id) }
        }
        let card = try #require(store.state.cards.first { $0.title == "From the Mac session" })
        await store.rename(card, title: "Renamed by the Mac session")
        try await wait("renamed") {
            store.state.cards.contains { $0.id == card.id && $0.title == "Renamed by the Mac session" }
        }
        let labelLane = try #require(store.selectedBoard?.lanes.first { ![card.lane, "running"].contains($0.id) })
        await store.move(card, lane: labelLane.id)
        // The core shows the move at once and keeps it pending until the machine confirms it.
        try await wait("moved") { store.state.cards.contains { $0.id == card.id && $0.lane == labelLane.id } }
        try await wait("move confirmed") { store.movingCardIDs.isEmpty }

        // A chat opens on its machine, answers, and takes a second message
        // from the composer.
        let chatCreated = await store.createConversation(
            .with {
                $0.projectID = store.selectedProjectID
                $0.title = "Session chat"
                $0.prompt = "first"
                $0.selection = .with {
                    $0.provider = "mock"; $0.model = "mock"; $0.effort = "low"
                }
                $0.workspaceMode = "project"
            }, chat: true)
        #expect(chatCreated)
        #expect(store.section == .chats)
        func replies() -> Int { store.conversationMessages.filter { $0.role == "assistant" }.count }
        func idle() -> Bool {
            !["running", "starting"].contains(store.conversation?.conversation.status ?? "running")
        }
        try await wait("first reply", timeout: .seconds(60)) { replies() >= 1 && idle() }
        let chatID = try #require(store.selectedChatID)
        #expect(store.isConversationServerBacked(chatID), "the selection followed the server ID")
        #expect(store.selectedDetail?.project.id == project)
        store.composerText = "second"
        await store.sendComposer()
        #expect(store.composerText.isEmpty)
        try await wait("second reply", timeout: .seconds(60)) {
            replies() >= 2 && idle() && !store.conversationModel.state.working
        }
        #expect(
            store.conversationMessages.filter { $0.role == "user" }.flatMap(\.parts).map(\.text) == ["first", "second"])
        let chat = try #require(store.chats.first { $0.id == chatID })
        await store.pin(chat, pinned: true)
        try await wait("pinned") { store.chats.contains { $0.id == chatID && $0.pinned } }
        // A screen share reaches the machine over the gateway route and the
        // Mac's media engine; the isolated daemon has no capture helper, so it
        // settles on its reason without starting media.
        let machine = try #require(store.machines.first { $0.daemonID == daemon })
        let screen = store.screensModel.createSession(
            machineID: machine.id, daemonID: daemon, machineName: machine.name)
        func screenSettled() -> Bool {
            switch screen.controller.phase {
            case .unsupported, .permissionRequired: true
            default: false
            }
        }
        try await wait("screen capabilities") { screenSettled() }
        #expect(screen.controller.capabilities.platform.isEmpty == false)
        #expect(!screen.controller.routeLabel.isEmpty)
        store.screensModel.closeSession(screen.id)

        store.closeConversation()
        #expect(store.conversation == nil)
        #expect(store.failedOutboxItems.isEmpty)
        await store.coreHost?.shutdown()

        // The next launch shows the cached workspace before it reconnects.
        let relaunched = try launch(root: root, suite: suite)
        await relaunched.startCore()
        try await wait("cached workspace") {
            relaunched.navigationCards[project]?.contains {
                $0.id == card.id && $0.title == "Renamed by the Mac session"
            } == true
        }
        await relaunched.connect()
        #expect(relaunched.phase.isConnected)
        await relaunched.coreHost?.shutdown()
    }
}
