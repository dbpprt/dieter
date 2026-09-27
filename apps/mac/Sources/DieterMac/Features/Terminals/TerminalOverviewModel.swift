import DieterAPI
import DieterCore
import Foundation
import Observation

private struct TerminalOverviewMachineResult: Sendable {
    let machineID: String
    let entries: [TerminalOverviewEntry]
    let error: String?
}

@MainActor @Observable final class TerminalOverviewModel {
    var terminalOverviewEntries: [TerminalOverviewEntry] = []
    var selectedTerminalOverviewID: String?
    var terminalOverviewLoading = false
    var terminalOverviewError: String?
    var terminalOverviewPreferredMachineID: String?
    @ObservationIgnored var terminalOverviewGeneration: UInt64 = 0
    @ObservationIgnored var terminalOverviewLease: FeatureClientLease<any TerminalsRPC>?

    private let terminalsModel: TerminalsModel
    private let machines: () -> [DieterEndpoint]
    private let machineIsAvailable: (DieterEndpoint) -> Bool
    private let isOverviewActive: () -> Bool
    private let acquire: @MainActor (DieterEndpoint) async throws -> FeatureClientLease<any TerminalsRPC>
    private let reportError: (Error) -> Void
    private var terminalOverviewMachines: [DieterEndpoint] { machines() }

    init(
        terminalsModel: TerminalsModel, machines: @escaping () -> [DieterEndpoint],
        available: @escaping (DieterEndpoint) -> Bool, active: @escaping () -> Bool,
        acquire: @escaping @MainActor (DieterEndpoint) async throws -> FeatureClientLease<any TerminalsRPC>,
        reportError: @escaping (Error) -> Void
    ) {
        self.terminalsModel = terminalsModel; self.machines = machines
        machineIsAvailable = available; isOverviewActive = active
        self.acquire = acquire; self.reportError = reportError
    }
    func stop() {
        terminalOverviewGeneration &+= 1
        terminalOverviewLoading = false
        terminalOverviewLease?.release()
        terminalOverviewLease = nil
    }
    func reset() { stop(); terminalOverviewEntries = []; selectedTerminalOverviewID = nil; terminalOverviewError = nil }

    func loadTerminalOverview(preferredMachineID: String? = nil) async {
        terminalOverviewGeneration &+= 1
        let generation = terminalOverviewGeneration
        terminalOverviewLoading = terminalOverviewEntries.isEmpty
        terminalOverviewError = nil
        defer {
            if generation == terminalOverviewGeneration { terminalOverviewLoading = false }
        }

        let candidates = terminalOverviewMachines.filter(machineIsAvailable)
        guard !candidates.isEmpty else {
            terminalOverviewLease?.release(); terminalOverviewLease = nil
            terminalOverviewEntries = []
            selectedTerminalOverviewID = nil
            terminalOverviewError = "No compatible Dieter machines are online."
            terminalsModel.stopTerminalWatch()
            terminalsModel.installTerminals([], selectedID: nil)
            return
        }

        var results: [TerminalOverviewMachineResult] = []
        for machine in candidates {
            let result = await fetchTerminalOverview(on: machine)
            guard !Task.isCancelled, generation == terminalOverviewGeneration else { return }
            results.append(result)
            // Publish successful routes progressively so one slow machine does
            // not hold the complete overview in its empty loading state.
            terminalOverviewEntries = TerminalOverviewCatalog.sorted(results.flatMap(\.entries))
        }
        guard !Task.isCancelled, generation == terminalOverviewGeneration else { return }

        terminalOverviewEntries = TerminalOverviewCatalog.sorted(results.flatMap(\.entries))
        let failures = results.compactMap { result in result.error.map { "\(result.machineID): \($0)" } }
        terminalOverviewError = failures.isEmpty ? nil : failures.joined(separator: "\n")
        guard
            let selected = TerminalOverviewCatalog.selection(
                in: terminalOverviewEntries, currentID: selectedTerminalOverviewID,
                preferredMachineID: preferredMachineID)
        else {
            selectedTerminalOverviewID = nil
            terminalOverviewLease?.release()
            terminalOverviewLease = nil
            terminalsModel.stopTerminalWatch()
            terminalsModel.installTerminals([], selectedID: nil)
            return
        }
        await activateTerminalOverviewEntry(selected, generation: generation)
    }

    func selectTerminalOverviewEntry(_ id: String) async {
        guard isOverviewActive(),
            let entry = terminalOverviewEntries.first(where: { $0.id == id })
        else { return }
        terminalOverviewGeneration &+= 1
        await activateTerminalOverviewEntry(entry, generation: terminalOverviewGeneration)
    }

    private func fetchTerminalOverview(on machine: DieterEndpoint) async -> TerminalOverviewMachineResult {
        var lease: FeatureClientLease<any TerminalsRPC>?
        do {
            let client: any TerminalsRPC
            let borrowed = try await acquire(machine)
            lease = borrowed
            client = borrowed.client
            defer { lease?.release() }
            let values = try await client.terminals(projectID: "", cardID: "").terminals
            return TerminalOverviewMachineResult(
                machineID: machine.id,
                entries: values.map {
                    TerminalOverviewEntry(machineID: machine.id, machineName: machine.name, terminal: $0)
                }, error: nil)
        } catch is CancellationError {
            return TerminalOverviewMachineResult(machineID: machine.id, entries: [], error: nil)
        } catch {
            return TerminalOverviewMachineResult(
                machineID: machine.id, entries: [], error: DieterRPCFailure.message(for: error))
        }
    }

    private func activateTerminalOverviewEntry(_ entry: TerminalOverviewEntry, generation: UInt64) async {
        guard isOverviewActive(),
            let machine = terminalOverviewMachines.first(where: { $0.id == entry.machineID })
        else { return }
        terminalsModel.stopTerminalWatch()
        terminalOverviewLease?.release()
        terminalOverviewLease = nil
        do {
            let client: any TerminalsRPC
            var lease: FeatureClientLease<any TerminalsRPC>?
            let borrowed = try await acquire(machine)
            lease = borrowed
            client = borrowed.client
            guard !Task.isCancelled, generation == terminalOverviewGeneration, isOverviewActive() else {
                lease?.release()
                return
            }
            terminalOverviewLease = lease
            selectedTerminalOverviewID = entry.id
            terminalsModel.bind(
                target: WorkspaceTarget(endpointID: machine.id, projectID: ""), client: client)
            terminalsModel.machineName = machine.name
            terminalsModel.isLive = true
            terminalsModel.active = true
            terminalsModel.installTerminals(
                terminalOverviewEntries.filter { $0.machineID == machine.id }.map(\.terminal),
                selectedID: entry.terminal.id)
        } catch {
            guard !Task.isCancelled, generation == terminalOverviewGeneration else { return }
            terminalOverviewError = DieterRPCFailure.message(for: error)
            terminalsModel.isLive = false
        }
    }

    func createOverviewTerminal(
        projectID: String, checkoutID: String, machineID: String?, machineHome: Bool,
        name: String, shell: String, workingDirectory: String
    ) async {
        let destination = machineID.flatMap { id in terminalOverviewMachines.first(where: { $0.id == id }) }
        guard let machine = destination, machineIsAvailable(machine) else {
            reportError(
                NSError(
                    domain: "DieterTerminal", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "The selected machine is unavailable."]))
            return
        }
        let generation = terminalOverviewGeneration
        var lease: FeatureClientLease<any TerminalsRPC>?
        do {
            let client: any TerminalsRPC
            let borrowed = try await acquire(machine)
            lease = borrowed
            client = borrowed.client
            defer { lease?.release() }
            guard !Task.isCancelled, generation == terminalOverviewGeneration, isOverviewActive() else { return }
            var request = Dieter_V1_CreateTerminalRequest()
            request.projectID = projectID
            request.checkoutID = machineHome ? "" : checkoutID
            request.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            request.shell = shell
            request.workingDirectory = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            request.columns = 120
            request.rows = 36
            request.machineHome = machineHome
            let terminal = try await client.createTerminal(request)
            guard !Task.isCancelled, generation == terminalOverviewGeneration, isOverviewActive() else { return }
            let entry = TerminalOverviewEntry(machineID: machine.id, machineName: machine.name, terminal: terminal)
            terminalOverviewEntries.removeAll { $0.id == entry.id }
            terminalOverviewEntries.append(entry)
            terminalOverviewEntries = TerminalOverviewCatalog.sorted(terminalOverviewEntries)
            selectedTerminalOverviewID = entry.id
            terminalsModel.createTerminalPresented = false
            terminalOverviewGeneration &+= 1
            await activateTerminalOverviewEntry(entry, generation: terminalOverviewGeneration)
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled, generation == terminalOverviewGeneration, isOverviewActive() else { return }
            reportError(error)
        }
    }

    func updateTerminalOverviewEntry(
        machineID: String, terminalID: String, terminal: Dieter_V1_Terminal?
    ) {
        guard isOverviewActive() else { return }
        let id = TerminalOverviewEntry.id(machineID: machineID, terminalID: terminalID)
        if let terminal,
            let machine = terminalOverviewMachines.first(where: { $0.id == machineID })
        {
            let entry = TerminalOverviewEntry(machineID: machineID, machineName: machine.name, terminal: terminal)
            if let index = terminalOverviewEntries.firstIndex(where: { $0.id == id }) {
                terminalOverviewEntries[index] = entry
            } else {
                terminalOverviewEntries.append(entry)
            }
            terminalOverviewEntries = TerminalOverviewCatalog.sorted(terminalOverviewEntries)
        } else {
            terminalOverviewEntries.removeAll { $0.id == id }
            if selectedTerminalOverviewID == id {
                selectedTerminalOverviewID = nil
                if let next = terminalOverviewEntries.first {
                    Task { await selectTerminalOverviewEntry(next.id) }
                }
            }
        }
    }

}
