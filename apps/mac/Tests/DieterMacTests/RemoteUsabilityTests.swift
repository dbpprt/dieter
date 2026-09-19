import AppKit
import DieterAPI
import DieterCore
import Foundation
import Synchronization
import Testing
@testable import DieterMac

@Test @MainActor func laneCreationRetainsDestinationAndClearsItOnDismissal() {
    let store = DieterStore(restoreSync: false)
    defer { store.disconnect() }
    var board = Dieter_V1_Board(); board.id = "board"; board.projectID = "project"
    board.lanes = ["todo", "running", "review", "done"].map { id in
        var lane = Dieter_V1_Lane(); lane.id = id; return lane
    }
    var project = Dieter_V1_Project(); project.id = "project"
    store.state.projects = [project]; store.state.boards = [board]
    store.selectedProjectID = project.id; store.selectedBoardID = board.id
    for lane in board.lanes {
        store.presentNewCard(in: lane.id)
        #expect(store.createConversationPresented)
        #expect(store.window.newCardLaneID == lane.id)
        store.createConversationPresented = false
        #expect(store.window.newCardLaneID == nil)
    }
    store.presentNewCard(in: "removed-lane")
    #expect(!store.createConversationPresented)
}

@Test @MainActor func documentClickWithPaneDisabledAndCommandClickResolveRemoteBytes() async throws {
    let copies = RemoteDocumentCopies()
    var document = Dieter_V1_FileDocument(); document.binary = true; document.data = Data("%PDF-test".utf8)
    let copy = try copies.save(document, path: "reports/Report with spaces.pdf")
    #expect(copy.lastPathComponent == "Report with spaces.pdf")
    #expect(try Data(contentsOf: copy) == document.data)
    let delegate = ConversationTextLinkDelegate()
    var opened: [URL] = []
    var resolved: [String] = []
    delegate.externalResolver = { url in
        resolved.append(url.relativeString)
        return ConversationLinkExternalTarget(isLocalCopy: true, revalidate: { copy })
    }
    delegate.openExternal = { url, _ in opened.append(url) }
    // Default configuration: there is no optional in-app pane handler.
    #expect(delegate.activate("/remote/worktree/reports/Report%20with%20spaces.pdf"))
    await delegate.openingTask?.value
    delegate.handler = { _ in
        Issue.record("Command-click must use the external resolver"); return true
    }
    #expect(delegate.activate("reports/Report%20with%20spaces.pdf", modifiers: .command))
    await delegate.openingTask?.value
    #expect(opened == [copy, copy])
    #expect(resolved.count == 2)
}

@Test @MainActor func remoteDocumentOpeningRevalidatesSelectionAndReportsFailure() async {
    let delegate = ConversationTextLinkDelegate()
    var opened = false
    var failure: String?
    delegate.openExternal = { _, _ in opened = true }
    delegate.reportError = { failure = $0 }
    delegate.externalResolver = { _ in .init(revalidate: { nil }) }
    #expect(delegate.activate("report.pdf"))
    await delegate.openingTask?.value
    #expect(!opened)
    delegate.externalResolver = { _ in .unavailable("The remote machine is offline.") }
    #expect(delegate.activate("report.pdf"))
    await delegate.openingTask?.value
    #expect(!opened && failure == "The remote machine is offline.")
}

@Test @MainActor func remoteDocumentCopiesKeepSameNamesSeparateAndEnforceSizeLimit() throws {
    let copies = RemoteDocumentCopies()
    var document = Dieter_V1_FileDocument(); document.content = "First machine"
    let first = try copies.save(document, path: "docs/report.md")
    document.content = "Second machine"
    let second = try copies.save(document, path: "docs/report.md")
    #expect(first != second)
    #expect(try String(contentsOf: first, encoding: .utf8) == "First machine")
    #expect(try String(contentsOf: second, encoding: .utf8) == "Second machine")
    #expect(try FileManager.default.attributesOfItem(atPath: first.path)[.posixPermissions] as? Int == 0o600)
    document.binary = true; document.data = Data(count: RemoteDocumentCopies.maximumBytes + 1)
    #expect(throws: CocoaError.self) { try copies.save(document, path: "too-big.pdf") }
}

@Test func composerDeliveryOnlyIncludesThisConversationAndMachine() throws {
    func entry(_ id: String, card: String, machine: String, state: DieterOutboxEntry.State = .queued) throws
        -> DieterOutboxEntry
    {
        var request = Dieter_V1_SendMessageRequest(); request.cardID = card
        return DieterOutboxEntry(
            commandID: id, clientID: "client", endpointID: machine, kind: .sendMessage,
            request: try request.serializedData(), optimisticID: id, attempts: 0, state: state, createdAt: .now)
    }
    let items = try [
        entry("mine", card: "A", machine: "remote"), entry("other-chat", card: "B", machine: "remote"),
        entry("other-machine", card: "A", machine: "local", state: .failed),
    ]
    let status = try #require(
        ConversationDeliveryStatus.resolve(
            entries: items, conversationID: "A", endpointID: "remote", machineName: "Mini", online: false))
    #expect(status.itemIDs == ["mine"])
    #expect(status.phase == .waiting)
    #expect(status.title.contains("Mini"))
    #expect(
        ConversationDeliveryStatus.resolve(
            entries: items, conversationID: "absent", endpointID: "remote", machineName: "Mini", online: true) == nil)
    var accepted = items[0]; accepted.serverID = "accepted"
    #expect(
        ConversationDeliveryStatus.resolve(
            entries: [accepted], conversationID: "A", endpointID: "remote", machineName: "Mini", online: true) == nil)
}

private struct DirectoryTestError: Error {}

@Test @MainActor func offlineMachineManagementUsesItsGatewayWithoutAnActiveDaemonConnection() async {
    let seen = Mutex<[DieterEndpoint]>([])
    let base = DieterAppEnvironment.testing()
    let store = DieterStore(
        environment: DieterAppEnvironment(
            arguments: [], defaults: base.defaults, storageRoot: base.storageRoot,
            clients: DieterClientFactory { endpoint, _, _, _ in
                seen.withLock { $0.append(endpoint) }
                throw DirectoryTestError()
            }), restoreSync: false)
    defer { store.disconnect() }
    let machine = DieterEndpoint(
        name: "Offline Mini", host: "gateway.example", port: 443, secure: true, daemonID: "offline")
    store.endpoints = [machine]; store.gatewayOrigins = [machine.gatewayEndpoint]; store.endpoint = machine
    #expect(store.rpc == nil)
    #expect(!(await store.revokeDaemon(machine)))
    #expect(!(await store.renameMachine(machine, name: "New name")))
    let targets = seen.withLock { $0 }
    #expect(targets.count == 2)
    #expect(targets.allSatisfy { $0.daemonID == nil && $0.credentialID == machine.credentialID })
    #expect(store.endpoints == [machine], "A failed removal must preserve the machine")
}

@Test @MainActor func composerStatusReadsTheDurableOutboxRatherThanTheLegacySnapshot() async throws {
    let store = DieterStore(restoreSync: false)
    defer { store.disconnect() }
    store.selectedCardID = "card"
    var request = Dieter_V1_SendMessageRequest(); request.cardID = "card"
    try await store.outbox.enqueue(
        DieterOutboxEntry(
            commandID: "send", clientID: "client", endpointID: store.endpoint.id, kind: .sendMessage,
            request: try request.serializedData(), optimisticID: "pending-message", attempts: 1,
            state: .retrying, createdAt: .now))
    #expect(store.syncDiskState.outbox.isEmpty)
    #expect(store.conversationContext.deliveryStatus()?.phase == .retrying)
    #expect(store.conversationContext.deliveryStatus()?.itemIDs == ["pending-message"])
}

@Test @MainActor func removingOfflineMachineClearsOnlyItsDirectoryAndKeepsOtherMachines() {
    let store = DieterStore(restoreSync: false)
    defer { store.disconnect() }
    let removed = DieterEndpoint(name: "Old Mini", host: "gateway.example", port: 443, secure: true, daemonID: "old")
    let retained = DieterEndpoint(
        name: "Current Mac", host: "gateway.example", port: 443, secure: true, daemonID: "current")
    store.endpoints = [removed, retained]; store.endpoint = retained
    var oldProject = Dieter_V1_Project(); oldProject.id = "old-project"
    var currentProject = Dieter_V1_Project(); currentProject.id = "current-project"
    store.projectDirectory = [oldProject.id: oldProject, currentProject.id: currentProject]
    store.projectEndpointIDs = [oldProject.id: removed.id, currentProject.id: retained.id]
    var board = Dieter_V1_Board(); board.id = "old-board"; board.projectID = oldProject.id
    store.navigationBoards = [oldProject.id: [board]]
    store.selectedProjectID = currentProject.id
    store.forgetMachineFromDirectory(removed)
    #expect(store.endpoints == [retained])
    #expect(store.projectDirectory[oldProject.id] == nil)
    #expect(store.navigationBoards[oldProject.id] == nil)
    #expect(store.projectDirectory[currentProject.id] != nil)
    #expect(store.endpoint == retained && store.selectedProjectID == currentProject.id)

    // The last machine must not reappear through the legacy state's fallback.
    store.state.projects = [currentProject]
    store.forgetMachineFromDirectory(retained)
    #expect(store.projects.isEmpty)
    #expect(store.selectedProjectID.isEmpty)
}
