import DieterAPI
import DieterCore
import Foundation
import GRPCCore
import Observation

@MainActor @Observable
final class TerminalsModel {
    private(set) var target = WorkspaceTarget(endpointID: "", projectID: "")
    var machineName = "Machine"
    var isLive = false
    var active = false { didSet { if !active { stopTerminalWatch() } } }
    var terminalScopeCardID: String?
    var terminals: [Dieter_V1_Terminal] = []
    var selectedTerminalID: String?
    var terminalScreens: [String: TerminalScreenState] = [:]
    var terminalLoading = false
    var terminalStreamConnected = false
    var terminalError: String?
    var errorMessage: String?
    var createTerminalPresented = false
    @ObservationIgnored var terminalRequestGeneration: UInt64 = 0
    @ObservationIgnored var terminalWatchTask: Task<Void, Never>?
    @ObservationIgnored var terminalSequences: [String: UInt64] = [:]
    @ObservationIgnored let terminalsRead = OwnedRead<Dieter_V1_TerminalsResponse>()
    @ObservationIgnored let terminalInputForwarder = TerminalInputForwarder()
    @ObservationIgnored var terminalOutputAccumulator = TerminalOutputAccumulator()
    @ObservationIgnored private var rpc: (any TerminalsRPC)?
    @ObservationIgnored private var bindingGeneration: UInt64 = 0
    @ObservationIgnored private var watchGeneration: UInt64 = 0
    @ObservationIgnored var onCreated: @MainActor () -> Void = {}

    var selectedTerminal: Dieter_V1_Terminal? { terminals.first { $0.id == selectedTerminalID } }

    func bind(target: WorkspaceTarget, client: (any TerminalsRPC)?) {
        guard self.target != target || rpc !== client else { return }
        let sameTarget = self.target == target
        bindingGeneration &+= 1; terminalRequestGeneration &+= 1
        stopTerminalWatch(); terminalsRead.cancel(); terminalInputForwarder.suspend()
        self.target = target; rpc = client
        terminalLoading = false; terminalError = nil; errorMessage = nil
        if !sameTarget {
            terminals = []; selectedTerminalID = nil; terminalScreens = [:]; terminalSequences = [:]
            terminalOutputAccumulator = TerminalOutputAccumulator()
        }
    }

    private func report(_ error: Error) {
        guard !DieterRPCFailure.isCancellation(error) else { return }
        errorMessage = DieterRPCFailure.message(for: error)
    }

    func loadTerminals() async {
        guard let rpc else { return }
        terminalRequestGeneration &+= 1
        let generation = terminalRequestGeneration
        let scope = terminalScopeCardID
        let projectID = scope == nil ? "" : target.projectID
        terminalLoading = true
        terminalError = nil
        defer { if generation == terminalRequestGeneration { terminalLoading = false } }
        do {
            let response = try await terminalsRead.value(key: "\(ObjectIdentifier(rpc)):\(projectID):\(scope ?? "")") {
                try await rpc.terminals(projectID: projectID, cardID: scope ?? "")
            }
            guard self.rpc === rpc, generation == terminalRequestGeneration,
                terminalScopeCardID == scope, scope == nil || target.projectID == projectID
            else { return }
            let values = response.terminals
            terminals = values
            let liveIDs = Set(values.map(\.id))
            terminalScreens = terminalScreens.filter { liveIDs.contains($0.key) }
            terminalSequences = terminalSequences.filter { liveIDs.contains($0.key) }
            await terminalOutputAccumulator.retain(terminalIDs: liveIDs)
            guard self.rpc === rpc, generation == terminalRequestGeneration else { return }
            if selectedTerminalID.flatMap({ id in values.first(where: { $0.id == id }) }) == nil {
                selectedTerminalID = values.first?.id
            }
            startTerminalWatch()
        } catch {
            guard self.rpc === rpc, generation == terminalRequestGeneration else { return }
            if !DieterRPCFailure.isCancellation(error) { terminalError = DieterRPCFailure.message(for: error) }
        }
    }

    func selectTerminal(_ id: String) {
        guard terminals.contains(where: { $0.id == id }) else { return }
        selectedTerminalID = id
        startTerminalWatch()
    }

    func createTerminal(projectID: String, name: String, shell: String, workingDirectory: String) async {
        guard let rpc else { return }
        var request = Dieter_V1_CreateTerminalRequest()
        request.projectID = projectID
        request.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        request.shell = shell
        request.workingDirectory = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        request.columns = 120
        request.rows = 36
        request.cardID = terminalScopeCardID ?? ""
        let binding = bindingGeneration
        do {
            let value = try await rpc.createTerminal(request)
            guard binding == bindingGeneration else { return }
            upsertTerminal(value)
            selectedTerminalID = value.id
            terminalSequences[value.id] = 0
            terminalScreens[value.id] = TerminalScreenState()
            await terminalOutputAccumulator.seed(terminalID: value.id)
            guard binding == bindingGeneration else { return }
            createTerminalPresented = false
            onCreated()
            startTerminalWatch()
        } catch {
            if binding == bindingGeneration { report(error) }
        }
    }

    func sendTerminalInput(id: String, data: Data) {
        guard let rpc,
            !data.isEmpty,
            terminals.first(where: { $0.id == id })?.status == "running"
        else { return }
        terminalInputForwarder.enqueue(endpointID: target.endpointID, id: id, data: data, rpc: rpc) {
            [weak self] message in
            guard let self, self.rpc === rpc, self.terminals.contains(where: { $0.id == id }) else { return }
            self.errorMessage = "Terminal input could not be forwarded: \(message)"
        }
    }

    func resizeTerminal(id: String, columns: Int, rows: Int) async {
        guard let rpc,
            columns >= 2, rows >= 2,
            terminals.first(where: { $0.id == id })?.status == "running"
        else { return }
        let binding = bindingGeneration
        do {
            let value = try await rpc.resizeTerminal(id: id, columns: columns, rows: rows)
            guard binding == bindingGeneration, self.rpc === rpc, terminals.contains(where: { $0.id == id }) else {
                return
            }
            upsertTerminal(value)
        } catch  where DieterRPCFailure.isCancellation(error) {} catch {
            guard binding == bindingGeneration, terminals.contains(where: { $0.id == id }) else { return }
            report(error)
        }
    }

    func renameTerminal(id: String, name: String) async {
        guard let rpc else { return }
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        let binding = bindingGeneration
        do {
            let updated = try await rpc.renameTerminal(id: id, name: value)
            guard binding == bindingGeneration, self.rpc === rpc, terminals.contains(where: { $0.id == id }) else {
                return
            }
            upsertTerminal(updated)
        } catch { if binding == bindingGeneration { report(error) } }
    }

    func closeTerminal(id: String) async {
        guard let rpc else { return }
        let binding = bindingGeneration
        do {
            try await rpc.closeTerminal(id: id)
            guard binding == bindingGeneration, self.rpc === rpc else { return }
            terminals.removeAll { $0.id == id }
            terminalScreens.removeValue(forKey: id)
            terminalSequences.removeValue(forKey: id)
            await terminalOutputAccumulator.remove(terminalID: id)
            guard binding == bindingGeneration, self.rpc === rpc else { return }
            if selectedTerminalID == id {
                selectedTerminalID = terminals.first?.id
                startTerminalWatch()
            }
        } catch { if binding == bindingGeneration { report(error) } }
    }

    func startTerminalWatch() {
        stopTerminalWatch()
        let binding = bindingGeneration
        let watcher = watchGeneration
        guard active,
            let id = selectedTerminalID,
            terminals.contains(where: { $0.id == id }),
            let rpc
        else { return }
        let after = terminalSequences[id] ?? 0
        terminalWatchTask = Task { [weak self] in
            guard let self else { return }
            var delay = 0.5
            while !Task.isCancelled, self.bindingGeneration == binding, self.watchGeneration == watcher,
                self.rpc === rpc, self.selectedTerminalID == id
            {
                do {
                    self.terminalStreamConnected = true
                    try await rpc.watchTerminal(id: id, after: self.terminalSequences[id] ?? after) {
                        [weak self] frame in
                        await self?.acceptTerminalFrame(frame, terminalID: id, binding: binding, watcher: watcher)
                    }
                    guard !Task.isCancelled, self.bindingGeneration == binding, self.watchGeneration == watcher else {
                        return
                    }
                    self.terminalStreamConnected = false
                } catch  where DieterRPCFailure.isCancellation(error) {
                    return
                } catch {
                    guard self.bindingGeneration == binding, self.watchGeneration == watcher else { return }
                    self.terminalStreamConnected = false
                    if let rpcError = error as? RPCError, rpcError.code == .notFound {
                        self.terminals.removeAll { $0.id == id }
                        self.selectedTerminalID = self.terminals.first?.id
                        return
                    }
                }
                try? await DieterTaskSleep.seconds(delay)
                delay = min(5, delay * 1.8)
            }
        }
    }

    func acceptTerminalFrame(
        _ frame: Dieter_V1_TerminalFrame, terminalID: String, binding: UInt64? = nil, watcher: UInt64? = nil
    ) async {
        guard binding == nil || binding == bindingGeneration, watcher == nil || watcher == watchGeneration else {
            return
        }
        let currentBinding = bindingGeneration
        guard frame.hasTerminal, frame.terminal.id == terminalID else { return }
        upsertTerminal(frame.terminal)
        if !terminalStreamConnected { terminalStreamConnected = true }
        terminalSequences[terminalID] = max(terminalSequences[terminalID] ?? 0, frame.sequence)
        guard frame.screenReset || !frame.data.isEmpty else { return }
        await terminalOutputAccumulator.enqueue(
            terminalID: terminalID,
            data: frame.data,
            screenReset: frame.screenReset,
            current: terminalScreens[terminalID] ?? TerminalScreenState()
        ) { [weak self] id, screen in
            guard let self, self.bindingGeneration == currentBinding, self.terminals.contains(where: { $0.id == id })
            else { return }
            self.terminalScreens[id] = screen
        }
    }

    func upsertTerminal(_ value: Dieter_V1_Terminal) {
        if let index = terminals.firstIndex(where: { $0.id == value.id }) {
            guard terminals[index] != value else { return }
            terminals[index] = value
        } else {
            terminals.append(value)
        }
        terminals.sort {
            if $0.createdAt == $1.createdAt { return $0.id < $1.id }
            return $0.createdAt < $1.createdAt
        }
    }

    func stopTerminalWatch() {
        watchGeneration &+= 1
        terminalWatchTask?.cancel()
        terminalWatchTask = nil
        terminalStreamConnected = false
    }

}
