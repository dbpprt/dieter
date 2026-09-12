import DieterAPI
import DieterCore
import Foundation
import Observation

@MainActor @Observable
final class ConversationProcessesModel {
    static let maximumOutputBytes = 256 * 1024
    private(set) var target = WorkspaceTarget(endpointID: "", projectID: "")
    private(set) var processes: [Dieter_V1_Execution] = []
    private(set) var selectedID: String?
    private(set) var stdout = Data()
    private(set) var stderr = Data()
    private(set) var outputTruncated = false
    private(set) var loading = false
    private(set) var stopping = false
    private(set) var error: String?
    var active = false { didSet { if active != oldValue { updateActivity() } } }
    @ObservationIgnored private var rpc: (any ProcessesRPC)?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var watchGeneration = 0
    @ObservationIgnored private var sequence: UInt64 = 0
    @ObservationIgnored private var watchedID: String?
    @ObservationIgnored private var completedWatchID: String?
    @ObservationIgnored private var polling: Task<Void, Never>?
    @ObservationIgnored private var watching: Task<Void, Never>?

    deinit { polling?.cancel(); watching?.cancel() }

    var selected: Dieter_V1_Execution? { processes.first { $0.id == selectedID } }
    var connected: Bool { rpc != nil }

    func bind(target: WorkspaceTarget, client: (any ProcessesRPC)?) {
        guard self.target != target || rpc !== client else { return }
        stopSubscriptions(); generation &+= 1
        if self.target != target {
            processes = []; selectedID = nil; stdout = Data(); stderr = Data(); sequence = 0
            outputTruncated = false
        }
        self.target = target; rpc = client; loading = false; stopping = false; error = nil
        completedWatchID = nil
        if active { updateActivity() }
    }

    func refresh() async {
        guard active, !loading, let rpc, !target.conversationID.isEmpty else { return }
        let scope = target; let request = generation
        loading = true
        defer { if request == generation { loading = false } }
        do {
            let response = try await rpc.executions(projectID: scope.projectID, cardID: scope.conversationID)
            guard request == generation, self.rpc === rpc, active, !Task.isCancelled else { return }
            processes = response.executions.filter {
                $0.cardID == scope.conversationID && $0.projectID == scope.projectID
            }
            .map { value in processes.first(where: { $0.id == value.id && $0.sequence > value.sequence }) ?? value }
            .sorted { $0.createdAt > $1.createdAt }
            error = nil
            if !processes.contains(where: { $0.id == selectedID }) {
                select(processes.first?.id)
            } else {
                startWatch()
            }
        } catch {
            guard request == generation, self.rpc === rpc, active, !Task.isCancelled else { return }
            self.error = DieterRPCFailure.message(for: error)
        }
    }

    func select(_ id: String?) {
        guard id == nil || processes.contains(where: { $0.id == id }) else { return }
        if selectedID != id {
            stopWatch(); selectedID = id; stdout = Data(); stderr = Data(); sequence = 0
            outputTruncated = false; completedWatchID = nil
        }
        startWatch()
    }

    func stopSelected() async {
        guard active, !stopping, let rpc, let process = selected, process.status == "running",
            process.cardID == target.conversationID, process.projectID == target.projectID
        else { return }
        let request = generation; stopping = true
        defer { if request == generation { stopping = false } }
        do {
            let value = try await rpc.cancelExecution(id: process.id)
            guard request == generation, self.rpc === rpc else { return }
            update(value)
        } catch {
            guard request == generation, self.rpc === rpc else { return }
            self.error = DieterRPCFailure.message(for: error)
        }
    }

    private func updateActivity() {
        stopSubscriptions()
        guard active, rpc != nil else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                guard self != nil else { return }
                await self?.refresh()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
        startWatch()
    }

    private func stopSubscriptions() {
        polling?.cancel(); polling = nil; stopWatch()
    }
    private func stopWatch() {
        watchGeneration &+= 1; watching?.cancel(); watching = nil; watchedID = nil
    }

    private func startWatch() {
        guard active, let rpc, let id = selectedID, watchedID != id, completedWatchID != id else { return }
        stopWatch(); watchedID = id
        let request = generation; let watch = watchGeneration; let after = sequence
        watching = Task { [weak self] in
            do {
                try await rpc.watchExecution(id: id, after: after) { [weak self] event in
                    await self?.receive(event, id: id, request: request, watch: watch)
                }
                guard let self, generation == request, watchGeneration == watch else { return }
                completedWatchID = id; watchedID = nil; watching = nil
            } catch {
                guard let self, generation == request, watchGeneration == watch, !Task.isCancelled else { return }
                self.error = DieterRPCFailure.message(for: error); watchedID = nil; watching = nil
            }
        }
    }

    private func receive(_ event: Dieter_V1_ExecutionEvent, id: String, request: Int, watch: Int) {
        guard generation == request, watchGeneration == watch, selectedID == id, active,
            event.execution.id == id, event.execution.cardID == target.conversationID,
            event.execution.projectID == target.projectID
        else { return }
        update(event.execution)
        guard !event.heartbeat else { return }
        if event.reset { stdout = Data(); stderr = Data(); outputTruncated = event.execution.outputTruncated }
        guard event.reset || event.sequence > sequence else { return }
        sequence = event.sequence
        switch event.stream {
        case .stdout, .pty: stdout.append(event.data)
        case .stderr: stderr.append(event.data)
        default: break
        }
        // Divide the fixed rendering budget between streams. Each preserves
        // its own byte sequence and UTF-8 across transport frame boundaries.
        let limit = Self.maximumOutputBytes / 2
        if stdout.count > limit { stdout.removeFirst(stdout.count - limit); outputTruncated = true }
        if stderr.count > limit { stderr.removeFirst(stderr.count - limit); outputTruncated = true }
        outputTruncated = outputTruncated || event.execution.outputTruncated
    }

    private func update(_ value: Dieter_V1_Execution) {
        guard value.cardID == target.conversationID, value.projectID == target.projectID,
            let index = processes.firstIndex(where: { $0.id == value.id }), value.sequence >= processes[index].sequence
        else { return }
        processes[index] = value
    }
}
