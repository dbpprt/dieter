import DieterAPI
import Foundation
import Testing
@testable import DieterMac

private actor MergeLifecycleFixture: WorktreeRPC {
    var operations: [Dieter_V1_StartGitOperationRequest] = []
    var moved: [String] = []
    var workspaceRead: CheckedContinuation<Dieter_V1_Workspace, Never>?
    var readingWorkspace: Bool { workspaceRead != nil }
    var failCleanup = false
    func setFailCleanup() { failCleanup = true }
    func finishWorkspace() { workspaceRead?.resume(returning: .init()); workspaceRead = nil }
    func workspace(cardID: String) async throws -> Dieter_V1_Workspace {
        await withCheckedContinuation { workspaceRead = $0 }
    }
    func changeset(cardID: String) async throws -> Dieter_V1_Changeset { .init() }
    func fileDiff(_ request: Dieter_V1_GetDiffRequest) async throws -> Dieter_V1_FileDiff { .init() }
    func commitDiff(_ request: Dieter_V1_GetDiffRequest) async throws -> Dieter_V1_FileDiff { .init() }
    func changeComments(cardID: String, revision: String) async throws -> Dieter_V1_ChangeCommentsResponse { .init() }
    func scmCapabilities(cardID: String) async throws -> Dieter_V1_SCMCapabilities { .init() }
    func addChangeComment(_ request: Dieter_V1_AddChangeCommentRequest) async throws -> Dieter_V1_ChangeComment {
        .init()
    }
    func updateConversationWorkspace(_ request: Dieter_V1_UpdateConversationWorkspaceRequest) async throws
        -> Dieter_V1_Card
    { .init() }
    func startGitOperation(_ request: Dieter_V1_StartGitOperationRequest) async throws -> Dieter_V1_GitOperation {
        operations.append(request)
        var operation = Dieter_V1_GitOperation()
        operation.id = UUID().uuidString; operation.cardID = request.cardID; operation.kind = request.kind
        operation.status = request.kind == "cleanup" && failCleanup ? "failed" : "succeeded"
        return operation
    }
    func gitOperation(id: String) async throws -> Dieter_V1_GitOperation { throw CancellationError() }
    func cancelGitOperation(id: String) async throws -> Dieter_V1_GitOperation { throw CancellationError() }
    func watchGitOperation(
        id: String, after: UInt64, receive: @escaping @Sendable (Dieter_V1_GitOperationFrame) async -> Void
    ) async throws {
        try await Task.sleep(nanoseconds: 3_600_000_000_000)
    }
    func moveCard(_ request: Dieter_V1_MoveCardRequest) async throws -> Dieter_V1_Card {
        moved.append(request.cardID); var card = Dieter_V1_Card(); card.id = request.cardID; return card
    }
}

@Test @MainActor func mergeFlowCannotCleanUpTheNewlySelectedWorkspace() async throws {
    let rpc = MergeLifecycleFixture(), model = WorktreeChangesModel()
    var card = Dieter_V1_Card(); card.id = "card_A"; card.projectID = "project_A"
    model.bind(
        target: .init(endpointID: "machine", projectID: card.projectID, conversationID: card.id), client: rpc,
        card: card, doneLaneID: "done")
    let task = Task {
        await model.performMergeFlow(
            strategy: "merge", subject: "Merge", body: "", validate: false, removeWorkspace: true, moveCardToDone: true)
    }
    while !(await rpc.readingWorkspace) { await Task.yield() }
    card.id = "card_B"; card.projectID = "project_B"
    model.bind(
        target: .init(endpointID: "machine", projectID: card.projectID, conversationID: card.id), client: rpc,
        card: card, doneLaneID: "done")
    await rpc.finishWorkspace()
    #expect(await task.value == false)
    #expect(await rpc.operations.map(\.cardID) == ["card_A"])
    #expect(await rpc.moved.isEmpty)
    #expect(model.workspaceToast == nil)
    #expect(model.card?.id == "card_B")
    model.resetWorkspaceSurface()
}

@Test @MainActor func failedCleanupStopsMergeFlowBeforeMovingCardToDone() async throws {
    let rpc = MergeLifecycleFixture(), model = WorktreeChangesModel()
    await rpc.setFailCleanup()
    var card = Dieter_V1_Card(); card.id = "card_A"; card.projectID = "project_A"
    model.bind(
        target: .init(endpointID: "machine", projectID: card.projectID, conversationID: card.id), client: rpc,
        card: card, doneLaneID: "done")
    let task = Task {
        await model.performMergeFlow(
            strategy: "merge", subject: "Merge", body: "", validate: false, removeWorkspace: true, moveCardToDone: true)
    }
    while !(await rpc.readingWorkspace) { await Task.yield() }
    await rpc.finishWorkspace()
    #expect(await task.value == false)
    #expect(await rpc.operations.map(\.kind) == [GitOperationKind.mergeLocal.rawValue, "cleanup"])
    #expect(await rpc.moved.isEmpty)
    model.resetWorkspaceSurface()
}
