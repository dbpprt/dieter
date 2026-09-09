import DieterAPI
import Foundation
import Observation

struct ProjectChangeSelection: Hashable, Sendable {
    var path: String
    var section: String
}

/// One checkout's presentation state. Reads belong to a binding generation;
/// abandoning the UI never cancels a daemon-owned Git operation.
@MainActor @Observable
final class ProjectChangesModel {
    private(set) var projectID = ""
    private(set) var changes: Dieter_V1_Changeset?
    private(set) var diff: Dieter_V1_FileDiff?
    private(set) var selection: ProjectChangeSelection?
    private(set) var operation: Dieter_V1_GitOperation?
    private(set) var refreshing = false
    private(set) var diffLoading = false
    private(set) var pendingKind: String?
    private(set) var needsReconciliation = false
    var refreshError: String?
    var diffError: String?
    var operationError: String?
    var notice: String?
    var commitSubject = ""
    var commitBody = ""

    @ObservationIgnored private var client: (any ProjectChangesRPC)?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var diffGeneration: UInt64 = 0
    @ObservationIgnored private var refreshAgain = false
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var diffTask: Task<Void, Never>?
    @ObservationIgnored private var operationTask: Task<Bool, Never>?
    @ObservationIgnored private var cache: [ProjectChangeSelection: Dieter_V1_FileDiff] = [:]
    @ObservationIgnored private var cacheOrder: [ProjectChangeSelection] = []

    var stagedFiles: [Dieter_V1_ChangedFile] { changes?.files.filter(\.staged) ?? [] }
    var unstagedFiles: [Dieter_V1_ChangedFile] { changes?.files.filter(\.unstaged) ?? [] }
    var busy: Bool {
        pendingKind != nil || needsReconciliation || GitOperationStatus.active(operation?.status ?? "")
            || !(changes?.currentOperationID.isEmpty ?? true)
    }
    var mutationsDisabled: Bool { client == nil || changes == nil || busy || changes?.volatile == true }

    func bind(projectID: String, client: any ProjectChangesRPC) {
        guard self.projectID != projectID || self.client !== client else { return }
        let sameProject = self.projectID == projectID
        suspend()
        self.client = client
        self.projectID = projectID
        if !sameProject {
            changes = nil; diff = nil; selection = nil; operation = nil
            commitSubject = ""; commitBody = ""; operationError = nil; notice = nil
        }
        refreshError = nil; diffError = nil
        cache = [:]; cacheOrder = []
        needsReconciliation = true
    }

    func suspend() {
        generation &+= 1; diffGeneration &+= 1
        refreshTask?.cancel(); refreshTask = nil
        diffTask?.cancel(); diffTask = nil
        operationTask?.cancel(); operationTask = nil
        refreshing = false; diffLoading = false; refreshAgain = false
        needsReconciliation = true
        pendingKind = nil
    }

    func refresh() async {
        if let refreshTask {
            refreshAgain = true
            await refreshTask.value
            return
        }
        guard let client, !projectID.isEmpty else { return }
        let token = generation
        let projectID = projectID
        refreshing = true
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.owns(token) { self.refreshing = false; self.refreshTask = nil }
            }
            repeat {
                self.refreshAgain = false
                do {
                    let value = try await client.changeset(projectID: projectID)
                    guard self.owns(token) else { return }
                    self.accept(value)
                    self.refreshError = nil
                    self.needsReconciliation = false
                    if !value.currentOperationID.isEmpty {
                        let observed = try await client.gitOperation(id: value.currentOperationID)
                        guard self.owns(token) else { return }
                        self.operation = observed
                    } else if self.pendingKind == nil {
                        self.operation = nil
                    }
                } catch {
                    guard self.owns(token) else { return }
                    self.refreshError = DieterRPCFailure.message(for: error)
                    return
                }
            } while self.refreshAgain && self.owns(token)
        }
        refreshTask = task
        await task.value
    }

    private func owns(_ token: UInt64) -> Bool { generation == token && !Task.isCancelled }

    private func accept(_ value: Dieter_V1_Changeset) {
        let revisionChanged = changes?.revision != value.revision
        if revisionChanged { cache = [:]; cacheOrder = [] }
        if revisionChanged, pendingKind == nil { notice = nil }
        if changes != value { changes = value }
        let choices =
            value.files.filter(\.unstaged).map { ProjectChangeSelection(path: $0.path, section: "unstaged") }
            + value.files.filter(\.staged).map { ProjectChangeSelection(path: $0.path, section: "staged") }
        let next =
            selection.flatMap { current in
                choices.first(where: { $0 == current }) ?? choices.first(where: { $0.path == current.path })
            } ?? choices.first
        if let next {
            if next != selection || revisionChanged || diff == nil {
                select(next, reload: revisionChanged, retryStale: false)
            }
        } else {
            diffTask?.cancel(); diffGeneration &+= 1
            selection = nil; diff = nil; diffError = nil; diffLoading = false
        }
    }

    func select(_ next: ProjectChangeSelection, reload: Bool = false, retryStale: Bool = true) {
        guard selection != next || reload || diff == nil else { return }
        diffTask?.cancel(); diffGeneration &+= 1
        let sameSelection = selection == next
        selection = next
        diffError = nil
        if let cached = cache[next], cached.revision == changes?.revision, !reload {
            diff = cached; diffLoading = false
            return
        }
        if !sameSelection { diff = nil }
        fetchDiff(append: false, retryStale: retryStale)
    }

    func loadMore() {
        guard !diffLoading, diff?.truncated == true else { return }
        fetchDiff(append: true, retryStale: true)
    }

    func retryDiff() {
        guard let selection else { return }
        select(selection, reload: true)
    }

    private func fetchDiff(append: Bool, retryStale: Bool) {
        guard let client, let changes, let selection else { return }
        let token = generation
        diffGeneration &+= 1
        let requestID = diffGeneration
        var request = Dieter_V1_GetDiffRequest()
        request.projectID = projectID; request.path = selection.path; request.section = selection.section
        request.expectedRevision = changes.revision; request.limit = 1_048_576
        if append { request.offset = diff?.nextOffset ?? 0 }
        let previous = append ? diff : nil
        diffLoading = true
        diffTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.owns(token), self.diffGeneration == requestID { self.diffLoading = false } }
            do {
                var page = try await client.fileDiff(request)
                guard self.owns(token), self.diffGeneration == requestID,
                    self.selection == selection, self.changes?.revision == request.expectedRevision
                else { return }
                if let previous { page.patch = previous.patch + page.patch }
                self.diff = page
                self.diffError = nil
                self.cache[selection] = page
                self.cacheOrder.removeAll { $0 == selection }
                self.cacheOrder.append(selection)
                while self.cacheOrder.count > 8 || self.cache.values.reduce(0, { $0 + $1.patch.utf8.count }) > 8_388_608
                {
                    guard !self.cacheOrder.isEmpty else { break }
                    self.cache.removeValue(forKey: self.cacheOrder.removeFirst())
                }
            } catch {
                guard self.owns(token), self.diffGeneration == requestID else { return }
                let message = DieterRPCFailure.message(for: error)
                self.diffError = message
                if retryStale && message.localizedCaseInsensitiveContains("refresh") {
                    // Refresh starts a diff with retryStale=false: never recurse
                    // while an external writer is continuously changing files.
                    await self.refresh()
                }
            }
        }
    }

    func waitForDiff() async { await diffTask?.value }

    @discardableResult
    func startOperation(kind: String, path: String = "", parameters: [String: String] = [:]) -> Task<Bool, Never>? {
        guard !mutationsDisabled, let client, let changes else { return nil }
        let token = generation
        var request = Dieter_V1_StartGitOperationRequest()
        request.projectID = projectID; request.kind = kind; request.expectedRevision = changes.revision
        request.parameters = parameters
        if !path.isEmpty { request.parameters["path"] = path }
        pendingKind = kind
        operationError = nil; notice = nil
        let task = Task { [weak self] () -> Bool in
            guard let self else { return false }
            defer { if self.owns(token) { self.pendingKind = nil; self.operationTask = nil } }
            do {
                var value = try await client.startGitOperation(request)
                guard self.owns(token) else { return false }
                self.operation = value
                let deadline = Date().addingTimeInterval(3_600)
                while GitOperationStatus.active(value.status), value.status != "waiting_for_resolution",
                    Date() < deadline
                {
                    try await DieterTaskSleep.milliseconds(250)
                    value = try await client.gitOperation(id: value.id)
                    guard self.owns(token) else { return false }
                    self.operation = value
                }
                self.needsReconciliation = true
                await self.refresh()
                guard self.owns(token) else { return false }
                guard value.status == "succeeded" else {
                    self.operationError =
                        value.error.isEmpty ? "The operation ended with status \(value.status)." : value.error
                    return false
                }
                guard !self.needsReconciliation else { return false }
                if kind == "commit" { self.commitSubject = ""; self.commitBody = "" }
                self.notice = Self.completedTitle(kind)
                return true
            } catch {
                guard self.owns(token) else { return false }
                self.operationError = DieterRPCFailure.message(for: error)
                self.needsReconciliation = true
                await self.refresh()
                return false
            }
        }
        operationTask = task
        return task
    }

    static func completedTitle(_ kind: String) -> String {
        switch kind {
        case "stage": "Changes staged"
        case "unstage": "Changes unstaged"
        case "commit": "Staged changes committed"
        case "discard_changes": "Changes discarded · recovery copy saved"
        default: "Operation completed"
        }
    }
}
