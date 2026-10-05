import Testing
import DieterAPI
import AppKit
import Foundation
import Observation
import SwiftUI
import SharedCore
import SwiftTerm
import UniformTypeIdentifiers
@testable import DieterMac

@Test func gpuTelemetryKeepsUnavailableValuesDistinctFromRealZeroes() {
    var gpu = Dieter_V1_GPUDevice()
    gpu.id = "gpu0"
    gpu.name = "Apple M4"
    gpu.vendor = .apple
    gpu.memoryKind = .unified
    #expect(!gpu.hasUtilizationPercent)
    #expect(!gpu.hasMemoryTotalBytes)

    gpu.utilizationPercent = 0
    gpu.memoryUsedBytes = 0
    #expect(gpu.hasUtilizationPercent)
    #expect(gpu.hasMemoryUsedBytes)
    #expect(gpu.utilizationPercent == 0)
}

@Test func projectSetupBuildsExistingAndNewGitRequests() {
    var draft = ProjectSetupDraft()
    draft.mode = .existing
    draft.path = "  /srv/repo  "
    draft.name = "  Atlas  "
    draft.summary = "  Main service  "
    draft.prompt = "  Preserve local changes.  "
    draft.boardName = "  Delivery  "
    draft.workflow = "direct"

    let existing = draft.request()
    #expect(existing.mode == "open")
    #expect(existing.path == "/srv/repo")
    #expect(existing.name == "Atlas")
    #expect(existing.summary == "Main service")
    #expect(existing.prompt == "Preserve local changes.")
    #expect(existing.boardName == "Delivery")
    #expect(existing.workflow == "direct")

    draft.mode = .newRepository
    #expect(draft.request().mode == "create")
}

@Test func remoteProjectPathsSupportDaemonSeparatorsAndSafeFolderNames() {
    #expect(RemoteProjectPath.lastComponent("/srv/worktrees/feature/") == "feature")
    #expect(RemoteProjectPath.lastComponent("C:\\src\\feature") == "feature")
    #expect(RemoteProjectPath.joining("/srv/projects", "atlas", separator: "/") == "/srv/projects/atlas")
    #expect(RemoteProjectPath.joining("C:\\src\\", "atlas", separator: "\\") == "C:\\src\\atlas")
    #expect(RemoteProjectPath.parentAndName("/srv/projects/atlas") == ("/srv/projects", "atlas"))
    #expect(RemoteProjectPath.validDirectoryName("atlas"))
    #expect(!RemoteProjectPath.validDirectoryName(".."))
    #expect(!RemoteProjectPath.validDirectoryName("feature/one"))
    #expect(!RemoteProjectPath.validDirectoryName("feature\\one"))
}

@Test func projectNameSuggestionNeverOverwritesACustomName() {
    let initial = RemoteProjectPath.updatingSuggestedName(
        currentName: "", previousSuggestion: "", path: "/srv/atlas"
    )
    #expect(initial.name == "atlas")
    #expect(initial.suggestion == "atlas")

    let automatic = RemoteProjectPath.updatingSuggestedName(
        currentName: initial.name, previousSuggestion: initial.suggestion, path: "/srv/orion"
    )
    #expect(automatic.name == "orion")

    let custom = RemoteProjectPath.updatingSuggestedName(
        currentName: "Customer API", previousSuggestion: automatic.suggestion, path: "/srv/gateway"
    )
    #expect(custom.name == "Customer API")
    #expect(custom.suggestion == "gateway")
}

@Test func remoteDesktopInputGeometryExcludesLetterboxingAndUsesTopLeftCoordinates() throws {
    let bounds = CGRect(x: 0, y: 0, width: 1_000, height: 1_000)
    let video = CGSize(width: 1_600, height: 900)
    #expect(
        RemoteDesktopInputGeometry.normalized(
            point: CGPoint(x: 500, y: 100), bounds: bounds, videoSize: video) == nil)
    let topLeft = try #require(
        RemoteDesktopInputGeometry.normalized(
            point: CGPoint(x: 0, y: 781.24), bounds: bounds, videoSize: video))
    #expect(abs(topLeft.x) < 0.0001)
    #expect(abs(topLeft.y) < 0.0001)
    let center = try #require(
        RemoteDesktopInputGeometry.normalized(
            point: CGPoint(x: 500, y: 500), bounds: bounds, videoSize: video))
    #expect(abs(center.x - 0.5) < 0.0001)
    #expect(abs(center.y - 0.5) < 0.0001)
}

private actor ScheduleRPCStub: DieterScheduleRPC {
    let schedulesResponses: [String: Dieter_V1_SchedulesResponse]
    let runsResponses: [String: Dieter_V1_ScheduleRunsResponse]
    private var requestedProjectIDs: [String] = []
    private var requestedScheduleIDs: [String] = []
    private var requestedScheduleTokens: [String] = []
    private var requestedRunTokens: [String] = []
    private var requestedPageSizes: [Int32] = []

    init(schedules: [Dieter_V1_Schedule], runs: [Dieter_V1_ScheduleRun]) {
        var schedulesResponse = Dieter_V1_SchedulesResponse()
        schedulesResponse.schedules = schedules
        self.schedulesResponses = ["": schedulesResponse]
        var runsResponse = Dieter_V1_ScheduleRunsResponse()
        runsResponse.runs = runs
        self.runsResponses = ["": runsResponse]
    }

    init(schedulePages: [String: Dieter_V1_SchedulesResponse], runPages: [String: Dieter_V1_ScheduleRunsResponse]) {
        schedulesResponses = schedulePages
        runsResponses = runPages
    }

    func schedules(projectID: String, pageSize: Int32, pageToken: String) async throws -> Dieter_V1_SchedulesResponse {
        requestedProjectIDs.append(projectID)
        requestedScheduleTokens.append(pageToken)
        requestedPageSizes.append(pageSize)
        return schedulesResponses[pageToken] ?? Dieter_V1_SchedulesResponse()
    }

    func scheduleRuns(id: String, pageSize: Int32, pageToken: String) async throws -> Dieter_V1_ScheduleRunsResponse {
        requestedScheduleIDs.append(id)
        requestedRunTokens.append(pageToken)
        requestedPageSizes.append(pageSize)
        return runsResponses[pageToken] ?? Dieter_V1_ScheduleRunsResponse()
    }

    func requests() -> (
        projects: [String], schedules: [String], scheduleTokens: [String], runTokens: [String], pageSizes: [Int32]
    ) {
        (requestedProjectIDs, requestedScheduleIDs, requestedScheduleTokens, requestedRunTokens, requestedPageSizes)
    }
}

@Test @MainActor func schedulesLoadThroughTheirOwnSurfaceWithoutWaitingForGlobalSync() async {
    var schedule = Dieter_V1_Schedule()
    schedule.id = "s_morning"
    schedule.projectID = "p_dieter"
    schedule.name = "Morning"
    var run = Dieter_V1_ScheduleRun()
    run.id = "sr_morning"
    run.scheduleID = schedule.id
    let rpc = ScheduleRPCStub(schedules: [schedule], runs: [run])
    let store = DieterStore(core: SchedulesCoreDouble.core(reader: rpc), liveEnvironment: false)
    store.selectedProjectID = schedule.projectID

    await store.loadSchedules()

    #expect(store.schedules.map(\.id) == [schedule.id])
    #expect(store.schedulesModel.selectedScheduleID == schedule.id)
    #expect(store.schedulesModel.scheduleRuns.map(\.id) == [run.id])
    #expect(store.schedulesModel.schedulesAreLoaded)
    #expect(!store.schedulesModel.schedulesLoading)
    #expect(!store.schedulesModel.scheduleRunsLoading)
    let requests = await rpc.requests()
    #expect(requests.projects == [schedule.projectID])
    #expect(requests.schedules == [schedule.id])
}

@Test @MainActor func schedulesAndOccurrenceHistoryAppendCursorPages() async {
    var morning = Dieter_V1_Schedule(); morning.id = "s_morning"; morning.projectID = "p_dieter";
    morning.name = "Morning"
    var nightly = Dieter_V1_Schedule(); nightly.id = "s_nightly"; nightly.projectID = morning.projectID;
    nightly.name = "Nightly"
    var firstSchedules = Dieter_V1_SchedulesResponse()
    firstSchedules.schedules = [morning]; firstSchedules.nextPageToken = "s-next"; firstSchedules.totalCount = 2
    var secondSchedules = Dieter_V1_SchedulesResponse()
    secondSchedules.schedules = [nightly]; secondSchedules.totalCount = 2

    var newest = Dieter_V1_ScheduleRun(); newest.id = "sr_new"; newest.scheduleID = morning.id
    var older = Dieter_V1_ScheduleRun(); older.id = "sr_old"; older.scheduleID = morning.id
    var firstRuns = Dieter_V1_ScheduleRunsResponse()
    firstRuns.runs = [newest]; firstRuns.nextPageToken = "r-next"
    var secondRuns = Dieter_V1_ScheduleRunsResponse(); secondRuns.runs = [older]

    let rpc = ScheduleRPCStub(
        schedulePages: ["": firstSchedules, "s-next": secondSchedules],
        runPages: ["": firstRuns, "r-next": secondRuns]
    )
    let store = DieterStore(core: SchedulesCoreDouble.core(reader: rpc), liveEnvironment: false)
    store.selectedProjectID = morning.projectID

    await store.loadSchedules()
    await store.schedulesModel.loadMoreSchedules()
    await store.schedulesModel.loadMoreScheduleRuns()

    #expect(store.schedules.map(\.id) == [morning.id, nightly.id])
    #expect(store.schedulesModel.schedulesTotalCount == 2)
    #expect(store.schedulesModel.schedulesNextPageToken.isEmpty)
    #expect(store.schedulesModel.scheduleRuns.map(\.id) == [newest.id, older.id])
    #expect(store.schedulesModel.scheduleRunsNextPageToken.isEmpty)
    let requests = await rpc.requests()
    #expect(requests.scheduleTokens == ["", "s-next"])
    #expect(requests.runTokens == ["", "r-next"])
    #expect(requests.pageSizes == [50, 50, 50, 50])
}

@Test func daemonEndpointKeepsHostnamePresenceAndGatewayCredentialIdentity() throws {
    let endpoint = MachineEndpoint(
        name: "Studio Mac",
        host: "dieter.example",
        port: 443,
        secure: true,
        daemonID: "daemon-1",
        online: false,
        lastSeenAt: "2026-08-18T12:00:00Z",
        releaseVersion: "0.4.92",
        minimumReleaseVersion: "0.4.80"
    )
    #expect(endpoint.id == "https://dieter.example:443#daemon-1")
    #expect(endpoint.credentialID == "https://dieter.example:443")
    #expect(endpoint.name == "Studio Mac")
    #expect(!endpoint.online)
    // The core's origins round-trip; anything else is not a gateway.
    let gateway = MachineEndpoint(origin: "https://dieter.example:443", name: "Gateway")
    #expect(gateway?.credentialID == endpoint.credentialID)
    #expect(MachineEndpoint(origin: "http://::1:4242", name: "Local")?.host == "::1")
    #expect(MachineEndpoint(origin: "", name: "None") == nil)
}

@Test func cardDragPayloadRejectsUnrelatedText() {
    let encoded = BoardCardDragPayload(cardID: "c_123", boardID: "b_456", sourceLane: "todo").encoded
    #expect(BoardCardDragPayload(encoded)?.cardID == "c_123")
    #expect(BoardCardDragPayload("ordinary text") == nil)
}

@Test func labelDragPayloadIsScopedToItsBoard() {
    let encoded = BoardLabelDragPayload(labelID: "l_123", boardID: "b_456").encoded
    let payload = BoardLabelDragPayload(encoded)

    #expect(payload?.labelID == "l_123")
    #expect(payload?.boardID == "b_456")
    #expect(BoardLabelDragPayload("ordinary text") == nil)
    #expect(BoardLabelDragPayload("board-label||l_123") == nil)
}

@Test func shiftReturnCreatesANewlineAndPlainReturnSends() {
    #expect(ComposerReturnPolicy.sendsMessage(shiftPressed: false))
    #expect(!ComposerReturnPolicy.sendsMessage(shiftPressed: true))
}

@Test func composerHistoryWalksBackwardAndReturnsToThePreservedDraft() {
    let entries = ["First prompt", "Second prompt", "Third prompt"]
    var navigation = ComposerHistoryNavigation()

    #expect(navigation.navigate(.older, entries: entries, currentText: "unfinished draft") == "Third prompt")
    #expect(navigation.navigate(.older, entries: entries, currentText: "Third prompt") == "Second prompt")
    #expect(navigation.navigate(.older, entries: entries, currentText: "Second prompt") == "First prompt")
    #expect(navigation.navigate(.older, entries: entries, currentText: "First prompt") == "First prompt")
    #expect(navigation.navigate(.newer, entries: entries, currentText: "First prompt") == "Second prompt")
    #expect(navigation.navigate(.newer, entries: entries, currentText: "Second prompt") == "Third prompt")
    #expect(navigation.navigate(.newer, entries: entries, currentText: "Third prompt") == "unfinished draft")
    #expect(!navigation.isBrowsing)
    #expect(navigation.navigate(.newer, entries: entries, currentText: "unfinished draft") == nil)
}

@Test func composerHistoryUsesDeliveredUserTextAndStopsWhenEditing() {
    func message(_ id: String, role: String, text: String) -> Dieter_V1_UiMessage {
        var part = Dieter_V1_MessagePart(); part.type = "text"; part.text = text
        var message = Dieter_V1_UiMessage(); message.id = id; message.role = role; message.parts = [part]
        return message
    }
    var queued = Dieter_V1_QueuedMessage(); queued.id = "queued"
    let entries = ComposerHistoryNavigation.entries(
        messages: [
            message("one", role: "user", text: "First"),
            message("assistant", role: "assistant", text: "Answer"),
            message("queued", role: "user", text: "Still queued"),
            message("two", role: "human", text: "Second"),
        ],
        queuedMessages: [queued]
    )
    #expect(entries == ["First", "Second"])

    var navigation = ComposerHistoryNavigation()
    #expect(navigation.navigate(.older, entries: entries, currentText: "") == "Second")
    navigation.observeTextChange("Second, edited")
    #expect(!navigation.isBrowsing)
}

@Test func composerHistoryOnlyTakesOverAtMultilineEdges() {
    let text = "first line\nsecond line"
    #expect(ComposerHistoryNavigation.isAtBoundary(.older, text: text, selection: NSRange(location: 3, length: 0)))
    #expect(!ComposerHistoryNavigation.isAtBoundary(.older, text: text, selection: NSRange(location: 14, length: 0)))
    #expect(!ComposerHistoryNavigation.isAtBoundary(.newer, text: text, selection: NSRange(location: 3, length: 0)))
    #expect(ComposerHistoryNavigation.isAtBoundary(.newer, text: text, selection: NSRange(location: 14, length: 0)))
}

private func historyToolMessage(_ id: String) -> Dieter_V1_UiMessage {
    var part = Dieter_V1_MessagePart()
    part.type = "dynamic-tool"
    part.toolCallID = "call_\(id)"
    part.toolName = "Bash"
    var message = Dieter_V1_UiMessage()
    message.id = id
    message.role = "assistant"
    message.parts = [part]
    return message
}

private func historyTextMessage(_ id: String, role: String = "assistant") -> Dieter_V1_UiMessage {
    var part = Dieter_V1_MessagePart()
    part.type = "text"
    part.text = "message \(id)"
    var message = Dieter_V1_UiMessage()
    message.id = id
    message.role = role
    message.parts = [part]
    return message
}

@Test func conversationViewportTailsUntilTheUserDetaches() {
    let awaiting = ConversationViewportMode.awaitingInitial(conversationID: "chat-one")
    #expect(ConversationScrollBehavior.followsLatest(awaiting))
    #expect(!ConversationScrollBehavior.showsJumpToLatest(viewportMode: awaiting))
    #expect(!ConversationScrollBehavior.initialPositionComplete(awaiting))
    #expect(
        !ConversationScrollBehavior.initialPositionComplete(
            .awaitingInitial(conversationID: "a previous conversation")))

    let following = ConversationScrollBehavior.afterUserScroll(isAtLatest: true)
    #expect(following == .followingLatest)
    #expect(ConversationScrollBehavior.followsLatest(following))
    #expect(!ConversationScrollBehavior.showsJumpToLatest(viewportMode: following))
    #expect(ConversationScrollBehavior.initialPositionComplete(following))

    let detached = ConversationScrollBehavior.afterUserScroll(isAtLatest: false)
    #expect(detached == .detached)
    #expect(!ConversationScrollBehavior.followsLatest(detached))
    #expect(ConversationScrollBehavior.showsJumpToLatest(viewportMode: detached))

    #expect(ConversationScrollBehavior.isAtLatest(visibleMaxY: 1_000, contentHeight: 1_000))
    #expect(ConversationScrollBehavior.isAtLatest(visibleMaxY: 999, contentHeight: 1_000))
    #expect(!ConversationScrollBehavior.isAtLatest(visibleMaxY: 950, contentHeight: 1_000))
    #expect(
        ConversationScrollBehavior.isAtLatest(
            visibleMaxY: 1_828, contentHeight: 1_730, bottomInset: 98))
    #expect(
        !ConversationScrollBehavior.isAtLatest(
            visibleMaxY: 1_828, contentHeight: 1_730, bottomInset: 159))
    #expect(
        ConversationScrollBehavior.isAtLatest(
            visibleMaxY: 1_889, contentHeight: 1_730, bottomInset: 159))
    #expect(
        !ConversationScrollBehavior.isAtLatest(
            visibleMaxY: 1_000,
            contentHeight: 1_000,
            renderedThroughLatest: false
        )
    )
}

@Test func conversationTimelineStaysHiddenUntilItsInitialTailPositionLands() {
    let conversationID = "chat-one"
    #expect(
        ConversationTimelinePresentation.isReady(
            messageCount: 0,
            conversationID: conversationID,
            projectionConversationID: "",
            viewportMode: .awaitingInitial(conversationID: conversationID)))
    #expect(
        !ConversationTimelinePresentation.isReady(
            messageCount: 20,
            conversationID: conversationID,
            projectionConversationID: "chat-two",
            viewportMode: .followingLatest))
    #expect(
        !ConversationTimelinePresentation.isReady(
            messageCount: 20,
            conversationID: conversationID,
            projectionConversationID: conversationID,
            viewportMode: .awaitingInitial(conversationID: conversationID)))
    #expect(
        ConversationTimelinePresentation.isReady(
            messageCount: 20,
            conversationID: conversationID,
            projectionConversationID: conversationID,
            viewportMode: .followingLatest))
}

@Test func conversationProjectionIdentityIncludesTheSelectedConversation() {
    let chat = ConversationPresentationKey(
        conversationID: "chat-one",
        revision: 7,
        renderStart: 0,
        renderCount: 30
    )
    let card = ConversationPresentationKey(
        conversationID: "card-one",
        revision: 7,
        renderStart: 0,
        renderCount: 30
    )

    #expect(chat != card)
}

@Test func terminalScreenReducerReplaysResetsAndBoundsReconnectState() {
    let first = TerminalScreenReducer.applying(
        data: Data("first".utf8),
        screenReset: true,
        to: TerminalScreenState(),
        limit: 8
    )
    #expect(String(decoding: first.data, as: UTF8.self) == "first")
    #expect(first.resetRevision == 1)

    let appended = TerminalScreenReducer.applying(
        data: Data("-second".utf8),
        screenReset: false,
        to: first,
        limit: 8
    )
    #expect(String(decoding: appended.data, as: UTF8.self) == "t-second")
    #expect(appended.resetRevision == 2)
    #expect(appended.revision == 2)

    let replayed = TerminalScreenReducer.applying(
        data: Data("fresh".utf8),
        screenReset: true,
        to: appended,
        limit: 8
    )
    #expect(String(decoding: replayed.data, as: UTF8.self) == "fresh")
    #expect(replayed.resetRevision == 3)
}

@Test func terminalScreenReducerRetainsBoundedChunksWithoutFlatteningEveryAppend() {
    var screen = TerminalScreenState()
    let segment = Data(repeating: 0x61, count: 48 * 1_024)
    for _ in 0..<6 { screen.append(segment, limit: 192 * 1_024) }

    #expect(screen.byteCount == 192 * 1_024)
    #expect(screen.chunks.count >= 3)
    #expect(screen.chunks.allSatisfy { !$0.isEmpty && $0.count <= 64 * 1_024 })
    #expect(screen.data.count == screen.byteCount)
}

@Test @MainActor func remoteTerminalPaletteAssignmentsAreIdempotent() {
    let view = RemoteTerminalView(frame: .zero, font: .monospacedSystemFont(ofSize: 13, weight: .regular))
    let foreground = NSColor.systemGreen
    let background = NSColor.black
    let caret = NSColor.white
    view.applyPalette(foreground: foreground, background: background, caret: caret)
    let mutations = view.paletteMutationCount
    view.applyPalette(foreground: foreground, background: background, caret: caret)
    #expect(view.paletteMutationCount == mutations)

    view.applyPalette(foreground: .systemYellow, background: background, caret: caret)
    #expect(view.paletteMutationCount == mutations + 1)
}

@Test @MainActor func remoteTerminalRendererMovesTheVisibleCaretWithOutputAndReplayResets() async throws {
    let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    let view = SwiftTerm.TerminalView(
        frame: NSRect(x: 0, y: 0, width: 640, height: 320),
        font: font
    )
    let renderer = RemoteTerminalScreenRenderer()

    var screen = TerminalScreenState()
    screen.data = Data("abc".utf8)
    screen.revision = 1
    renderer.apply(screen, to: view)
    try await Task.sleep(nanoseconds: 50_000_000)

    #expect(view.terminal.getCursorLocation().x == 3)
    #expect(view.terminal.getCursorLocation().y == 0)
    #expect(view.caretFrame.origin.x > 0)
    let firstCaret = view.caretFrame

    screen.data.append(Data("\u{001B}[2D".utf8))
    screen.revision += 1
    renderer.apply(screen, to: view)
    try await Task.sleep(nanoseconds: 50_000_000)

    #expect(view.terminal.getCursorLocation().x == 1)
    #expect(view.caretFrame.origin.x < firstCaret.origin.x)

    screen.data.append(Data("\r\nnext".utf8))
    screen.revision += 1
    renderer.apply(screen, to: view)
    try await Task.sleep(nanoseconds: 50_000_000)

    #expect(view.terminal.getCursorLocation().x == 4)
    #expect(view.terminal.getCursorLocation().y == 1)
    #expect(view.caretFrame.origin.y < firstCaret.origin.y)

    screen.data = Data("reset".utf8)
    screen.revision += 1
    screen.resetRevision += 1
    renderer.apply(screen, to: view)
    try await Task.sleep(nanoseconds: 50_000_000)

    #expect(view.terminal.getCursorLocation().x == 5)
    #expect(view.terminal.getCursorLocation().y == 0)
    #expect(view.caretFrame.origin.y == firstCaret.origin.y)
}

@Test @MainActor func remoteTerminalViewUsesPersistedGeometryBeforeReconnectReplay() async throws {
    let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    let view = RemoteTerminalView(frame: .zero, font: font)
    view.prepareForReplay(columns: 120, rows: 36)

    let renderer = RemoteTerminalScreenRenderer()
    var screen = TerminalScreenState()
    screen.data = Data("persisted prompt stays on one row".utf8)
    screen.revision = 1
    renderer.apply(screen, to: view)
    try await Task.sleep(nanoseconds: 50_000_000)

    #expect(view.terminal.cols == 120)
    #expect(view.terminal.rows == 36)
    #expect(view.terminal.getCursorLocation().x == 33)
    #expect(view.terminal.getCursorLocation().y == 0)
}

@Test @MainActor func remoteTerminalViewTracksSetFrameSizeGeometry() async throws {
    let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    let view = RemoteTerminalView(
        frame: NSRect(x: 0, y: 0, width: 900, height: 500),
        font: font
    )
    view.prepareForReplay(columns: 120, rows: 36)
    view.feed(text: "terminal resize remains coherent")

    view.setFrameSize(NSSize(width: 520, height: 260))
    try await Task.sleep(nanoseconds: 50_000_000)

    let narrowColumns = view.terminal.cols
    let narrowRows = view.terminal.rows
    #expect(narrowColumns > 2 && narrowColumns < 120)
    #expect(narrowRows > 1 && narrowRows < 36)
    #expect(view.terminal.getCursorLocation().x == 32)
    #expect(view.terminal.getCursorLocation().x < narrowColumns)

    view.setFrameSize(NSSize(width: 1_100, height: 620))
    try await Task.sleep(nanoseconds: 50_000_000)

    #expect(view.terminal.cols > narrowColumns)
    #expect(view.terminal.rows > narrowRows)
    #expect(view.terminal.getCursorLocation().x == 32)
    #expect(view.bounds.intersects(view.caretFrame))
}

@Test @MainActor func remoteTerminalViewSupportsNativeSelectionCopyPasteAndFocus() async throws {
    let pasteboard = NSPasteboard.general
    let savedPasteboard =
        pasteboard.pasteboardItems?.map { source in
            source.types.compactMap { type in
                source.data(forType: type).map { (type.rawValue, $0) }
            }
        } ?? []
    defer {
        pasteboard.clearContents()
        let restoredItems = savedPasteboard.map { contents in
            let item = NSPasteboardItem()
            for (type, data) in contents {
                item.setData(data, forType: NSPasteboard.PasteboardType(type))
            }
            return item
        }
        if !restoredItems.isEmpty { pasteboard.writeObjects(restoredItems) }
    }

    let view = RemoteTerminalView(
        frame: NSRect(x: 0, y: 0, width: 640, height: 320),
        font: .monospacedSystemFont(ofSize: 13, weight: .regular)
    )
    let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = view
    view.prepareForReplay(columns: 80, rows: 24)
    view.feed(text: "selectable terminal text")
    try await Task.sleep(for: .milliseconds(50))

    _ = window.makeFirstResponder(nil)
    let cell = view.caretFrame.size
    let rowY = view.bounds.height - (cell.height / 2)
    view.mouseDown(with: terminalMouseEvent(.leftMouseDown, at: NSPoint(x: cell.width / 2, y: rowY), in: view))
    view.mouseDragged(
        with: terminalMouseEvent(.leftMouseDragged, at: NSPoint(x: cell.width * 10.5, y: rowY), in: view))
    view.mouseUp(with: terminalMouseEvent(.leftMouseUp, at: NSPoint(x: cell.width * 10.5, y: rowY), in: view))

    #expect(window.firstResponder === view)
    #expect(view.selectedRange().location != NSNotFound)
    #expect(view.selectedRange().length > 0)
    NSApp.sendEvent(terminalKeyEvent("c", modifiers: .command, in: window))
    #expect(pasteboard.string(forType: .string)?.contains("selectable") == true)

    var sent = Data()
    let coordinator = RemoteTerminalSurface.Coordinator(
        terminalID: "clipboard-shell", send: { sent.append($0) }, resize: { _, _ in })
    view.terminalDelegate = coordinator
    pasteboard.clearContents()
    pasteboard.setString("pasted through terminal", forType: .string)
    NSApp.sendEvent(terminalKeyEvent("v", modifiers: .command, in: window))
    #expect(String(decoding: sent, as: UTF8.self) == "pasted through terminal")

    let menu = view.menu(for: terminalMouseEvent(.rightMouseDown, at: .zero, in: view))
    #expect(menu?.items.map(\.title).filter { !$0.isEmpty } == ["Copy", "Paste", "Select All"])
}

@Test @MainActor func remoteTerminalViewEmitsRawTerminalControlBytesForEditingKeys() {
    let view = RemoteTerminalView(
        frame: NSRect(x: 0, y: 0, width: 640, height: 320),
        font: .monospacedSystemFont(ofSize: 13, weight: .regular)
    )
    var sent = Data()
    let coordinator = RemoteTerminalSurface.Coordinator(
        terminalID: "editing-keys", send: { sent.append($0) }, resize: { _, _ in })
    view.terminalDelegate = coordinator

    view.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
    view.doCommand(by: #selector(NSResponder.moveLeft(_:)))

    #expect(Array(sent) == [0x7f, 0x1b, 0x5b, 0x44])
}

@Test @MainActor func remoteTerminalViewUsesShiftDragToSelectWhenApplicationTracksTheMouse() async throws {
    let view = RemoteTerminalView(
        frame: NSRect(x: 0, y: 0, width: 640, height: 320),
        font: .monospacedSystemFont(ofSize: 13, weight: .regular)
    )
    let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = view
    view.prepareForReplay(columns: 80, rows: 24)
    view.feed(text: "mouse-aware output\u{001B}[?1000h")
    try await Task.sleep(for: .milliseconds(50))

    let cell = view.caretFrame.size
    let rowY = view.bounds.height - (cell.height / 2)
    let modifiers: NSEvent.ModifierFlags = .shift
    view.mouseDown(
        with: terminalMouseEvent(
            .leftMouseDown, at: NSPoint(x: cell.width / 2, y: rowY), modifiers: modifiers, in: view))
    view.mouseDragged(
        with: terminalMouseEvent(
            .leftMouseDragged, at: NSPoint(x: cell.width * 8.5, y: rowY), modifiers: modifiers, in: view))
    view.mouseUp(
        with: terminalMouseEvent(
            .leftMouseUp, at: NSPoint(x: cell.width * 8.5, y: rowY), modifiers: modifiers, in: view))

    #expect(view.selectedRange().location != NSNotFound)
    #expect(view.selectedRange().length > 0)
}

@MainActor
private func terminalMouseEvent(
    _ type: NSEvent.EventType,
    at point: NSPoint,
    modifiers: NSEvent.ModifierFlags = [],
    in view: NSView
) -> NSEvent {
    NSEvent.mouseEvent(
        with: type,
        location: view.convert(point, to: nil),
        modifierFlags: modifiers,
        timestamp: 0,
        windowNumber: view.window?.windowNumber ?? 0,
        context: nil,
        eventNumber: 1,
        clickCount: 1,
        pressure: 1
    )!
}

@MainActor
private func terminalKeyEvent(
    _ characters: String,
    modifiers: NSEvent.ModifierFlags,
    in window: NSWindow
) -> NSEvent {
    NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: modifiers,
        timestamp: 0,
        windowNumber: window.windowNumber,
        context: nil,
        characters: characters,
        charactersIgnoringModifiers: characters,
        isARepeat: false,
        keyCode: 0
    )!
}

@Test func sidebarWidthIsClampedToItsSupportedRange() {
    #expect(SidebarSizing.clamped(180) == SidebarSizing.minimumWidth)
    #expect(SidebarSizing.clamped(300) == 300)
    #expect(SidebarSizing.clamped(500) == SidebarSizing.maximumWidth)
}

@Test func kanbanLanesFillTheBoardBeforeFallingBackToHorizontalScrolling() {
    #expect(KanbanLaneSizing.laneWidth(availableWidth: 1_255, laneCount: 4) == 300)
    #expect(KanbanLaneSizing.contentWidth(availableWidth: 1_255, laneCount: 4) == 1_255)
    #expect(KanbanLaneSizing.laneWidth(availableWidth: 680, laneCount: 4) == KanbanLaneSizing.minimumWidth)
    #expect(KanbanLaneSizing.contentWidth(availableWidth: 680, laneCount: 4) == 1_111)
}

@Test func laneCardPagesBoundTenThousandCardsAndClampAfterDeletion() {
    let first = LaneCardPage.resolve(total: 10_000, requestedPage: 0)
    #expect(first.lowerBound == 0)
    #expect(first.upperBound == LaneCardPage.defaultSize)
    #expect(first.pageCount == 250)
    #expect(first.rangeLabel == "1–40 of 10000")

    let last = LaneCardPage.resolve(total: 10_000, requestedPage: 249)
    #expect(last.lowerBound == 9_960)
    #expect(last.upperBound == 10_000)
    #expect(!last.canGoForward)

    let clamped = LaneCardPage.resolve(total: 3, requestedPage: 249)
    #expect(clamped.page == 0)
    #expect(clamped.lowerBound == 0)
    #expect(clamped.upperBound == 3)
}

@Test func settingsAreFirstClassNestedNavigationDestinations() {
    #expect(AppSection.allCases.contains(.settings))
    #expect(
        DieterSettingsSection.allCases.map(\.rawValue) == [
            "General", "Browser", "Connection", "Usage", "Prompts", "Notifications", "Island", "Agents", "Experimental",
        ])
}

@Test func machineInformationUsesAPopupInsteadOfANavigationDestination() {
    #expect(!AppSection.allCases.map(\.rawValue).contains("Machines"))
}

@Test @MainActor func workRoutesToTheConversationOwnerAndProjectReadsToTheProjectHost() throws {
    let store = DieterStore(liveEnvironment: false)
    let checkoutMachine = MachineEndpoint(
        name: "MBP", host: "mbp.invalid", port: 443, secure: true,
        daemonID: "daemon-mbp", online: true)
    let conversationOwner = MachineEndpoint(
        name: "Mini", host: "mini.invalid", port: 443, secure: true,
        daemonID: "daemon-mini", online: true)
    store.endpoints = [checkoutMachine, conversationOwner]
    store.machineEntries = Dictionary(
        uniqueKeysWithValues: store.endpoints.map { machine in
            (
                machine.id,
                ClientMachineEntry.with {
                    $0.id = machine.daemonID ?? ""
                    $0.online = true
                    $0.available = true
                    $0.compatible = true
                }
            )
        })
    var project = Dieter_V1_Project()
    project.id = "project"
    project.checkouts = [
        .with {
            $0.id = "co"; $0.projectID = "project"; $0.daemonID = "daemon-mbp"
        }
    ]
    store.projectDirectory = [project.id: project]
    store.projectHosts = [project.id: "daemon-mbp"]
    var chat = Dieter_V1_Card()
    chat.id = "chat"
    chat.scope = "chat"
    chat.projectID = "project"
    chat.ownerDaemonID = "daemon-mini"

    let route = try #require(store.conversationWorkspaceRoute(for: chat))
    #expect(route.endpointID == conversationOwner.id)
    #expect(route.machineName == "Mini")
    #expect(store.projectMachine(forProjectID: "project")?.id == checkoutMachine.id)
    #expect(store.projectIsAvailable("project"))
    // A machine the session does not list is still the owner, shown as offline.
    chat.ownerDaemonID = "daemon-gone"
    #expect(store.machine(for: chat)?.online == false)
    #expect(store.endpointID(for: chat) == "\(store.activeGateway.credentialID)#daemon-gone")
}

@Test func appearancePreferenceDefaultsToSystemAndRecognizesEveryStoredMode() {
    #expect(DieterAppearance.resolve(nil) == .system)
    #expect(DieterAppearance.resolve("unknown") == .system)
    #expect(DieterAppearance.allCases.map(\.rawValue) == ["system", "light", "dark"])
    #expect(DieterAppearance.resolve("system").colorScheme == nil)
    #expect(DieterAppearance.resolve("light").colorScheme == .light)
    #expect(DieterAppearance.resolve("dark").colorScheme == .dark)
}

@Test func palettePreferenceRecognizesEveryDesignAndDefaultsToMonochrome() {
    #expect(DieterPalette.resolve(nil) == .monochrome)
    #expect(DieterPalette.resolve("unknown") == .monochrome)
    #expect(DieterPalette.resolve("acid-terminal") == .monochrome)
    #expect(
        DieterPalette.allCases.map(\.rawValue) == [
            "monochrome",
            "electric-blue", "jade-operator", "copper-circuit", "ultraviolet-relay",
            "solar-command", "arctic-console", "coral-signal",
        ])
    #expect(Set(DieterPalette.allCases.map(\.title)).count == 8)
    #expect(DieterPalette.allCases.allSatisfy { DieterPalette.resolve($0.rawValue) == $0 })
}

@Test @MainActor func liveThemeSelectionInvalidatesObserversAndPersistsImmediately() async throws {
    let suiteName = "DieterMacTests.theme.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(DieterAppearance.light.rawValue, forKey: DieterAppearance.storageKey)
    defaults.set(DieterPalette.monochrome.rawValue, forKey: DieterPalette.storageKey)
    let store = DieterStore(themeDefaultsOverride: defaults, liveEnvironment: false)
    let (changes, continuation) = AsyncStream<Void>.makeStream()

    withObservationTracking {
        _ = store.themeSelection.identity
    } onChange: {
        continuation.yield()
    }
    store.themeSelection = DieterThemeSelection(
        appearance: .dark,
        palette: .coralSignal
    )

    var iterator = changes.makeAsyncIterator()
    #expect(await iterator.next() != nil)
    continuation.finish()
    #expect(store.themeSelection.identity == "dark:coral-signal:glass")
    #expect(defaults.string(forKey: DieterAppearance.storageKey) == "dark")
    #expect(defaults.string(forKey: DieterPalette.storageKey) == "coral-signal")
    #expect(DieterThemeSelection.load(from: defaults) == store.themeSelection)
}

@Test func onlyAuthenticationRequiresAConnectionOverlay() {
    #expect(ConnectionPhase.authenticationRequired.needsConnectionOverlay)
    #expect(!ConnectionPhase.connecting.needsConnectionOverlay)
    #expect(!ConnectionPhase.disconnected.needsConnectionOverlay)
}

@Test func projectDestinationsGroupDuplicateNamesByOwningMachine() throws {
    let gateway = MachineEndpoint(name: "Gateway", host: "example.com", port: 443, secure: true)
    let home = MachineEndpoint(
        name: "mini-home", host: gateway.host, port: gateway.port, secure: true,
        daemonID: "home", online: true, releaseVersion: "0.4.92"
    )
    let office = MachineEndpoint(
        name: "mini-office", host: gateway.host, port: gateway.port, secure: true,
        daemonID: "office", online: false, releaseVersion: "0.4.57"
    )
    var homeProject = Dieter_V1_Project()
    homeProject.id = "p_home"
    homeProject.name = "dieter"
    var homeCheckout = Dieter_V1_Checkout(); homeCheckout.id = "co_home"; homeCheckout.daemonID = "home"
    homeCheckout.path = "/Users/home/Development/dieter"; homeProject.checkouts = [homeCheckout]
    var officeProject = Dieter_V1_Project()
    officeProject.id = "p_office"
    officeProject.name = "dieter"
    var officeCheckout = Dieter_V1_Checkout(); officeCheckout.id = "co_office"; officeCheckout.daemonID = "office"
    officeCheckout.path = "/Users/office/Development/dieter"; officeProject.checkouts = [officeCheckout]

    let groups = ProjectDestinationCatalog.groups(
        projects: [officeProject, homeProject],
        endpoints: [office, home]
    )

    #expect(groups.map(\.machineName) == ["mini-home", "mini-office"])
    #expect(groups.map(\.title) == ["mini-home · Online", "mini-office · Offline"])
    #expect(groups.map { $0.destinations.map(\.project.name) } == [["dieter"], ["dieter"]])
    let destination = try #require(ProjectDestinationCatalog.destination(projectID: officeProject.id, in: groups))
    #expect(destination.title == "dieter · mini-office")
    #expect(destination.detail == "Offline · ~/Development/dieter")
}

@Test func projectWithoutACheckoutHasNoExecutionDestination() throws {
    let machine = MachineEndpoint(
        name: "Studio Mac", host: "example.com", port: 443, secure: true,
        daemonID: "studio", online: true
    )
    var project = Dieter_V1_Project()
    project.id = "p_studio"
    project.name = "Dieter"
    project.path = "/work/dieter"

    let groups = ProjectDestinationCatalog.groups(
        projects: [project],
        endpoints: [machine]
    )

    #expect(groups.isEmpty)
}

@Test func projectDestinationDefaultsToTheCurrentMachineAndAllowsAnExplicitCheckoutOverride() throws {
    let current = MachineEndpoint(
        name: "Zulu current Mac", host: "example.com", port: 443, secure: true,
        daemonID: "current", online: true
    )
    let remote = MachineEndpoint(
        name: "Alpha remote Mac", host: "example.com", port: 443, secure: true,
        daemonID: "remote", online: true
    )
    var project = Dieter_V1_Project()
    project.id = "p_shared"
    project.name = "Shared"
    var currentCheckout = Dieter_V1_Checkout()
    currentCheckout.id = "co_current"; currentCheckout.projectID = project.id
    currentCheckout.daemonID = "current"; currentCheckout.path = "/current/shared"
    var remoteCheckout = Dieter_V1_Checkout()
    remoteCheckout.id = "co_remote"; remoteCheckout.projectID = project.id
    remoteCheckout.daemonID = "remote"; remoteCheckout.path = "/remote/shared"
    project.checkouts = [remoteCheckout, currentCheckout]

    let groups = ProjectDestinationCatalog.groups(
        projects: [project],
        endpoints: [remote, current]
    )

    let defaultDestination = try #require(
        ProjectDestinationCatalog.preferredDestination(
            preferredMachineID: current.id,
            preferredProjectID: project.id,
            in: groups
        ))
    #expect(defaultDestination.checkoutID == currentCheckout.id)
    #expect(defaultDestination.machineID == current.id)

    let explicitDestination = try #require(
        ProjectDestinationCatalog.preferredDestination(
            preferredMachineID: current.id,
            preferredProjectID: project.id,
            preferredCheckoutID: remoteCheckout.id,
            in: groups
        ))
    #expect(explicitDestination.checkoutID == remoteCheckout.id)
    #expect(explicitDestination.machineID == remote.id)

    let selectedRemoteProject = try #require(
        ProjectDestinationCatalog.preferredDestination(
            preferredMachineID: remote.id,
            preferredProjectID: project.id,
            in: groups
        ))
    #expect(selectedRemoteProject.checkoutID == remoteCheckout.id)
}

@Test func boardPresentationUsesLoadingStateUntilASelectionCanBeResolved() {
    #expect(
        BoardPresentationState.resolve(
            hasLoadedWorkspace: false,
            selectedBoardID: "",
            hasSelectedBoard: false
        ) == .loading)
    #expect(
        BoardPresentationState.resolve(
            hasLoadedWorkspace: true,
            selectedBoardID: "b_loading",
            hasSelectedBoard: false
        ) == .loading)
    #expect(
        BoardPresentationState.resolve(
            hasLoadedWorkspace: true,
            selectedBoardID: "b_loaded",
            hasSelectedBoard: true
        ) == .loaded)
}

@Test func boardPresentationPreservesTheEmptyStateForABoardlessWorkspace() {
    #expect(
        BoardPresentationState.resolve(
            hasLoadedWorkspace: true,
            selectedBoardID: "",
            hasSelectedBoard: false
        ) == .empty)
}

@Test @MainActor func coreFailuresReportByKindAndTransientOnesStaySilentWhileOffline() {
    let store = DieterStore(liveEnvironment: false)
    store.phase = .disconnected
    store.show(CoreFailure(kind: .transient, message: "The machine is unreachable."))
    #expect(store.errorMessage == nil)
    store.show(CoreFailure(kind: .permanent, message: "This board has no done lane."))
    #expect(store.errorMessage == "This board has no done lane.")

    store.errorMessage = nil
    store.phase = .connected
    store.show(CoreFailure(kind: .transient, message: "The machine is unreachable."))
    #expect(store.errorMessage == "The machine is unreachable.")
    store.errorMessage = nil
    store.show(CancellationError())
    #expect(store.errorMessage == nil)
}

@Test @MainActor func notificationSettingIsKeptOnlyUnderItsCoreKey() throws {
    let suite = "DieterNotificationSettingTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = DieterStore(environment: .testing(defaults: defaults), liveEnvironment: false)
    store.notificationsEnabled = false
    #expect(!store.notificationsEnabled)
    #expect(defaults.string(forKey: "notifications.enabled") == "false")
    #expect(defaults.object(forKey: "DieterNotifications") == nil)
}

@Test @MainActor func cachedBoardSelectionSwitchesTheVisibleProjectAtOnce() {
    let store = DieterStore(liveEnvironment: false)
    var firstProject = Dieter_V1_Project()
    firstProject.id = "p_first"
    firstProject.name = "First"
    var secondProject = Dieter_V1_Project()
    secondProject.id = "p_second"
    secondProject.name = "Second"
    var firstBoard = Dieter_V1_Board()
    firstBoard.id = "b_first"
    firstBoard.projectID = firstProject.id
    var secondBoard = Dieter_V1_Board()
    secondBoard.id = "b_second"
    secondBoard.projectID = secondProject.id
    var secondCard = Dieter_V1_Card()
    secondCard.id = "c_second"
    secondCard.projectID = secondProject.id
    secondCard.boardID = secondBoard.id

    store.projectDirectory = [firstProject.id: firstProject, secondProject.id: secondProject]
    store.navigationBoards = [firstProject.id: [firstBoard], secondProject.id: [secondBoard]]
    store.navigationCards = [firstProject.id: [], secondProject.id: [secondCard]]
    store.selectedProjectID = firstProject.id
    store.selectedBoardID = firstBoard.id
    store.state.project = firstProject
    store.state.boards = [firstBoard]

    store.selectCachedBoard(secondBoard.id, projectID: secondProject.id)

    #expect(store.selectedProjectID == secondProject.id)
    #expect(store.selectedBoard?.id == secondBoard.id)
    #expect(store.state.project.id == secondProject.id)
    #expect(store.state.cards.map(\.id) == [secondCard.id])
}

@Test func fileDocumentsPreserveTheirBytes() {
    var document = Dieter_V1_FileDocument()
    document.binary = true
    document.content = "ignored"
    document.data = Data([0, 1, 2])
    #expect(document.bytes == Data([0, 1, 2]))
    document.binary = false
    document.content = "hello"
    #expect(document.bytes == Data("hello".utf8))
}

@Test func labelColorPaletteSerializesCustomColorsAsHex() {
    #expect(LabelColorPalette.hex(for: SwiftUI.Color(red: 1, green: 0.5, blue: 0)) == "#ff8000")
}

@Test @MainActor func macAttachmentSelectionPreservesBytesAndEnforcesTheSharedLimit() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "dieter-mac-attachments-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let image = root.appending(path: "fixture.png")
    let document = root.appending(path: "notes.txt")
    try Data("png fixture".utf8).write(to: image)
    try Data("hello".utf8).write(to: document)

    let store = DieterStore(liveEnvironment: false)
    let parts = try await store.attachmentParts([image, document])
    #expect(parts.count == 2)
    #expect(parts[0].filename == "fixture.png")
    #expect(parts[0].mediaType == "image/png")
    #expect(parts[0].data == Data("png fixture".utf8))
    #expect(parts[1].filename == "notes.txt")

    var rejected = false
    do {
        _ = try await store.attachmentParts([image], appendingTo: Array(repeating: parts[0], count: 4))
    } catch {
        rejected = true
    }
    #expect(rejected)
}

@Test @MainActor func pastedMacImageBecomesAPngAttachmentWithoutALocalFileURL() async throws {
    let png = try #require(
        Data(
            base64Encoded:
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
    let provider = NSItemProvider(item: png as NSData, typeIdentifier: UTType.png.identifier)
    let store = DieterStore(liveEnvironment: false)

    let parts = try await store.attachmentParts([provider])

    #expect(parts.count == 1)
    #expect(parts[0].type == "file")
    #expect(parts[0].mediaType == "image/png")
    #expect(parts[0].filename == "attached-image", "an unnamed paste is named by the core")
    #expect(parts[0].data == png)
}

@Test @MainActor func pastedMacTIFFScreenshotIsNormalizedToPortablePNG() async throws {
    let image = NSImage(size: NSSize(width: 2, height: 2))
    image.lockFocus()
    NSColor.systemPurple.setFill()
    NSRect(x: 0, y: 0, width: 2, height: 2).fill()
    image.unlockFocus()
    let tiff = try #require(image.tiffRepresentation)
    let provider = NSItemProvider(item: tiff as NSData, typeIdentifier: UTType.tiff.identifier)
    let store = DieterStore(liveEnvironment: false)

    let parts = try await store.attachmentParts([provider])

    #expect(parts[0].mediaType == "image/png")
    #expect(parts[0].filename == "attached-image", "an unnamed paste is named by the core")
    #expect(NSImage(data: parts[0].data) != nil)
}

@Test @MainActor func pasteboardImageDataBecomesAComposerAttachment() async throws {
    let png = try #require(
        Data(
            base64Encoded:
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("dieter-test-\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    pasteboard.clearContents()
    pasteboard.setData(png, forType: NSPasteboard.PasteboardType(UTType.png.identifier))
    let store = DieterStore(liveEnvironment: false)

    let input = try #require(store.pasteboardAttachmentInput(pasteboard))
    let parts = try await store.attachmentParts(input)

    #expect(parts.count == 1)
    #expect(parts[0].type == "file")
    #expect(parts[0].mediaType == "image/png")
    #expect(parts[0].filename == "attached-image", "an unnamed paste is named by the core")
    #expect(parts[0].data == png)
}

@Test @MainActor func pasteboardWithOnlyTextIsLeftForTheFocusedTextView() async throws {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("dieter-test-\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    pasteboard.clearContents()
    pasteboard.setString("plain text", forType: .string)
    let store = DieterStore(liveEnvironment: false)

    #expect(store.pasteboardAttachmentInput(pasteboard) == nil)
    #expect(!store.attachPasteboard(pasteboard))
    #expect(store.composerAttachments.isEmpty)
}

@Test func conversationWorkspacePickerUsesOnlySupportedCreationChoices() {
    #expect(ConversationWorkspaceMode.selectable("worktree") == .worktree)
    #expect(ConversationWorkspaceMode.selectable("WORKTREE") == .worktree)
    #expect(ConversationWorkspaceMode.selectable("project") == .project)
    #expect(ConversationWorkspaceMode.selectable("main") == .project)
    #expect(ConversationWorkspaceMode.selectable("branch") == .project)
    #expect(ConversationWorkspaceMode.selectable(nil) == .project)
    #expect(ConversationWorkspaceMode.allCases == [.worktree, .project])
    #expect(ConversationWorkspaceMode.worktree.title == "Worktree")
    #expect(ConversationWorkspaceMode.project.title == "Project directory")
}

@Test func embeddedMacImageAttachmentsProvidePreviewImages() throws {
    let png = try #require(
        Data(
            base64Encoded:
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
    var dataPart = Dieter_V1_MessagePart()
    dataPart.type = "image"
    dataPart.mediaType = "image/png"
    dataPart.data = png
    #expect(AttachmentImagePayload.image(from: dataPart) != nil)

    var dataURLPart = Dieter_V1_MessagePart()
    dataURLPart.type = "image"
    dataURLPart.url = "data:image/png;base64,\(png.base64EncodedString())"
    #expect(AttachmentImagePayload.image(from: dataURLPart) != nil)
}

@Test @MainActor func pasteboardFileURLsAttachTheUnderlyingFiles() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "dieter-mac-pasteboard-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appending(path: "diagram.png")
    try Data("png fixture".utf8).write(to: file)
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("dieter-test-\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    pasteboard.clearContents()
    pasteboard.writeObjects([file as NSURL])
    let store = DieterStore(liveEnvironment: false)

    #expect(store.attachPasteboard(pasteboard))
    let deadline = Date().addingTimeInterval(1)
    while store.composerAttachments.isEmpty, Date() < deadline {
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    let attachment = try #require(store.composerAttachments.first)
    #expect(attachment.filename == "diagram.png")
    #expect(attachment.data == Data("png fixture".utf8))
}

private func dragCard(_ id: String, position: Int64) -> Dieter_V1_Card {
    var card = Dieter_V1_Card()
    card.id = id
    card.position = position
    return card
}

@Test func sidebarProjectDragPayloadRejectsOtherStringDrops() {
    let payload = SidebarProjectDragPayload(projectID: "p_one")
    #expect(SidebarProjectDragPayload(payload.encoded) == payload)
    #expect(SidebarProjectDragPayload("not-a-sidebar-project") == nil)
    #expect(SidebarProjectDragPayload("dieter:sidebar-project:") == nil)
}

@Test func pinnedChatDragPayloadRejectsOtherStringDrops() {
    let payload = PinnedChatDragPayload(chatID: "c_first")
    #expect(PinnedChatDragPayload(payload.encoded) == payload)
    #expect(PinnedChatDragPayload("not-a-pinned-chat") == nil)
    #expect(PinnedChatDragPayload("dieter:pinned-chat:") == nil)
}

@Test @MainActor func openingAConversationRoutesToItsChatOrBoardWorkspace() async {
    let store = DieterStore(liveEnvironment: false)
    var firstProject = Dieter_V1_Project()
    firstProject.id = "p_first"
    firstProject.name = "First"
    var targetProject = Dieter_V1_Project()
    targetProject.id = "p_target"
    targetProject.name = "Target"
    var firstBoard = Dieter_V1_Board()
    firstBoard.id = "b_first"
    firstBoard.projectID = firstProject.id
    var targetBoard = Dieter_V1_Board()
    targetBoard.id = "b_target"
    targetBoard.projectID = targetProject.id
    var boardCard = Dieter_V1_Card()
    boardCard.id = "c_board"
    boardCard.projectID = targetProject.id
    boardCard.boardID = targetBoard.id
    var chat = Dieter_V1_Card()
    chat.id = "c_chat"
    chat.projectID = targetProject.id
    chat.scope = "chat"

    store.projectDirectory = [firstProject.id: firstProject, targetProject.id: targetProject]
    store.navigationBoards = [firstProject.id: [firstBoard], targetProject.id: [targetBoard]]
    store.navigationCards = [targetProject.id: [boardCard]]
    store.chats = [chat]
    store.selectedProjectID = firstProject.id
    store.selectedBoardID = firstBoard.id
    store.section = .settings
    await store.openInbox()
    await store.openConversation(cardID: boardCard.id, fromInbox: true)
    #expect(store.section == .inbox)
    #expect(store.selectedCardID == boardCard.id)
    #expect(store.selectedProjectID == targetProject.id)
    #expect(store.selectedBoardID == targetBoard.id)
    await store.openInbox()
    #expect(store.selectedCardID == boardCard.id)

    await store.openConversation(cardID: chat.id, fromInbox: true)
    #expect(store.section == .inbox)
    #expect(store.selectedCardID == nil)
    #expect(store.selectedChatID == chat.id)
    await store.conversationContext.openConversation(cardID: chat.id, chat: true)
    #expect(store.section == .inbox)
    store.closeConversation()
    #expect(store.section == .inbox)
    #expect(store.selectedChatID == nil)

    await store.openConversation(cardID: boardCard.id)

    #expect(store.section == .board)
    #expect(store.selectedProjectID == targetProject.id)
    #expect(store.selectedBoardID == targetBoard.id)
    #expect(store.selectedCardID == boardCard.id)
    #expect(store.selectedChatID == nil)
    #expect(store.state.cards.map(\.id) == [boardCard.id])

    await store.openConversation(cardID: chat.id)

    #expect(store.section == .chats)
    #expect(store.selectedProjectID == targetProject.id)
    #expect(store.selectedCardID == nil)
    #expect(store.selectedChatID == chat.id)
}

@Test @MainActor func openingAllChatsRestoresTheLastUsedActiveChat() async {
    let store = DieterStore()
    var project = Dieter_V1_Project()
    project.id = "p_project"
    var firstChat = Dieter_V1_Card()
    firstChat.id = "c_first"
    firstChat.projectID = project.id
    firstChat.scope = "chat"
    var lastUsedChat = Dieter_V1_Card()
    lastUsedChat.id = "c_last"
    lastUsedChat.projectID = project.id
    lastUsedChat.scope = "chat"

    store.projectDirectory = [project.id: project]
    store.chats = [firstChat, lastUsedChat]

    await store.openConversation(cardID: lastUsedChat.id, chat: true)
    store.closeConversation()
    store.section = .settings

    await store.openChats()

    #expect(store.section == .chats)
    #expect(store.selectedChatID == lastUsedChat.id)
    #expect(store.lastUsedChatID == lastUsedChat.id)
}
