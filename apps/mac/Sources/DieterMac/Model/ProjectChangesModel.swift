import DieterAPI
import DieterCore
import Foundation
import Observation
import SharedCore

struct ProjectChangeSelection: Hashable, Sendable {
    var path: String
    var section: String
}

/// One checkout's changes outside any conversation's worktree, kept by the
/// shared core on the checkout's machine. An active surface refreshes
/// itself; leaving the view never cancels a machine-owned Git operation.
@MainActor @Observable
final class ProjectChangesModel {
    private(set) var projectID = ""
    private(set) var changes: Dieter_V1_Changeset?
    private(set) var diff: Dieter_V1_FileDiff?
    /// The diff's lines as the core numbers them.
    private(set) var diffLines: [UnifiedDiffLine] = []
    private(set) var selection: ProjectChangeSelection?
    private(set) var operation: Dieter_V1_GitOperation?
    private(set) var refreshing = false
    private(set) var diffLoading = false
    private(set) var pendingKind: String?
    private(set) var needsReconciliation = false
    private(set) var busy = false
    var refreshError: String?
    var diffError: String?
    var operationError: String?
    var notice: String?
    var commitSubject = ""
    var commitBody = ""
    /// Visible and foregrounded: the core refreshes the checkout periodically.
    var active = false {
        didSet {
            guard active != oldValue else { return }
            let on = active
            send { $0.active = .with { $0.on = on } }
        }
    }
    @ObservationIgnored private var core: CoreClient?
    @ObservationIgnored private let scope = "changes-\(UUID().uuidString)"
    @ObservationIgnored private var subscription: SliceSubscription?
    /// The checkout the core was last told to show; slices for another are stale.
    @ObservationIgnored private var bound = ClientProjectChangesTarget()
    @ObservationIgnored private var queued: Task<Void, Never>?
    /// A selection on its way to the core; it shows until the core reports it.
    @ObservationIgnored private var requested: ProjectChangeSelection?
    private var mutable = false

    var stagedFiles: [Dieter_V1_ChangedFile] { changes?.files.filter(\.staged) ?? [] }
    var unstagedFiles: [Dieter_V1_ChangedFile] { changes?.files.filter(\.unstaged) ?? [] }
    var mutationsDisabled: Bool { core == nil || !mutable }

    /// Shows a checkout's changes on the machine that holds it.
    func bind(projectID: String, checkoutID: String, daemonID: String, core: CoreClient) {
        if subscription == nil {
            self.core = core
            subscription = SliceSubscription(client: core, slice: .projectChanges, scope: scope) { [weak self] update in
                guard let self, case .projectChanges(let slice) = update.value else { return }
                self.fold(slice)
            }
        }
        let next = ClientProjectChangesTarget.with {
            $0.projectID = projectID
            $0.checkoutID = checkoutID
            $0.daemonID = daemonID
        }
        guard next != bound else { return }
        if self.projectID != projectID {
            changes = nil; diff = nil; diffLines = []; selection = nil; operation = nil
            commitSubject = ""; commitBody = ""; operationError = nil; notice = nil
        }
        refreshError = nil; diffError = nil
        self.projectID = projectID
        bound = next
        let on = active
        send { $0.bind = next }
        send { $0.active = .with { $0.on = on } }
    }

    /// Stops refreshing while the view is hidden.
    func suspend() { active = false }

    func disconnect() { active = false }

    private func fold(_ slice: ClientProjectChangesSlice) {
        guard slice.projectID == bound.projectID, slice.checkoutID == bound.checkoutID,
            slice.daemonID == bound.daemonID
        else { return }
        let changes = slice.hasChanges ? slice.changes : nil
        if self.changes != changes { self.changes = changes }
        let reported =
            slice.hasSelection
            ? ProjectChangeSelection(
                path: slice.selection.path, section: slice.selection.staged ? "staged" : "unstaged")
            : nil
        // The core answered for the requested file (it may have followed it to
        // the other half), or the file is gone.
        if reported?.path == requested?.path || changes?.files.contains(where: { $0.path == requested?.path }) != true {
            requested = nil
        }
        let selection = reported ?? requested
        if self.selection != selection { self.selection = selection }
        let diff = slice.hasDiff ? slice.diff : nil
        if self.diff != diff { self.diff = diff }
        let lines = slice.diffRows.map(UnifiedDiffLine.init)
        if diffLines != lines { diffLines = lines }
        if diffLoading != slice.diffLoading { diffLoading = slice.diffLoading }
        let operation = slice.hasOperation ? slice.operation : nil
        if self.operation != operation { self.operation = operation }
        let pending = slice.pendingKind.isEmpty ? nil : slice.pendingKind
        if pendingKind != pending { pendingKind = pending }
        if needsReconciliation != slice.needsReconciliation { needsReconciliation = slice.needsReconciliation }
        if refreshing != slice.refreshing { refreshing = slice.refreshing }
        if busy != slice.busy { busy = slice.busy }
        mutable = !slice.mutationsDisabled
        let refreshError = slice.refreshError.isEmpty ? nil : slice.refreshError
        if self.refreshError != refreshError { self.refreshError = refreshError }
        let diffError = slice.diffError.isEmpty ? nil : slice.diffError
        if self.diffError != diffError { self.diffError = diffError }
        let operationError = slice.operationError.isEmpty ? nil : slice.operationError
        if self.operationError != operationError { self.operationError = operationError }
        let notice = slice.notice.isEmpty ? nil : slice.notice
        if self.notice != notice { self.notice = notice }
        // The view opens on the first change rather than an empty diff.
        if selection == nil, pendingKind == nil, let changes,
            let first = changes.files.first(where: \.unstaged).map({
                ProjectChangeSelection(path: $0.path, section: "unstaged")
            })
                ?? changes.files.first(where: \.staged).map({ ProjectChangeSelection(path: $0.path, section: "staged") }
                )
        {
            select(first)
        }
    }

    /// Sends a command without waiting for it, after those sent before.
    private func send(_ build: @escaping (inout ClientProjectChangesCommand) -> Void) {
        guard core != nil else { return }
        let previous = queued
        queued = Task { [weak self] in
            await previous?.value
            await self?.run(afterQueued: false, build)
        }
    }

    @discardableResult
    private func run(
        afterQueued: Bool = true, _ build: (inout ClientProjectChangesCommand) -> Void
    ) async -> ClientResult? {
        guard let core else { return nil }
        if afterQueued, let queued { await queued.value }
        var command = ClientProjectChangesCommand()
        command.scope = scope
        build(&command)
        let sent = command, target = bound
        do {
            let result = try await core.dispatch(.with { $0.projectChanges = sent })
            if case .projectChanges(let slice)? = result.result { fold(slice) }
            return result
        } catch let failure as CoreFailure {
            if target == bound { operationError = failure.message }
            return nil
        } catch {
            return nil
        }
    }

    func refresh() async {
        guard !bound.projectID.isEmpty else { return }
        await run { $0.refresh = ClientReviewStep() }
    }

    /// Shows one half of a file; the latest selection wins.
    func select(_ next: ProjectChangeSelection, reload: Bool = false, retryStale: Bool = true) {
        guard selection != next || reload || diff == nil else { return }
        if selection != next { diff = nil; diffLines = [] }
        selection = next
        requested = next
        send { command in
            command.select = .with {
                $0.path = next.path
                $0.staged = next.section == "staged"
            }
        }
    }

    func loadMore() {
        guard !diffLoading, diff?.truncated == true else { return }
        send { $0.loadMoreDiff = ClientReviewStep() }
    }

    func retryDiff() {
        guard let selection else { return }
        select(selection, reload: true)
    }

    /// Waits until the selected diff has arrived.
    func waitForDiff() async {
        if let queued { await queued.value }
        let deadline = ContinuousClock.now + .seconds(30)
        while diffLoading, ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    /// Runs a checkout operation; success is reported only after the
    /// refresh that shows it. A commit's draft survives a failure.
    @discardableResult
    func startOperation(kind: String, path: String = "", parameters: [String: String] = [:]) -> Task<Bool, Never>? {
        guard !mutationsDisabled else { return nil }
        var parameters = parameters
        if !path.isEmpty { parameters["path"] = path }
        let request = parameters
        pendingKind = kind
        operationError = nil
        notice = nil
        return Task { [weak self] () -> Bool in
            guard let self else { return false }
            let result = await self.run { command in
                command.run = .with {
                    $0.kind = kind
                    $0.parameters = request
                }
            }
            if self.pendingKind == kind { self.pendingKind = nil }
            guard case .outcome(let outcome)? = result?.result, outcome.succeeded else { return false }
            if kind == "commit" { self.commitSubject = ""; self.commitBody = "" }
            return true
        }
    }
}
