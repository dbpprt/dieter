#if os(iOS)
    import DieterAPI
    import Foundation
    import SharedCore
    import XCTest
    @testable import DieterIOS

    /// The iOS app adapts the shared core's slices and commands; these feed a
    /// scripted core and check what views read and what the core is asked.
    /// They need UIKit, so they compile into the app-hosted
    /// DieterIOSNativeTests target and run in the Simulator (`ios.adapters`).
    @MainActor
    final class IOSCoreAdapterTests: XCTestCase {
        // MARK: - Helpers

        private func commands<Value>(
            _ core: ScriptedCoreClient, _ match: (ClientCommand.OneOf_Command) -> Value?
        ) -> [Value] {
            core.commands.compactMap { $0.command.flatMap(match) }
        }

        /// Waits for queued commands, which the adapters send from tasks.
        private func eventually(
            _ description: String, file: StaticString = #filePath, line: UInt = #line,
            _ condition: () -> Bool
        ) async throws {
            let deadline = Date().addingTimeInterval(5)
            while !condition() {
                guard Date() < deadline else { return XCTFail("Timed out: \(description)", file: file, line: line) }
                try await DieterTaskSleep.milliseconds(5)
            }
        }

        private func launch(testSession: IOSLaunchConfiguration.TestSession? = nil) -> IOSLaunchConfiguration {
            IOSLaunchConfiguration(
                root: FileManager.default.temporaryDirectory, defaults: .standard, screenClientName: "iPhone",
                testSession: testSession, signedOutTestSession: nil, preview: nil, ephemeralCredentials: true)
        }

        private func card(_ id: String, _ title: String) -> Dieter_V1_Card {
            .with {
                $0.id = id
                $0.title = title
            }
        }

        private func message(_ id: String) -> Dieter_V1_UiMessage {
            .with {
                $0.id = id
                $0.role = "assistant"
            }
        }

        // MARK: - Launch and session

        #if DEBUG
            func testLaunchConfigurationMapsOnlyTheIsolatedTestEnvironment() {
                let support = URL(fileURLWithPath: "/support", isDirectory: true)
                let temporary = FileManager.default.temporaryDirectory.path
                let plain = IOSLaunchConfiguration.debug(environment: [:], device: "iPhone", support: support)
                XCTAssertEqual(plain.root, support)
                XCTAssertNil(plain.testSession)
                XCTAssertNil(plain.preview)
                XCTAssertFalse(plain.ephemeralCredentials)
                XCTAssertEqual(plain.screenClientName, "iPhone")
                // Launcher values the app no longer reads change nothing.
                let ignored = IOSLaunchConfiguration.debug(
                    environment: ["DIETER_IOS_TEST_PROJECT": "p", "DIETER_IOS_TEST_BOARD": "b"], device: "iPhone",
                    support: support)
                XCTAssertEqual(ignored.root, support)

                let gateway = ["DIETER_IOS_TEST_GATEWAY": "http://127.0.0.1:9", "DIETER_IOS_TEST_TOKEN": "test-token"]
                let adopted = IOSLaunchConfiguration.debug(environment: gateway, device: "iPad", support: support)
                XCTAssertEqual(adopted.testSession, .init(gatewayURL: "http://127.0.0.1:9", token: "test-token"))
                XCTAssertNil(adopted.signedOutTestSession)
                XCTAssertTrue(adopted.ephemeralCredentials)
                XCTAssertEqual(adopted.screenClientName, "iPad")
                XCTAssertTrue(adopted.root.path.hasPrefix(temporary), adopted.root.path)
                XCTAssertFalse(adopted.defaults === UserDefaults.standard)
                // Every isolated launch starts from its own state.
                let next = IOSLaunchConfiguration.debug(environment: gateway, device: "iPad", support: support)
                XCTAssertNotEqual(next.root, adopted.root)

                var signedOutEnvironment = gateway
                signedOutEnvironment["DIETER_IOS_TEST_START_SIGNED_OUT"] = "1"
                let signedOut = IOSLaunchConfiguration.debug(
                    environment: signedOutEnvironment, device: "iPhone", support: support)
                XCTAssertNil(signedOut.testSession)
                XCTAssertEqual(signedOut.signedOutTestSession?.token, "test-token")

                let previews: [(String, String, IOSLaunchConfiguration.Preview)] = [
                    ("DIETER_IOS_SCREEN_FIXTURE", "fixture", .screen("fixture")),
                    ("DIETER_IOS_CONNECTION_PREVIEW", "1", .connecting),
                ]
                for (name, value, preview) in previews {
                    let configuration = IOSLaunchConfiguration.debug(
                        environment: [name: value], device: "iPhone", support: support)
                    XCTAssertEqual(configuration.preview, preview, name)
                    XCTAssertTrue(configuration.ephemeralCredentials, name)
                    XCTAssertNil(configuration.testSession, name)
                }
            }
        #endif

        func testStartObservesTheAppSlicesAndAdoptsTheTestSessionOnce() async {
            let core = ScriptedCoreClient()
            let app = IOSAppModel(
                core: core, launch: launch(testSession: .init(gatewayURL: "http://127.0.0.1:9", token: "test-token")))
            await app.start()
            for slice in [ClientSlice.session, .workspace, .navigation, .activity, .outbox] {
                XCTAssertTrue(core.isObserved(slice), "\(slice)")
            }
            await app.start()
            let adopted = commands(core) { if case .adoptSession(let adopt) = $0 { adopt } else { nil } }
            XCTAssertEqual(adopted.map(\.gatewayURL), ["http://127.0.0.1:9"])
            XCTAssertEqual(adopted.map(\.sessionToken), ["test-token"])
            // Saved drafts load before the session is adopted.
            let kinds = core.commands.compactMap { command -> String? in
                switch command.command {
                case .listDrafts: "drafts"
                case .adoptSession: "adopt"
                default: nil
                }
            }
            XCTAssertEqual(kinds, ["drafts", "adopt"])
        }

        func testALaunchWithoutATestSessionAdoptsNothing() async {
            let core = ScriptedCoreClient()
            let app = IOSAppModel(core: core, launch: launch())
            await app.start()
            XCTAssertTrue(commands(core) { if case .adoptSession(let adopt) = $0 { adopt } else { nil } }.isEmpty)
        }

        func testForegroundChangesReachTheCoreInOrderOnceStarted() async throws {
            let core = ScriptedCoreClient()
            let app = IOSAppModel(core: core, launch: launch())
            app.setForeground(true)
            app.setForeground(false)
            app.setForeground(true)
            func sent() -> [Bool] {
                commands(core) { if case .setForeground(let set) = $0 { set.foreground } else { nil } }
            }
            try await eventually("three foreground changes") { sent().count == 3 }
            XCTAssertEqual(sent(), [true, false, true])
            XCTAssertTrue(core.isObserved(.session), "the core starts before the first change")
        }

        func testSignOutAndReconnectAreCoreCommands() async {
            let core = ScriptedCoreClient()
            let app = IOSAppModel(core: core, launch: launch())
            await app.signOut()
            await app.reconnect()
            let kinds = core.commands.compactMap { command -> String? in
                switch command.command {
                case .signOut: "sign-out"
                case .reconnect: "reconnect"
                default: nil
                }
            }
            XCTAssertEqual(kinds, ["sign-out", "reconnect"])
            XCTAssertNil(app.errorMessage)
        }

        func testRefusedCommandsShowTheCoresMessage() async {
            let core = ScriptedCoreClient()
            core.handler = { command in
                if case .reconnect = command.command {
                    throw CoreFailure(kind: .transient, message: "The gateway is unreachable.")
                }
                return .with { $0.done = ClientDone() }
            }
            let app = IOSAppModel(core: core, launch: launch())
            await app.reconnect()
            XCTAssertEqual(app.errorMessage, "The gateway is unreachable.")
        }

        func testTheSessionSliceDecidesLaunchAndSignIn() async {
            let core = ScriptedCoreClient()
            let app = IOSAppModel(core: core, launch: launch())
            await app.start()
            XCTAssertFalse(app.launched)
            // Disconnected before the core has run says nothing about the session.
            core.emit(.session) {
                $0.session = .with {
                    $0.phase = .disconnected
                    $0.gateways = [
                        .with {
                            $0.origin = "https://gateway.getdieter.com:443"
                            $0.active = true
                            $0.connect = true
                        }
                    ]
                }
            }
            XCTAssertFalse(app.launched)
            core.emit(.session) { $0.session = .with { $0.phase = .authRequired } }
            XCTAssertTrue(app.launched)
            XCTAssertFalse(app.signedIn)
            core.emit(.session) {
                $0.session = .with {
                    $0.phase = .connected
                    $0.phaseLabel = "Connected"
                }
            }
            XCTAssertTrue(app.signedIn)
            XCTAssertEqual(app.session.phaseLabel, "Connected")
        }

        func testWorkspaceDeltasFoldOntoTheSnapshotInOrder() async {
            let core = ScriptedCoreClient()
            let app = IOSAppModel(core: core, launch: launch())
            await app.start()
            core.emit(.workspace) {
                $0.workspace = .with { $0.cards = [self.card("a", "First"), self.card("b", "Second")] }
            }
            core.emit(.workspace) {
                $0.workspaceDelta = .with {
                    $0.upsertedCards = [self.card("b", "Renamed")]
                    $0.removedCardIds = ["a"]
                }
            }
            XCTAssertEqual(app.workspace.cards.map(\.id), ["b"])
            XCTAssertEqual(app.card("b")?.title, "Renamed")
            XCTAssertNil(app.card("a"))
            // A lost update is never folded; the resubscribed snapshot replaces the workspace.
            core.emit(.workspace, skipSequence: true) {
                $0.workspaceDelta = .with { $0.upsertedCards = [self.card("lost", "Lost")] }
            }
            XCTAssertNil(app.card("lost"))
            core.emit(.workspace) { $0.workspace = .with { $0.cards = [self.card("c", "Fresh")] } }
            XCTAssertEqual(app.workspace.cards.map(\.id), ["c"])
        }

        func testTheVisibleConversationFollowsTheScreenInOrder() async throws {
            let core = ScriptedCoreClient()
            let app = IOSAppModel(core: core, launch: launch())
            app.setVisibleConversation("c1")
            // Another conversation leaving the screen leaves c1 visible.
            app.conversationHidden("c2")
            app.conversationHidden("c1")
            func sent() -> [String] {
                commands(core) { if case .setVisibleConversation(let set) = $0 { set.cardID } else { nil } }
            }
            try await eventually("both visibility changes") { sent().count == 2 }
            XCTAssertEqual(sent(), ["c1", ""])
        }

        // MARK: - Board view

        func testABoardViewBindsAfterItsFirstSnapshotAndDropsStaleTargets() async throws {
            let core = ScriptedCoreClient()
            let board = BoardViewModel(scope: "ios-board-test")
            board.attach(core)
            XCTAssertTrue(core.isObserved(.boardView, scope: "ios-board-test"))
            board.bind(boardID: "b1")
            func sent() -> [ClientBoardViewCommand] {
                commands(core) { if case .boardView(let command) = $0 { command } else { nil } }
            }
            XCTAssertTrue(sent().isEmpty, "the core takes commands once it has shown the view")
            core.emit(.boardView, scope: "ios-board-test") { $0.boardView = ClientBoardViewSlice() }
            try await eventually("the bind") { sent().count == 1 }
            XCTAssertEqual(sent().first?.scope, "ios-board-test")
            XCTAssertEqual(sent().first?.bind.boardID, "b1")

            core.emit(.boardView, scope: "ios-board-test") {
                $0.boardView = .with {
                    $0.target = .with { $0.boardID = "b2" }
                    $0.total = 9
                }
            }
            XCTAssertEqual(board.slice.total, 0, "a view of another board is stale")
            core.emit(.boardView, scope: "ios-board-test") {
                $0.boardView = .with {
                    $0.target = .with { $0.boardID = "b1" }
                    $0.total = 3
                }
            }
            XCTAssertEqual(board.slice.total, 3)

            board.bind(boardID: "b1")
            board.drop(cardID: "c1", laneID: "review")
            try await eventually("the drop") { sent().count == 2 }
            XCTAssertEqual(sent().last?.drop.cardID, "c1")
            XCTAssertEqual(sent().last?.drop.laneID, "review")
            board.detach()
            XCTAssertFalse(core.isObserved(.boardView, scope: "ios-board-test"))
        }

        func testABoardViewBindsAgainAfterALostUpdate() async throws {
            let core = ScriptedCoreClient()
            let board = BoardViewModel(scope: "ios-board-test")
            board.attach(core)
            board.bind(boardID: "b1")
            func binds() -> [String] {
                commands(core) {
                    if case .boardView(let command) = $0, case .bind(let bind) = command.action {
                        bind.boardID
                    } else {
                        nil
                    }
                }
            }
            core.emit(.boardView, scope: "ios-board-test") { $0.boardView = ClientBoardViewSlice() }
            try await eventually("the first bind") { binds().count == 1 }
            core.emit(.boardView, scope: "ios-board-test", skipSequence: true) { $0.boardView = ClientBoardViewSlice() }
            // The resubscribed surface starts unbound.
            core.emit(.boardView, scope: "ios-board-test") { $0.boardView = ClientBoardViewSlice() }
            try await eventually("the second bind") { binds().count == 2 }
            XCTAssertEqual(binds(), ["b1", "b1"])
        }

        func testEveryBoardViewOwnsItsScope() {
            let core = ScriptedCoreClient()
            let first = BoardViewModel(scope: "ios-board-first")
            let second = BoardViewModel(scope: "ios-board-second")
            XCTAssertNotEqual(first.scope, second.scope)
            first.attach(core)
            second.attach(core)
            first.detach()
            XCTAssertFalse(core.isObserved(.boardView, scope: first.scope))
            XCTAssertTrue(core.isObserved(.boardView, scope: second.scope))
        }

        // MARK: - Conversation

        func testAConversationFoldsDeltasOnlyOntoASnapshot() {
            let core = ScriptedCoreClient()
            let model = IOSConversationModel(cardID: "c1", core: core)
            model.observe()
            XCTAssertTrue(core.isObserved(.conversation, scope: "c1"))
            core.emit(.conversation, scope: "c1") {
                $0.conversationDelta = .with { $0.upsertedMessages = [self.message("early")] }
            }
            XCTAssertNil(model.slice, "a delta without its snapshot is dropped")
            core.emit(.conversation, scope: "c1") {
                $0.conversation = .with {
                    $0.cardID = "c1"
                    $0.daemonID = "d1"
                    $0.messages = [self.message("m1")]
                }
            }
            core.emit(.conversation, scope: "c1") {
                $0.conversationDelta = .with {
                    $0.daemonID = "d1"
                    $0.upsertedMessages = [self.message("m2")]
                }
            }
            XCTAssertEqual(model.slice?.messages.map(\.id), ["m1", "m2"])
            XCTAssertNotNil(model.messages.byKey["m2"])
            XCTAssertEqual(model.daemonID, "d1")
            // A lost update drops the conversation until the next snapshot.
            core.emit(.conversation, scope: "c1", skipSequence: true) {
                $0.conversationDelta = .with { $0.upsertedMessages = [self.message("lost")] }
            }
            XCTAssertNil(model.slice)
            core.emit(.conversation, scope: "c1") { $0.failure = .with { $0.message = "The card no longer exists." } }
            XCTAssertEqual(model.error, "The card no longer exists.")
            model.close()
            XCTAssertFalse(core.isObserved(.conversation, scope: "c1"))
        }

        func testSendingUsesTheMessageTextAndClearsTheDraft() async {
            let core = ScriptedCoreClient()
            var shown: [String] = []
            let model = IOSConversationModel(cardID: "c1", core: core) { error in
                shown.append((error as? CoreFailure)?.message ?? "\(error)")
            }
            let attachment = Dieter_V1_MessagePart.with {
                $0.type = "file"
                $0.filename = "notes.txt"
                $0.mediaType = "text/plain"
                $0.data = Data("notes".utf8)
            }
            model.draftText = "  Fix the build  "
            model.draftAttachments = [attachment]
            await model.send()
            let sent = commands(core) { if case .sendMessage(let send) = $0 { send } else { nil } }
            XCTAssertEqual(sent.count, 1)
            XCTAssertEqual(sent.first?.cardID, "c1")
            // The core trims the text and places it ahead of the attachments.
            XCTAssertEqual(sent.first?.text, "  Fix the build  ")
            XCTAssertEqual(sent.first?.parts, [attachment])
            XCTAssertEqual(model.draftText, "")
            XCTAssertTrue(model.draftAttachments.isEmpty)

            core.handler = { _ in throw CoreFailure(kind: .permanent, message: "The machine is offline.") }
            model.draftText = "Again"
            await model.send()
            XCTAssertEqual(model.draftText, "Again", "a refused message stays in the composer")
            XCTAssertEqual(shown, ["The machine is offline."])
        }

        // MARK: - Files, terminals, and screens

        func testFilesViewsBindTheirOwnSurfacesAndIgnoreOtherTargets() async throws {
            let core = ScriptedCoreClient()
            let first = IOSFilesModel(scope: "ios-files-a")
            let second = IOSFilesModel(scope: "ios-files-b")
            let target = WorkspaceTarget(endpointID: IOSAppModel.endpointID(daemonID: "d1"), projectID: "p1")
            first.bind(target: target, core: core)
            second.bind(target: target, core: core)
            XCTAssertTrue(core.isObserved(.files, scope: "ios-files-a"))
            XCTAssertTrue(core.isObserved(.files, scope: "ios-files-b"))
            func binds() -> [ClientFilesCommand] {
                commands(core) {
                    if case .files(let command) = $0, case .bind = command.action { command } else { nil }
                }
            }
            try await eventually("both binds") { binds().count == 2 }
            XCTAssertEqual(Set(binds().map(\.scope)), ["ios-files-a", "ios-files-b"])
            XCTAssertEqual(binds().map(\.bind.daemonID), ["d1", "d1"])

            core.emit(.files, scope: "ios-files-a") {
                $0.files = .with {
                    $0.target = .with {
                        $0.daemonID = "d2"
                        $0.projectID = "p1"
                    }
                    $0.directory = "stale"
                }
            }
            XCTAssertEqual(first.filePath, "", "a listing for another target is stale")
            core.emit(.files, scope: "ios-files-a") {
                $0.files = .with {
                    $0.target = .with {
                        $0.daemonID = "d1"
                        $0.projectID = "p1"
                    }
                    $0.directory = "Sources"
                }
            }
            XCTAssertEqual(first.filePath, "Sources")
            XCTAssertEqual(second.filePath, "")
        }

        func testTerminalViewsBindTheMachinesOwnSurface() async throws {
            let core = ScriptedCoreClient()
            let model = TerminalsModel(scope: "ios-terminals-a")
            model.bind(
                target: WorkspaceTarget(endpointID: IOSAppModel.endpointID(daemonID: "d1"), projectID: ""), core: core)
            XCTAssertTrue(core.isObserved(.terminals, scope: "ios-terminals-a"))
            func binds() -> [ClientTerminalsCommand] {
                commands(core) {
                    if case .terminals(let command) = $0, case .bind = command.action { command } else { nil }
                }
            }
            try await eventually("the bind") { binds().count == 1 }
            XCTAssertEqual(binds().first?.scope, "ios-terminals-a")
            XCTAssertEqual(binds().first?.bind.daemonID, "d1")
            XCTAssertEqual(binds().first?.bind.kind, .machine)
        }

        func testAScreenIsObservedBeforeItConnectsAndClosingReleasesItsScope() async {
            let core = ScriptedCoreClient()
            let controller = IOSScreenController(core: core, media: nil)
            controller.connect(daemonID: "d1")
            XCTAssertTrue(core.isObserved(.screen, scope: controller.session.scope))
            await controller.settle()
            func sent() -> [ClientScreenCommand] {
                commands(core) { if case .screen(let command) = $0 { command } else { nil } }
            }
            guard case .connect(let connect) = sent().first?.action else { return XCTFail("\(sent())") }
            XCTAssertEqual(connect.daemonID, "d1")
            XCTAssertEqual(sent().first?.scope, controller.session.scope)

            core.emit(.screen, scope: controller.session.scope) {
                $0.screen = .with {
                    $0.phase = "streaming"
                    $0.phaseLabel = "Live"
                    $0.active = true
                }
            }
            XCTAssertTrue(controller.streaming)
            XCTAssertEqual(controller.phaseLabel, "Live")

            controller.close()
            XCTAssertFalse(core.isObserved(.screen, scope: controller.session.scope))
            await controller.settle()
            guard case .disconnect = sent().last?.action else { return XCTFail("\(sent())") }
            // A closed view sends nothing more.
            let count = sent().count
            controller.refresh()
            await controller.settle()
            XCTAssertEqual(sent().count, count)
        }
    }
#endif
