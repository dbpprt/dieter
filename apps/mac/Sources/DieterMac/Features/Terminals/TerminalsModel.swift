import DieterAPI
import DieterCore
import Foundation
import Observation
import SharedCore

/// One terminal in the account-wide overview.
struct TerminalOverviewEntry: Identifiable, Equatable, Sendable {
    let machineID: String
    let machineName: String
    var terminal: Dieter_V1_Terminal

    var id: String { Self.id(machineID: machineID, terminalID: terminal.id) }

    static func id(machineID: String, terminalID: String) -> String {
        "\(machineID)|\(terminalID)"
    }
}

/// The terminals of a machine, project, or conversation, kept by the shared
/// core on the machine that runs them. Only the selected terminal of an
/// active surface streams; hiding it never stops a shell. SwiftTerm is fed
/// from the output the core sends, paced by the output accumulator.
@MainActor @Observable
final class TerminalsModel {
    private(set) var target = WorkspaceTarget(endpointID: "", projectID: "")
    var machineName = "Machine"
    var isLive = false
    var active = false {
        didSet {
            guard active != oldValue else { return }
            let on = active
            send { $0.active = .with { $0.on = on } }
        }
    }
    var terminalScopeCardID: String?
    var terminals: [Dieter_V1_Terminal] = []
    var selectedTerminalID: String?
    var terminalScreens: [String: TerminalScreenState] = [:]
    var terminalLoading = false
    var terminalStreamConnected = false
    var terminalError: String?
    var errorMessage: String?
    var createTerminalPresented = false
    @ObservationIgnored var terminalOutputAccumulator = TerminalOutputAccumulator()
    @ObservationIgnored var onCreated: @MainActor () -> Void = {}
    @ObservationIgnored private var core: CoreClient?
    @ObservationIgnored private let ownScope = "terminals-\(UUID().uuidString)"
    /// The surface commands address: this model's own, or an overview's.
    @ObservationIgnored private var scope = ""
    @ObservationIgnored private var subscription: SliceSubscription?
    /// What the own surface was last told to show; its slices for another are stale.
    @ObservationIgnored private var bound = ClientTerminalTarget()
    /// The latest command sent without waiting; later commands wait for it,
    /// so input and binds reach the core in order.
    @ObservationIgnored private var queued: Task<Void, Never>?
    @ObservationIgnored private var pendingOutput: [ClientTerminalOutput] = []
    @ObservationIgnored private var draining: Task<Void, Never>?
    @ObservationIgnored private var outputGeneration: UInt64 = 0

    var selectedTerminal: Dieter_V1_Terminal? { terminals.first { $0.id == selectedTerminalID } }

    /// Shows `target`'s terminals through a surface of this model's own: the
    /// conversation's when it names one, else the project's or the machine's.
    func bind(target: WorkspaceTarget, core: CoreClient?) {
        let following = scope != ownScope
        if subscription == nil, let core {
            self.core = core
            subscription = SliceSubscription(client: core, slice: .terminals, scope: ownScope) { [weak self] update in
                guard let self, case .terminals(let slice) = update.value else { return }
                self.fold(slice)
            }
        }
        scope = ownScope
        guard following || self.target != target else { return }
        self.target = target
        reset()
        bound = ClientTerminalTarget.with {
            $0.daemonID = target.daemonID
            $0.kind =
                !target.conversationID.isEmpty ? .card : target.projectID.isEmpty ? .machine : .project
            $0.projectID = target.projectID
            $0.checkoutID = target.checkoutID
            $0.cardID = target.conversationID
        }
        let bind = bound, on = active
        send { $0.bind = bind }
        send { $0.active = .with { $0.on = on } }
    }

    /// Shows the overview's selected machine: the overview folds its slices
    /// here, and commands address the overview's surface.
    func follow(overviewScope: String, core: CoreClient) {
        subscription?.close()
        subscription = nil
        self.core = core
        if scope != overviewScope {
            scope = overviewScope
            bound = ClientTerminalTarget()
            reset()
        }
        // A reopened overview starts inactive.
        let on = active
        send { $0.active = .with { $0.on = on } }
    }

    private func reset() {
        terminals = []; selectedTerminalID = nil; terminalScreens = [:]
        terminalLoading = false; terminalError = nil; errorMessage = nil; terminalStreamConnected = false
        outputGeneration &+= 1
        pendingOutput = []; draining = nil
        terminalOutputAccumulator = TerminalOutputAccumulator()
    }

    /// Folds a surface. The overview passes the machine it shows; the own
    /// surface ignores slices for a previous target.
    func fold(_ slice: ClientTerminalsSlice, target shown: WorkspaceTarget? = nil) {
        if let shown {
            if target != shown {
                target = shown
                terminalScreens = [:]
                outputGeneration &+= 1
                pendingOutput = []; draining = nil
                terminalOutputAccumulator = TerminalOutputAccumulator()
            }
        } else {
            guard slice.target == bound else { return }
        }
        if terminals != slice.terminals { terminals = slice.terminals }
        let selected = slice.selectedID.isEmpty ? nil : slice.selectedID
        if selectedTerminalID != selected { selectedTerminalID = selected }
        if terminalLoading != slice.loading { terminalLoading = slice.loading }
        let error = slice.error.isEmpty ? nil : slice.error
        if terminalError != error { terminalError = error }
        if terminalStreamConnected != slice.streamConnected { terminalStreamConnected = slice.streamConnected }
        let live = Set(slice.terminals.map(\.id))
        if terminalScreens.keys.contains(where: { !live.contains($0) }) {
            terminalScreens = terminalScreens.filter { live.contains($0.key) }
        }
        enqueue(slice.output)
    }

    /// Applies output in the order it arrived; the accumulator paces redraws.
    private func enqueue(_ output: [ClientTerminalOutput]) {
        guard !output.isEmpty else { return }
        pendingOutput.append(contentsOf: output)
        guard draining == nil else { return }
        let generation = outputGeneration, accumulator = terminalOutputAccumulator
        draining = Task { [weak self] in
            while let self, generation == self.outputGeneration, !self.pendingOutput.isEmpty {
                let next = self.pendingOutput.removeFirst()
                await accumulator.enqueue(
                    terminalID: next.terminalID, data: next.data, screenReset: next.reset,
                    current: self.terminalScreens[next.terminalID] ?? TerminalScreenState()
                ) { [weak self] id, screen in
                    guard let self, generation == self.outputGeneration else { return }
                    self.terminalScreens[id] = screen
                }
            }
            if let self, generation == self.outputGeneration { self.draining = nil }
        }
    }

    /// Sends a command without waiting for it, after those sent before.
    private func send(_ build: @escaping (inout ClientTerminalsCommand) -> Void) {
        guard core != nil, !scope.isEmpty else { return }
        let previous = queued
        queued = Task { [weak self] in
            await previous?.value
            await self?.run(afterQueued: false, build)
        }
    }

    /// Runs a command; the own surface folds the result so callers read its
    /// effect. A failure shows as the error message.
    @discardableResult
    private func run(
        afterQueued: Bool = true, _ build: (inout ClientTerminalsCommand) -> Void
    ) async -> ClientResult? {
        guard let core, !scope.isEmpty else { return nil }
        if afterQueued, let queued { await queued.value }
        var command = ClientTerminalsCommand()
        command.scope = scope
        build(&command)
        let sent = command
        do {
            let result = try await core.dispatch(.with { $0.terminals = sent })
            if case .terminals(let slice)? = result.result, sent.scope == ownScope, scope == ownScope { fold(slice) }
            return result
        } catch let failure as CoreFailure {
            if sent.scope == scope { errorMessage = failure.message }
            return nil
        } catch {
            return nil
        }
    }

    func loadTerminals(selecting preferredID: String? = nil) async {
        await run { $0.load = ClientTerminalStep() }
        if let preferredID { await run { $0.select = .with { $0.terminalID = preferredID } } }
    }

    func selectTerminal(_ id: String) {
        guard terminals.contains(where: { $0.id == id }) else { return }
        selectedTerminalID = id
        send { $0.select = .with { $0.terminalID = id } }
    }

    /// Creates a terminal in this surface and selects it.
    func createTerminal(name: String, shell: String, workingDirectory: String) async {
        let result = await run { command in
            command.create = .with {
                $0.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                $0.shell = shell
                $0.workingDirectory = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
                $0.columns = 120
                $0.rows = 36
            }
        }
        guard case .terminal(let created)? = result?.result else { return }
        if !terminals.contains(where: { $0.id == created.id }) { terminals.append(created) }
        selectedTerminalID = created.id
        createTerminalPresented = false
        onCreated()
    }

    /// Input for the selected, running terminal, delivered in order.
    func sendTerminalInput(id: String, data: Data) {
        guard !data.isEmpty, id == selectedTerminalID, selectedTerminal?.status == "running" else { return }
        send { $0.input = .with { $0.data = data } }
    }

    /// The visible grid of the selected terminal; the machine resizes shortly after the last change.
    func resizeTerminal(id: String, columns: Int, rows: Int) async {
        guard id == selectedTerminalID, columns >= 2, rows >= 2, selectedTerminal?.status == "running" else { return }
        send {
            $0.grid = .with {
                $0.columns = Int32(columns); $0.rows = Int32(rows)
            }
        }
    }

    func renameTerminal(id: String, name: String) async {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        await run { command in
            command.rename = .with {
                $0.terminalID = id; $0.name = value
            }
        }
    }

    /// Ends the shell and forgets its scrollback.
    func closeTerminal(id: String) async {
        await run { command in command.close = .with { $0.terminalID = id } }
    }
}
