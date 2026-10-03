import DieterAPI
import Foundation
import Observation
import SharedCore

/// The background processes an agent started for one conversation, kept by
/// the shared core on the machine that runs them. While active, the core
/// refreshes the list and streams the selected process's output; hiding the
/// view never stops a process.
@MainActor @Observable
final class ConversationProcessesModel {
    private(set) var target = WorkspaceTarget(endpointID: "", projectID: "")
    private(set) var processes: [Dieter_V1_Execution] = []
    private(set) var selectedID: String?
    private(set) var stdout = Data()
    private(set) var stderr = Data()
    private(set) var outputTruncated = false
    private(set) var loading = false
    private(set) var stopping = false
    /// How many processes run, and whether the core's selection can be stopped now.
    private(set) var running = 0
    private(set) var canStop = false
    private(set) var error: String?
    var active = false {
        didSet {
            guard active != oldValue else { return }
            sendTarget()
        }
    }
    @ObservationIgnored private var core: CoreClient?
    @ObservationIgnored private let scope = "processes-\(UUID().uuidString)"
    @ObservationIgnored private var subscription: SliceSubscription?
    @ObservationIgnored private var queued: Task<Void, Never>?

    var selected: Dieter_V1_Execution? { processes.first { $0.id == selectedID } }
    var connected: Bool { core != nil }

    /// Shows `target`'s processes on the machine that runs the conversation.
    func bind(target: WorkspaceTarget, core: CoreClient?) {
        if subscription == nil, let core {
            self.core = core
            subscription = SliceSubscription(client: core, slice: .processes, scope: scope) { [weak self] update in
                guard let self, case .processes(let slice) = update.value else { return }
                self.fold(slice)
            }
        }
        guard self.target != target else { return }
        self.target = target
        processes = []; selectedID = nil; stdout = Data(); stderr = Data(); outputTruncated = false
        loading = false; stopping = false; running = 0; canStop = false; error = nil
        sendTarget()
    }

    private func sendTarget() {
        let target = target, active = active
        send {
            $0.bind = .with {
                $0.daemonID = target.daemonID
                $0.projectID = target.projectID
                $0.cardID = target.conversationID
                $0.active = active
            }
        }
    }

    private func fold(_ slice: ClientProcessesSlice) {
        guard slice.cardID == target.conversationID, slice.projectID == target.projectID,
            slice.daemonID == target.daemonID
        else { return }
        if processes != slice.processes { processes = slice.processes }
        let selected = slice.selectedID.isEmpty ? nil : slice.selectedID
        if selectedID != selected { selectedID = selected }
        if stdout != slice.stdout { stdout = slice.stdout }
        if stderr != slice.stderr { stderr = slice.stderr }
        if outputTruncated != slice.outputTruncated { outputTruncated = slice.outputTruncated }
        if loading != slice.loading { loading = slice.loading }
        if stopping != slice.stopping { stopping = slice.stopping }
        if running != Int(slice.running) { running = Int(slice.running) }
        if canStop != slice.canStop { canStop = slice.canStop }
        let failure = slice.error.isEmpty ? nil : slice.error
        if error != failure { error = failure }
    }

    /// Sends a command after those sent before, folding the processes it returns.
    private func send(_ build: @escaping (inout ClientProcessesCommand) -> Void) {
        guard let core else { return }
        let previous = queued, scope = scope
        queued = Task { [weak self] in
            await previous?.value
            var command = ClientProcessesCommand()
            command.scope = scope
            build(&command)
            let sent = command
            do {
                let result = try await core.dispatch(.with { $0.processes = sent })
                if case .processes(let slice)? = result.result { self?.fold(slice) }
            } catch {
                self?.error = (error as? CoreFailure)?.message ?? error.localizedDescription
            }
        }
    }

    /// Reads the list now; an active view also refreshes every 2 s.
    func refresh() async {
        sendTarget()
        await queued?.value
    }

    func select(_ id: String?) {
        guard let id, processes.contains(where: { $0.id == id }) else { return }
        selectedID = id
        send { $0.select = .with { $0.executionID = id } }
    }

    /// Stops the selected process; only an explicit stop ever ends one.
    func stopSelected() async {
        guard active, !stopping, selected?.status == "running" else { return }
        send { $0.stop = ClientStep() }
        await queued?.value
    }
}
