import DieterAPI
import Foundation
import SharedCore
import Testing
@testable import DieterMac

/// The Mac session adapts the shared core's slices and commands; these feed
/// a scripted core and check what views read and what the core is asked.
@MainActor
struct CoreSessionAdapterTests {
    let core = ScriptedCoreClient()
    let store: DieterStore

    init() {
        store = DieterStore(core: core, liveEnvironment: false)
    }

    func commands<Value>(_ match: (ClientCommand.OneOf_Command) -> Value?) -> [Value] {
        core.commands.compactMap { $0.command.flatMap(match) }
    }

    @Test func runningATodoCardAsksTheCoreToStartIt() async throws {
        var card = Dieter_V1_Card()
        card.id = "c_task"
        card.projectID = "p_dieter"
        card.boardID = "b_main"
        card.lane = "todo"
        await store.start(card)
        let start = try #require(commands { if case .startCard(let start) = $0 { start } else { nil } }.first)
        #expect(start.cardID == card.id)
        #expect(!start.hasDraftAttachments_p)
        // The core reports the start until the machine confirms it.
        store.foldBoard(.with { $0.operations = [card.id: "STARTING"] })
        await store.start(card)
        #expect(commands { if case .startCard(let start) = $0 { start } else { nil } }.count == 1)
    }

    @Test func theReasoningPreferenceFollowsTheSessionAndTogglesThroughTheCore() async throws {
        store.foldSession(.with { $0.showReasoning = true })
        #expect(store.showReasoning, "Settings shows the preference without an open conversation")
        #expect(commands { if case .setShowReasoning(let set) = $0 { set } else { nil } }.isEmpty)
        // An unrelated update that still carries the old value keeps a toggle on its way to the core.
        store.showReasoning = false
        store.foldSession(
            .with {
                $0.showReasoning = true; $0.phaseLabel = "Connected"
            })
        #expect(!store.showReasoning)
        func sent() -> [Bool] { commands { if case .setShowReasoning(let set) = $0 { set.show } else { nil } } }
        for _ in 0..<100 where sent().isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(sent() == [false])
    }

    @Test func pinningAChatIsACoreCommandShownFromTheWorkspace() async {
        var chat = Dieter_V1_Card()
        chat.id = "c_chat"
        chat.projectID = "p_dieter"
        chat.scope = "chat"
        var project = Dieter_V1_Project()
        project.id = chat.projectID
        var state = Dieter_V1_State()
        state.projects = [project]
        state.chats = [chat]
        store.foldFixture(state)
        await store.pin(chat, pinned: true)
        #expect(commands { if case .setCardPinned(let pin) = $0 { pin.pinned } else { nil } } == [true])
        chat.pinned = true
        state.chats = [chat]
        store.foldFixture(state)
        #expect(store.chats.first?.pinned == true)
        // Pinning what is already pinned asks nothing.
        await store.pin(chat, pinned: true)
        #expect(commands { if case .setCardPinned(let pin) = $0 { pin.pinned } else { nil } } == [true])
    }

    @Test func failedCreationIsDistinguishedFromAFailedTurn() {
        store.foldOutbox(
            .with {
                $0.pendingCardIds = ["local_chat"]
                $0.pendingMessageIds = ["local_message"]
                $0.failedIds = ["local_chat", "local_message"]
                $0.failures = ["local_chat": "model is not supported by this daemon", "local_message": "turn failed"]
            })
        #expect(store.failedCreationError("local_chat") == "model is not supported by this daemon")
        #expect(store.failedCreationError("local_message") == nil)
        #expect(!store.isConversationServerBacked("local_chat"))
        #expect(store.isFailedOutboxItem("local_message"))
    }

    @Test func machineQueuesShowWhatTheCoreSaysIsWaiting() {
        let machine = MachineEndpoint(
            name: "Offline", host: "gateway.getdieter.com", port: 443, secure: true, daemonID: "d_offline",
            online: false)
        store.endpoints = [machine]
        store.machineEntries[machine.id] = .with {
            $0.id = "d_offline"
            $0.detail = "Offline"
        }
        store.foldOutbox(
            .with {
                $0.machines = [
                    .with {
                        $0.daemonID = "d_offline"
                        $0.messageCount = 1
                        $0.changeCount = 1
                        $0.phase = .retrying
                        $0.title = "Retrying delivery to Offline"
                        $0.statusSuffix = " · retrying"
                    }
                ]
            })
        #expect(store.outbox(for: machine)?.title == "Retrying delivery to Offline")
        #expect(store.outbox(for: machine)?.phase == .retrying)
        #expect(store.machineStatusLine(machine) == "Offline · retrying")
        store.foldOutbox(
            .with {
                $0.failedOperations = [
                    .with {
                        $0.id = "local_card"
                        $0.label = "Create card"
                        $0.targetID = "local_card"
                        $0.failure = "The machine rejected the request."
                        $0.createdAtMillis = 1_000
                    }
                ]
            })
        #expect(store.failedOutboxItems.map(\.operation) == ["Create card"])
        store.foldOutbox(ClientOutboxSlice())
        #expect(store.outbox(for: machine) == nil)
    }

    @Test func theSessionSliceBecomesTheMachinesAndPhaseViewsRead() async throws {
        let session = ClientSessionSlice.with {
            $0.phase = .connected
            $0.gatewayOrigin = "https://gateway.getdieter.com:443"
            $0.gateways = [
                .with {
                    $0.origin = "https://gateway.getdieter.com:443"; $0.name = "Dieter Gateway"; $0.active = true
                }
            ]
            $0.machines = [
                .with {
                    $0.id = "d_mac"; $0.name = "Mac"; $0.online = true; $0.route = "Local"; $0.local = true
                    $0.releaseVersion = "0.4.340"
                    $0.compatible = true
                    $0.detail = "Local · 3 ms"; $0.available = true
                    $0.syncState = .live; $0.syncLabel = "Live"
                },
                .with {
                    $0.id = "d_old"; $0.name = "Old"; $0.online = true; $0.route = "Relay"
                    $0.compatible = false
                    $0.detail = "Update required · Dieter 0.4.1 (requires 0.4.300)"
                    $0.unavailableMessage = "Dieter 0.4.1 needs an update to 0.4.300."
                    $0.syncState = .incompatible; $0.syncLabel = "Update required"
                },
            ]
            $0.updatedAtMillis = 1_000
            $0.synced = true
            $0.phaseLabel = "Connected"
        }
        store.foldSession(session)
        #expect(store.phase == .connected)
        #expect(store.activeGateway.credentialID == "https://gateway.getdieter.com:443")
        #expect(store.activeGateway.name == "Dieter Gateway")
        #expect(store.machines.map(\.name) == ["Mac", "Old"])
        let mac = try #require(store.localMachine)
        #expect(mac.daemonID == "d_mac")
        #expect(store.machineEntry(mac)?.route == "Local")
        #expect(store.machineStatusLine(mac) == "Local · 3 ms")
        let old = try #require(store.endpoints.first { $0.daemonID == "d_old" })
        // The machine list shows the core's own wording.
        #expect(store.machineStatusLine(old) == "Update required · Dieter 0.4.1 (requires 0.4.300)")
        #expect(!store.machineIsAvailable(old))
        #expect(store.unavailableReason(old) == "Dieter 0.4.1 needs an update to 0.4.300.")
        #expect(store.unavailableReason(mac) == nil)
        #expect(store.workspaceIsLive)
        #expect(store.lastSyncedAt == Date(timeIntervalSince1970: 1))

        // Every machine that can take work has its agents read once per connection.
        func requested() -> [String] { commands { if case .ensureMetadata(let read) = $0 { read.daemonID } else { nil } } }
        for _ in 0..<100 where requested().isEmpty { await Task.yield() }
        store.foldSession(session)
        for _ in 0..<10 { await Task.yield() }
        #expect(requested() == ["d_mac"])

        store.foldSession(
            .with {
                $0.phase = .authRequired
                $0.gatewayOrigin = "https://gateway.getdieter.com:443"
            })
        #expect(store.phase == .authenticationRequired)
        #expect(store.machines.isEmpty)
        #expect(store.localMachine == nil)
        #expect(store.lastSyncedAt == nil)
    }

    @Test func boardMovesAreCommandsWhoseOverlayComesFromTheCore() async {
        var card = Dieter_V1_Card()
        card.id = "c_card"
        card.projectID = "p"
        card.boardID = "b"
        card.lane = "todo"
        await store.move(card, lane: "review", afterCardID: "c_before")
        let move = commands { if case .moveCard(let move) = $0 { move } else { nil } }.first
        #expect(move?.lane == "review" && move?.afterCardID == "c_before")
        store.foldBoard(
            .with {
                $0.moves = [.with { $0.cardID = card.id }]
            })
        #expect(store.movingCardIDs == [card.id])
        // A second move while one is unconfirmed is not sent.
        await store.move(card, lane: "done")
        #expect(commands { if case .moveCard(let move) = $0 { move } else { nil } }.count == 1)
        store.foldBoard(ClientBoardSlice())
        #expect(store.movingCardIDs.isEmpty)
    }

    @Test func finishingACardLetsTheCoreFindItsBoardsDoneLane() async {
        var card = Dieter_V1_Card()
        card.id = "c_review"
        card.projectID = "p"
        card.boardID = "b"
        card.lane = "review"
        await store.finish(card)
        #expect(commands { if case .finishCard(let finish) = $0 { finish.cardID } else { nil } } == [card.id])
        #expect(commands { if case .moveCard(let move) = $0 { move } else { nil } }.isEmpty)
        // A card that is already moving is not finished again.
        store.foldBoard(
            .with {
                $0.moves = [.with { $0.cardID = card.id }]
            })
        await store.finish(card)
        #expect(commands { if case .finishCard(let finish) = $0 { finish.cardID } else { nil } }.count == 1)
    }

    @Test func aCreatedConversationIsSelectedUnderItsServerIDOnceAccepted() async {
        core.handler = { command in
            switch command.command {
            case .createConversation:
                .with {
                    $0.card = .with {
                        $0.id = "local_chat"; $0.scope = "chat"
                    }
                }
            default: .with { $0.done = ClientDone() }
            }
        }
        #expect(await store.createConversation(.with { $0.prompt = "hi" }, chat: true))
        #expect(store.selectedChatID == "local_chat")
        #expect(core.isObserved(.conversation, scope: "local_chat"))
        store.foldOutbox(.with { $0.resolutions = ["local_chat": "c_chat"] })
        #expect(store.selectedChatID == "c_chat")
    }

    @Test func heldFoldsKeepFixturesUntilReleased() async {
        await store.startCore()
        #expect(core.isObserved(.session) && core.isObserved(.workspace) && core.isObserved(.outbox))
        store.coreFoldsHeld = true
        let injected = MachineEndpoint(name: "Fixture", host: "h", port: 1, daemonID: "d_fixture")
        store.endpoints = [injected]
        core.emit(.session) { $0.session = .with { $0.phase = .connecting } }
        #expect(store.endpoints == [injected])
        store.coreFoldsHeld = false
        #expect(store.endpoints.isEmpty)
        #expect(store.phase == .connecting)
    }

    @Test func navigationLayoutShowsTheCoreAndSendsEachUserEditInOrder() async {
        store.foldNavigation(
            .with {
                $0.projects = .with {
                    $0.order = ["b", "a"]
                    $0.expanded = ["a"]
                    $0.folders = [
                        .with {
                            $0.id = "f"; $0.name = "Work"; $0.itemIds = ["a"]; $0.expanded = true
                        }
                    ]
                    $0.unfiled = ["b"]
                }
                $0.collapsedChatSections = ["a"]
                $0.pending = 2
            })
        #expect(store.navigation.projects.order == ["b", "a"])
        #expect(store.navigation.projects.folders.map(\.name) == ["Work"])
        #expect(store.navigation.collapsedChatSections == ["a"])
        #expect(store.navigationPendingCount == 2)
        #expect(core.commands.isEmpty, "showing the core sends nothing back")

        store.moveProject("a", before: "b", ungrouped: false)
        store.setProjectExpanded("b", expanded: true)
        store.setChatSectionCollapsed("a", collapsed: false)
        store.toggleLaneSort(
            board: "b1",
            lane: .with {
                $0.laneID = "todo"; $0.descending = false
            })
        await store.navigationEditTail?.value
        let sent = core.commands.compactMap { command -> String? in
            switch command.command {
            case .navigation(let edit):
                if case .moveProject(let move)? = edit.action {
                    "move \(move.projectID) before \(move.beforeProjectID)"
                } else {
                    nil
                }
            case .setProjectExpanded(let flag): "expand \(flag.projectID) \(flag.expanded)"
            case .setChatSectionCollapsed(let flag): "collapse \(flag.projectID) \(flag.collapsed)"
            case .setLaneDescending(let sort): "lane \(sort.boardID).\(sort.laneID) \(sort.descending)"
            default: nil
            }
        }
        #expect(sent == ["move a before b", "expand b true", "collapse a false", "lane b1.todo true"])
    }

    @Test func creationMemoryFillsTheQuickTaskFormAndRemembersItsDestinationAndCheckout() async {
        store.foldCreation(
            .with {
                $0.projectID = "p"
                $0.boards = ["p": "b", "q": "c"]
                $0.checkouts = ["p": "co_p"]
            })
        #expect(store.quickTaskForm.draftProjectID == "p" && store.quickTaskForm.draftBoardID == "b")
        #expect(commands { if case .rememberCreation(let remember) = $0 { remember } else { nil } }.isEmpty)
        // A project takes the board the core preselects there.
        store.quickTaskForm.selectProject("q", in: store.creationMemory)
        #expect(store.quickTaskForm.draftBoardID == "c")
        store.pickCheckout(
            .with {
                $0.id = "co_q"; $0.projectID = "q"
            })
        try? await Task.sleep(for: .milliseconds(50))
        let remembered = commands { if case .rememberCreation(let remember) = $0 { remember } else { nil } }
        #expect(remembered.contains { $0.projectID == "q" && $0.boardID == "c" })
        #expect(remembered.contains { $0.projectID == "q" && $0.checkoutID == "co_q" })
    }
}
