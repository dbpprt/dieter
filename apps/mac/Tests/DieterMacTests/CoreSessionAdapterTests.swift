import DieterAPI
import DieterCore
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
        store = DieterStore(core: core, restoreSync: false)
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
        #expect(store.pendingCardStarts[card.id] != nil)
        await store.start(card)
        #expect(commands { if case .startCard(let start) = $0 { start } else { nil } }.count == 1)
        store.foldBoard(ClientBoardSlice())
        #expect(store.pendingCardStarts[card.id] == nil)
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

    @Test func machineQueuesShowWhatIsWaitingAndWhy() {
        let machine = DieterEndpoint(
            name: "Offline", host: "gateway.getdieter.com", port: 443, secure: true, daemonID: "d_offline",
            online: false)
        store.endpoints = [machine]
        store.foldOutbox(
            .with {
                $0.machines = [
                    .with {
                        $0.daemonID = "d_offline"
                        $0.pending = 2
                        $0.messageCount = 1
                        $0.changeCount = 1
                        $0.retrying = true
                    }
                ]
            })
        let summary = store.outboxSummary(for: machine)
        #expect(summary?.queuedLabel == "2 items queued")
        #expect(summary?.deliveryLabel == "2 items queued — delivers when it reconnects.")
        #expect(summary?.toastPhase(machineOnline: false) == .retrying)
        store.foldOutbox(
            .with {
                $0.machines = [
                    .with {
                        $0.daemonID = "d_offline"
                        $0.pending = 1
                        $0.failed = 1
                        $0.changeCount = 1
                        $0.lastError = "The machine rejected the request."
                    }
                ]
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
        #expect(store.outboxSummary(for: machine)?.toastPhase(machineOnline: true) == .failed)
        #expect(store.outboxSummary(for: machine)?.failureMessage == "The machine rejected the request.")
        #expect(store.failedOutboxItems.map(\.operation) == ["Create card"])
        store.foldOutbox(ClientOutboxSlice())
        #expect(store.outboxSummary(for: machine) == nil)
    }

    @Test func theSessionSliceBecomesTheMachinesAndPhaseViewsRead() throws {
        store.foldSession(
            .with {
                $0.phase = .connected
                $0.gatewayOrigin = "https://gateway.getdieter.com:443"
                $0.gateways = [
                    .with {
                        $0.origin = "https://gateway.getdieter.com:443"; $0.name = "Dieter Gateway"; $0.active = true
                    }
                ]
                $0.attachedMachineID = "d_mac"
                $0.machines = [
                    .with {
                        $0.id = "d_mac"; $0.name = "Mac"; $0.online = true; $0.attached = true; $0.route = "Local"
                        $0.routeLatencyMillis = 3; $0.releaseVersion = "0.4.340"
                        $0.compatibility = "COMPATIBILITY_STATUS_COMPATIBLE"
                    },
                    .with {
                        $0.id = "d_old"; $0.name = "Old"; $0.online = true; $0.route = "Relay"
                        $0.compatibility = "COMPATIBILITY_STATUS_UPDATE_REQUIRED";
                        $0.incompatibility = "Update required"
                        $0.syncWarnings = ["Shared updates are delayed"]
                    },
                ]
                $0.feed = .with {
                    $0.live = true; $0.daemonID = "d_mac"; $0.lastAppliedAtMillis = 1_000
                }
            })
        #expect(store.phase == .connected(version: "0.4.340"))
        #expect(store.endpoint.daemonID == "d_mac")
        #expect(store.endpoint.credentialID == "https://gateway.getdieter.com:443")
        #expect(store.machines.map(\.name) == ["Mac", "Old"])
        #expect(store.connectionStatus(for: store.endpoint)?.route == .local)
        let old = try #require(store.endpoints.first { $0.daemonID == "d_old" })
        #expect(store.connectionStatus(for: old)?.route == .gateway)
        #expect(old.compatibilityState == .incompatible)
        #expect(store.machineConnectionErrors[old.id] == "Update required")
        #expect(store.machineSyncIssues[old.id] == "Shared updates are delayed")
        #expect(!store.globalSyncing)
        #expect(store.lastSyncedAt == Date(timeIntervalSince1970: 1))
        store.foldSession(
            .with {
                $0.phase = .authRequired
                $0.gatewayOrigin = "https://gateway.getdieter.com:443"
            })
        #expect(store.phase == .authenticationRequired)
        #expect(store.endpoint.daemonID == nil)
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
                $0.moves = [
                    .with {
                        $0.cardID = card.id; $0.lane = "review"; $0.afterCardID = "c_before"
                    }
                ]
            })
        #expect(store.pendingCardMoves[card.id]?.lane == "review")
        #expect(store.movingCardIDs == [card.id])
        // A second move while one is unconfirmed is not sent.
        await store.move(card, lane: "done")
        #expect(commands { if case .moveCard(let move) = $0 { move } else { nil } }.count == 1)
        store.foldBoard(ClientBoardSlice())
        #expect(store.pendingCardMoves.isEmpty && store.movingCardIDs.isEmpty)
    }

    @Test func aCreatedConversationIsSelectedUnderItsServerIDOnceAccepted() async {
        core.handler = { command in
            guard case .createConversation = command.command else { return .with { $0.done = ClientDone() } }
            return .with {
                $0.card = .with {
                    $0.id = "local_chat"; $0.scope = "chat"
                }
            }
        }
        #expect(
            await store.createConversation(
                title: "chat", prompt: "hi", chat: true, provider: "mock", model: "mock", effort: "low", deferred: false
            ))
        #expect(store.selectedChatID == "local_chat")
        #expect(core.isObserved(.conversation, scope: "local_chat"))
        store.foldOutbox(.with { $0.resolutions = ["local_chat": "c_chat"] })
        #expect(store.selectedChatID == "c_chat")
    }

    @Test func heldFoldsKeepFixturesUntilReleased() async {
        await store.startCore()
        #expect(core.isObserved(.session) && core.isObserved(.workspace) && core.isObserved(.outbox))
        store.coreFoldsHeld = true
        let injected = DieterEndpoint(name: "Fixture", host: "h", port: 1, daemonID: "d_fixture")
        store.endpoints = [injected]
        core.emit(.session) { $0.session = .with { $0.phase = .connecting } }
        #expect(store.endpoints == [injected])
        store.coreFoldsHeld = false
        #expect(store.endpoints.isEmpty)
        #expect(store.phase == .connecting)
    }

    @Test func navigationLayoutMirrorsTheCoreAndSendsOnlyUserEditsInOrder() async {
        store.foldNavigation(
            .with {
                $0.projectOrder = ["b", "a"]
                $0.expandedProjects = ["a"]
                $0.projectFolders = [
                    .with {
                        $0.id = "f"; $0.name = "Work"; $0.itemIds = ["a"]; $0.expanded = true
                    }
                ]
                $0.pinnedChatOrder = ["c1"]
                $0.collapsedChatSections = ["a"]
                $0.laneSorts = ["b1.todo": "ascending"]
                $0.pending = 2
            })
        #expect(store.sidebarProjectNavigation.projectOrder == ["b", "a"])
        #expect(store.sidebarProjectNavigation.isExpanded("a"))
        #expect(store.sidebarProjectFolders.folders.map(\.name) == ["Work"])
        #expect(store.pinnedChatNavigation.chatOrder == ["c1"])
        #expect(store.chatProjectDisclosure.isCollapsed("a"))
        #expect(store.laneSortDirection(board: "b1", lane: "todo") == .ascending)
        #expect(store.laneSortDirection(board: "b1", lane: "done") == .descending)
        #expect(store.navigationPendingCount == 2)
        #expect(core.commands.isEmpty, "mirroring the core sends nothing back")

        store.sidebarProjectNavigation = SidebarProjectNavigationPreferences(
            projectOrder: ["a", "b"], expandedProjectIDs: ["a", "b"])
        store.toggleLaneSort(board: "b1", lane: "todo")
        #expect(store.laneSortDirection(board: "b1", lane: "todo") == .descending, "shown before the core confirms")
        await store.navigationEditTail?.value
        let sent = core.commands.compactMap { command -> String? in
            switch command.command {
            case .setProjectOrder(let order): "order \(order.projectIds)"
            case .setProjectExpanded(let flag): "expand \(flag.projectID) \(flag.expanded)"
            case .setLaneDescending(let sort): "lane \(sort.boardID).\(sort.laneID) \(sort.descending)"
            default: nil
            }
        }
        #expect(sent == ["order [\"a\", \"b\"]", "expand b true", "lane b1.todo true"])
    }

    @Test func creationMemoryFillsTheQuickTaskFormAndRemembersItsChanges() async {
        store.foldCreation(
            .with {
                $0.selection = .with {
                    $0.provider = "mock"; $0.model = "fast"; $0.effort = "low"
                }
                $0.workspaceMode = "project"
                $0.projectID = "p"
                $0.boards = ["p": "b"]
            })
        #expect(store.quickTaskForm.provider == "mock" && store.quickTaskForm.draftBoardID == "b")
        #expect(store.creationPreferences.workspaceMode == .project)
        #expect(commands { if case .rememberCreation(let remember) = $0 { remember } else { nil } }.isEmpty)
        store.quickTaskForm.model = "smart"
        store.rememberCreation(
            ConversationCreationPreferences(provider: "mock", model: "smart", workspaceMode: .worktree))
        try? await Task.sleep(for: .milliseconds(50))
        let remembered = commands { if case .rememberCreation(let remember) = $0 { remember } else { nil } }
        #expect(remembered.first?.selection.model == "smart")
        #expect(remembered.contains { $0.workspaceMode == "worktree" })
    }
}
