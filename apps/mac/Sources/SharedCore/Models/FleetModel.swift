import DieterAPI
import Foundation
import Observation

/// A machine as the fleet addresses it: the ID views key it by, its daemon,
/// and how the core presents it (nil when the core does not list it).
package struct FleetMachine: Equatable, Sendable {
    package let id: String
    package let daemonID: String
    package let name: String
    package let entry: ClientMachineEntry?

    package init(id: String, daemonID: String, name: String, entry: ClientMachineEntry?) {
        self.id = id
        self.daemonID = daemonID
        self.name = name
        self.entry = entry
    }
}

/// The machine popover: the selected machine's live telemetry, which the
/// shared core reads every 2 s while shown, and its power and update
/// operations. Machines are keyed by their machine ID, as the views use them.
@MainActor @Observable package final class FleetModel {
    package var selectedMachineID: String?
    package var machineInformation: [String: Dieter_V1_MachineInformation] = [:]
    package var machineCPUHistory: [String: [Double]] = [:]
    package var machineGPUHistory: [String: [String: [Double]]] = [:]
    /// Each machine's actions menu: update, restart, and shut down, as its capabilities allow.
    package var machineOperations: [String: [ClientMachineOperationState]] = [:]
    package var machineInformationLoading = false
    package var machineInformationError: String?
    package var machineOperationMessage: String?
    /// An operation on the selected machine is on its way, as the core reports it.
    package private(set) var machineOperationInFlight = false

    private let directory: () -> [FleetMachine]
    private let core: CoreClient
    private let reportError: (Error) -> Void
    @ObservationIgnored private var subscription: SliceSubscription?
    @ObservationIgnored private var shownResult = ""
    /// Selections reach the core in the order they were made.
    @ObservationIgnored private var queued: Task<Void, Never>?
    private var machines: [FleetMachine] { directory() }

    /// `machines` lists the machines the views show, each with how the core
    /// presents it: whether it can take work, and why not.
    package init(
        machines: @escaping () -> [FleetMachine], core: CoreClient, reportError: @escaping (Error) -> Void
    ) {
        directory = machines
        self.core = core
        self.reportError = reportError
    }

    package func reset() {
        dismissMachinePopover()
        machineInformation = [:]; machineCPUHistory = [:]; machineGPUHistory = [:]; machineOperations = [:]
        machineOperationMessage = nil; machineOperationInFlight = false
    }

    /// Shows the machine `machineID`, or closes it when it is already shown.
    package func openMachine(_ machineID: String) async {
        if selectedMachineID == machineID {
            dismissMachinePopover()
            return
        }
        selectedMachineID = machineID
        machineInformationError = nil
        await refreshMachineInformation(machineID: machineID)
    }

    package func dismissMachinePopover() {
        stopMachineTelemetry()
        selectedMachineID = nil
        machineInformationError = nil
    }

    package func refreshSelectedMachineInformation() async {
        guard let selectedMachineID else { return }
        await refreshMachineInformation(machineID: selectedMachineID)
    }

    package func stopMachineTelemetry() {
        machineInformationLoading = false
        enqueue { $0.select = ClientTelemetrySelect() }
    }

    /// Shows the machine through the core, which reads it now and every 2 s.
    package func refreshMachineInformation(machineID: String) async {
        guard selectedMachineID == machineID else { return }
        guard let machine = machines.first(where: { $0.id == machineID }) else {
            machineInformationError = "This machine is no longer enrolled."
            return
        }
        if let reason = unavailableReason(machine) {
            machineInformationError = reason
            return
        }
        let daemonID = machine.daemonID
        guard !daemonID.isEmpty else { return }
        subscribe()
        machineInformationLoading = machineInformation[machineID] == nil
        enqueue {
            $0.select = .with {
                $0.daemonID = daemonID
                $0.active = true
            }
        }
        await queued?.value
    }

    /// Restarts, shuts down, or updates the selected machine; the core keeps
    /// one idempotency key per confirmed action.
    package func performMachineOperation(_ action: Dieter_V1_MachineOperationAction) async {
        guard let machineID = selectedMachineID, let machine = machines.first(where: { $0.id == machineID }) else {
            return
        }
        if let reason = unavailableReason(machine) {
            reportError(NSError(domain: "DieterMachine", code: 2, userInfo: [NSLocalizedDescriptionKey: reason]))
            return
        }
        guard !machineOperationInFlight else { return }
        subscribe()
        do {
            let result = try await core.dispatch(
                .with { $0.telemetry = .with { $0.perform = .with { $0.action = action } } })
            if case .machineOperation(let response)? = result.result, selectedMachineID == machineID {
                machineOperationMessage = response.message.isEmpty ? "Machine operation accepted." : response.message
            }
        } catch {
            guard selectedMachineID == machineID else { return }
            reportError(error)
        }
    }

    /// Why `machine` cannot take work now, as the core words it; nil when it can.
    private func unavailableReason(_ machine: FleetMachine) -> String? {
        guard let entry = machine.entry else { return "\(machine.name) is unavailable." }
        return entry.available ? nil : entry.unavailableMessage
    }

    private func subscribe() {
        guard subscription == nil else { return }
        subscription = SliceSubscription(client: core, slice: .telemetry, scope: "") { [weak self] update in
            guard let self, case .telemetry(let slice) = update.value else { return }
            self.fold(slice)
        }
    }

    private func fold(_ slice: ClientTelemetrySlice) {
        let machines = machines
        for (daemonID, readings) in slice.machines {
            guard let machineID = machines.first(where: { $0.daemonID == daemonID })?.id else { continue }
            if readings.hasInformation, machineInformation[machineID] != readings.information {
                machineInformation[machineID] = readings.information
            }
            if machineCPUHistory[machineID] != readings.cpuHistory {
                machineCPUHistory[machineID] = readings.cpuHistory
            }
            let gpu = readings.gpuHistory.mapValues(\.values)
            if machineGPUHistory[machineID] != gpu { machineGPUHistory[machineID] = gpu }
            if machineOperations[machineID] != readings.operations {
                machineOperations[machineID] = readings.operations
            }
            guard machineID == selectedMachineID else { continue }
            let loading = readings.loading && !readings.hasInformation
            if machineInformationLoading != loading { machineInformationLoading = loading }
            let error = readings.error.isEmpty ? nil : readings.error
            if machineInformationError != error { machineInformationError = error }
        }
        if machineOperationInFlight != slice.operationPending { machineOperationInFlight = slice.operationPending }
        if !slice.operationResult.isEmpty, slice.operationResult != shownResult {
            shownResult = slice.operationResult
            machineOperationMessage = slice.operationResult
        }
    }

    private func enqueue(_ build: (inout ClientTelemetryCommand) -> Void) {
        var command = ClientTelemetryCommand()
        build(&command)
        let sent = command, previous = queued, core = core
        queued = Task { [weak self] in
            await previous?.value
            do {
                _ = try await core.dispatch(.with { $0.telemetry = sent })
            } catch {
                self?.machineInformationError = (error as? CoreFailure)?.message ?? error.localizedDescription
            }
        }
    }
}
