import DieterAPI
import Foundation
import Testing
@testable import DieterMac

private actor ChangesFixtureRPC: ProjectChangesRPC {
    var snapshot = makeSnapshot()
    var holdDiffs = false
    var holdChanges = false
    var failChanges = false
    var requests: [Dieter_V1_GetDiffRequest] = []
    var starts: [Dieter_V1_StartGitOperationRequest] = []
    var reads = 0
    var diffWaiters: [Int: CheckedContinuation<Dieter_V1_FileDiff, any Error>] = [:]
    var operationWaiter: CheckedContinuation<Dieter_V1_GitOperation, any Error>?
    var changesWaiter: CheckedContinuation<Dieter_V1_Changeset, any Error>?

    static func makeSnapshot(project: String = "project", revision: String = "r1", staged: Bool = false)
        -> Dieter_V1_Changeset
    {
        var value = Dieter_V1_Changeset()
        value.projectID = project; value.revision = revision; value.branch = "main"
        value.files = ["a.swift", "b.swift"].map { path in
            var file = Dieter_V1_ChangedFile()
            file.path = path; file.staged = staged; file.unstaged = !staged
            return file
        }
        return value
    }

    func configure(
        project: String = "project", revision: String = "r1", staged: Bool = false, holdDiffs: Bool = false,
        holdChanges: Bool = false, failChanges: Bool = false
    ) {
        snapshot = Self.makeSnapshot(project: project, revision: revision, staged: staged)
        self.holdDiffs = holdDiffs; self.holdChanges = holdChanges
        self.failChanges = failChanges
    }

    func changeset(projectID: String) async throws -> Dieter_V1_Changeset {
        reads += 1
        if failChanges { throw URLError(.networkConnectionLost) }
        if holdChanges { return try await withCheckedThrowingContinuation { changesWaiter = $0 } }
        return snapshot
    }

    func fileDiff(_ request: Dieter_V1_GetDiffRequest) async throws -> Dieter_V1_FileDiff {
        let index = requests.count
        requests.append(request)
        if holdDiffs { return try await withCheckedThrowingContinuation { diffWaiters[index] = $0 } }
        return Self.makeDiff(request)
    }

    static func makeDiff(_ request: Dieter_V1_GetDiffRequest, patch: String? = nil, truncated: Bool = false)
        -> Dieter_V1_FileDiff
    {
        var value = Dieter_V1_FileDiff()
        value.projectID = request.projectID; value.path = request.path; value.section = request.section
        value.revision = request.expectedRevision;
        value.patch = patch ?? "+\(request.path) at \(request.expectedRevision)"
        value.truncated = truncated; value.nextOffset = truncated ? Int64(value.patch.utf8.count) : 0
        return value
    }

    func resolveDiff(_ index: Int, patch: String? = nil, truncated: Bool = false) {
        diffWaiters.removeValue(forKey: index)?.resume(
            returning: Self.makeDiff(requests[index], patch: patch, truncated: truncated))
    }

    func startGitOperation(_ request: Dieter_V1_StartGitOperationRequest) async throws -> Dieter_V1_GitOperation {
        starts.append(request)
        return try await withCheckedThrowingContinuation { operationWaiter = $0 }
    }

    func gitOperation(id: String) async throws -> Dieter_V1_GitOperation { .init() }

    func finishOperation(succeeded: Bool) {
        var operation = Dieter_V1_GitOperation()
        operation.id = "operation"; operation.status = succeeded ? "succeeded" : "failed"
        operation.error = succeeded ? "" : "Index changed; refresh and try again"
        operationWaiter?.resume(returning: operation); operationWaiter = nil
    }

    func finishChanges() {
        holdChanges = false
        changesWaiter?.resume(returning: snapshot); changesWaiter = nil
    }

    var diffCount: Int { requests.count }
    var startCount: Int { starts.count }
    var waitingForChanges: Bool { changesWaiter != nil }
    var waitingForOperation: Bool { operationWaiter != nil }
}

@MainActor private func eventually(_ predicate: () async -> Bool) async throws {
    for _ in 0..<200 {
        if await predicate() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw NSError(domain: "ChangesTestTimeout", code: 1)
}

@Test @MainActor func projectDiffLatestSelectionWinsEvenWhenReturningToTheSameFile() async throws {
    let rpc = ChangesFixtureRPC()
    await rpc.configure(holdDiffs: true)
    let model = ProjectChangesModel(); model.bind(projectID: "project", client: rpc)
    await model.refresh()
    try await eventually { await rpc.diffCount == 1 }
    model.select(.init(path: "b.swift", section: "unstaged"))
    #expect(model.diff == nil)
    #expect(model.diffLoading)
    try await eventually { await rpc.diffCount == 2 }
    model.select(.init(path: "a.swift", section: "unstaged"))
    try await eventually { await rpc.diffCount == 3 }
    await rpc.resolveDiff(2, patch: "latest A")
    await model.waitForDiff()
    await rpc.resolveDiff(1, patch: "obsolete B")
    await rpc.resolveDiff(0, patch: "obsolete A")
    try await Task.sleep(for: .milliseconds(20))
    #expect(model.diff?.patch == "latest A")
    #expect(model.selection?.path == "a.swift")
    #expect(!model.diffLoading)
    model.suspend()
}

@Test @MainActor func projectDiffRejectsPreviousTargetAndReusesUnchangedRevision() async throws {
    let old = ChangesFixtureRPC(); await old.configure(holdDiffs: true)
    let current = ChangesFixtureRPC(); await current.configure(project: "other")
    let model = ProjectChangesModel(); model.bind(projectID: "project", client: old)
    await model.refresh(); try await eventually { await old.diffCount == 1 }
    model.bind(projectID: "other", client: current)
    #expect(model.diff == nil)
    await model.refresh(); await model.waitForDiff()
    await old.resolveDiff(0, patch: "wrong project")
    await model.refresh(); await model.waitForDiff()
    #expect(await current.diffCount == 1)
    #expect(model.diff?.projectID == "other")
    #expect(model.diff?.patch != "wrong project")
    model.suspend()
}

@Test @MainActor func projectStageLocksBeforeSubmissionAndThroughReconciliation() async throws {
    let rpc = ChangesFixtureRPC()
    let model = ProjectChangesModel(); model.bind(projectID: "project", client: rpc)
    await model.refresh(); await model.waitForDiff()
    let task = try #require(model.startOperation(kind: "stage", path: "a.swift"))
    #expect(model.mutationsDisabled)
    #expect(model.startOperation(kind: "stage", path: "a.swift") == nil)
    try await eventually { await rpc.waitingForOperation }
    await rpc.configure(revision: "r2", staged: true, holdChanges: true)
    await rpc.finishOperation(succeeded: true)
    try await eventually { await rpc.waitingForChanges }
    #expect(model.mutationsDisabled)
    #expect(model.startOperation(kind: "unstage") == nil)
    await rpc.finishChanges()
    #expect(await task.value)
    await model.waitForDiff()
    #expect(model.selection == .init(path: "a.swift", section: "staged"))
    #expect(model.diff?.section == "staged")
    #expect(!model.mutationsDisabled)
    #expect(await rpc.startCount == 1)
    model.suspend()
}

@Test @MainActor func projectCommitFailureSurvivesRefreshAndPreservesDraft() async throws {
    let rpc = ChangesFixtureRPC(); await rpc.configure(staged: true)
    let model = ProjectChangesModel(); model.bind(projectID: "project", client: rpc)
    await model.refresh(); await model.waitForDiff()
    model.commitSubject = "Keep my subject"; model.commitBody = "Keep my description"
    let task = try #require(model.startOperation(kind: "commit"))
    try await eventually { await rpc.waitingForOperation }
    await rpc.finishOperation(succeeded: false)
    #expect(await task.value == false)
    await model.refresh()
    #expect(model.operationError == "Index changed; refresh and try again")
    #expect(model.commitSubject == "Keep my subject")
    #expect(model.commitBody == "Keep my description")
    model.suspend()
}

@Test @MainActor func projectDiffPaginationCannotAppendOnePageTwice() async throws {
    let rpc = ChangesFixtureRPC(); await rpc.configure(holdDiffs: true)
    let model = ProjectChangesModel(); model.bind(projectID: "project", client: rpc)
    await model.refresh(); try await eventually { await rpc.diffCount == 1 }
    await rpc.resolveDiff(0, patch: "first\n", truncated: true)
    await model.waitForDiff()
    model.loadMore(); model.loadMore()
    try await eventually { await rpc.diffCount == 2 }
    await rpc.resolveDiff(1, patch: "second\n")
    await model.waitForDiff()
    #expect(model.diff?.patch == "first\nsecond\n")
    #expect(await rpc.diffCount == 2)
    #expect(model.diff?.truncated == false)
    model.suspend()
}

@Test @MainActor func projectChangesNavigationIsImmediateAndIndependentOfFiles() async {
    let store = DieterStore(restoreSync: false)
    var project = Dieter_V1_Project(); project.id = "project"; project.name = "Project"
    store.projectDirectory = [project.id: project]
    await store.openProjectChanges(project.id)
    #expect(store.section == .changes)
    #expect(store.selectedProjectID == project.id)
    // Invalidate old directory responses once, without starting a Files load.
    #expect(store.fileListingGeneration == 1)
    #expect(store.stateRequestGeneration == 0)
}

@Test @MainActor func projectOperationDoesNotReportSuccessBeforeAuthoritativeRefresh() async throws {
    let rpc = ChangesFixtureRPC()
    let model = ProjectChangesModel(); model.bind(projectID: "project", client: rpc)
    await model.refresh(); await model.waitForDiff()
    let task = try #require(model.startOperation(kind: "stage"))
    try await eventually { await rpc.waitingForOperation }
    await rpc.configure(failChanges: true)
    await rpc.finishOperation(succeeded: true)
    #expect(await task.value == false)
    #expect(model.mutationsDisabled)
    #expect(model.refreshError != nil)
    #expect(model.notice == nil)
    #expect(model.startOperation(kind: "stage") == nil)
    await rpc.configure(revision: "r2", staged: true)
    await model.refresh()
    #expect(!model.mutationsDisabled)
    #expect(model.stagedFiles.count == 2)
    #expect(await rpc.startCount == 1)
    model.suspend()
}

@Test @MainActor func projectReconnectRejectsOldCompletionWithoutResubmitting() async throws {
    let old = ChangesFixtureRPC()
    let model = ProjectChangesModel(); model.bind(projectID: "project", client: old)
    await model.refresh(); await model.waitForDiff()
    let operation = try #require(model.startOperation(kind: "stage"))
    try await eventually { await old.waitingForOperation }
    let current = ChangesFixtureRPC()
    await current.configure(revision: "reconnected", staged: true)
    model.bind(projectID: "project", client: current)
    #expect(model.mutationsDisabled)
    await model.refresh(); await model.waitForDiff()
    await old.finishOperation(succeeded: true)
    #expect(await operation.value == false)
    #expect(model.changes?.revision == "reconnected")
    #expect(model.diff?.revision == "reconnected")
    #expect(model.notice == nil)
    #expect(!model.mutationsDisabled)
    #expect(await old.startCount == 1)
    #expect(await current.startCount == 0)
    model.suspend()
}
