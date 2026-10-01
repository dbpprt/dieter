import DieterAPI
import DieterCore
import Foundation
import Observation
import SharedCore

/// The machine popover: the selected machine's live telemetry, which the
/// shared core reads every 2 s while shown, and its power and update
/// operations. Machines are keyed by their machine ID, as the views use them.
@MainActor @Observable final class FleetModel {
    var selectedMachineID: String?
    var machineInformation: [String: Dieter_V1_MachineInformation] = [:]
    var machineCPUHistory: [String: [Double]] = [:]
    var machineGPUHistory: [String: [String: [Double]]] = [:]
    var machineInformationLoading = false
    var machineInformationError: String?
    var machineOperationMessage: String?
    var machineOperationInFlight = false

    private let directory: () -> [DieterEndpoint]
    private let core: CoreClient
    private let reportError: (Error) -> Void
    @ObservationIgnored private var subscription: SliceSubscription?
    @ObservationIgnored private var shownResult = ""
    /// Selections reach the core in the order they were made.
    @ObservationIgnored private var queued: Task<Void, Never>?
    private var machines: [DieterEndpoint] { directory() }

    init(machines: @escaping () -> [DieterEndpoint], core: CoreClient, reportError: @escaping (Error) -> Void) {
        directory = machines
        self.core = core
        self.reportError = reportError
    }

    func reset() {
        dismissMachinePopover()
        machineInformation = [:]; machineCPUHistory = [:]; machineGPUHistory = [:]
        machineOperationMessage = nil; machineOperationInFlight = false
    }

    func openMachine(_ machine: DieterEndpoint) async {
        if selectedMachineID == machine.id {
            dismissMachinePopover()
            return
        }
        selectedMachineID = machine.id
        machineInformationError = nil
        await refreshMachineInformation(machineID: machine.id)
    }

    func dismissMachinePopover() {
        stopMachineTelemetry()
        selectedMachineID = nil
        machineInformationError = nil
    }

    func refreshSelectedMachineInformation() async {
        guard let selectedMachineID else { return }
        await refreshMachineInformation(machineID: selectedMachineID)
    }

    func startMachineTelemetry(machineID: String) {
        Task { await refreshMachineInformation(machineID: machineID) }
    }

    func stopMachineTelemetry() {
        machineInformationLoading = false
        enqueue { $0.select = ClientTelemetrySelect() }
    }

    /// Shows the machine through the core, which reads it now and every 2 s.
    func refreshMachineInformation(machineID: String) async {
        guard selectedMachineID == machineID else { return }
        guard let machine = machines.first(where: { $0.id == machineID }) else {
            machineInformationError = "This machine is no longer enrolled."
            return
        }
        guard machine.online else {
            machineInformationError = "\(machine.name) is offline."
            return
        }
        guard machine.compatibilityState != .incompatible else {
            machineInformationError = machine.incompatibilityDescription
            return
        }
        guard let daemonID = machine.daemonID else { return }
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
    func performMachineOperation(_ action: Dieter_V1_MachineOperationAction, confirmation: String) async {
        guard let machineID = selectedMachineID, let machine = machines.first(where: { $0.id == machineID }) else {
            return
        }
        guard machine.online else {
            reportError(
                NSError(
                    domain: "DieterMachine", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "\(machine.name) is offline."]))
            return
        }
        guard machine.compatibilityState != .incompatible else {
            machineOperationMessage = machine.incompatibilityDescription
            return
        }
        guard !machineOperationInFlight else { return }
        machineOperationInFlight = true
        defer { machineOperationInFlight = false }
        do {
            let result = try await core.dispatch(.with { $0.telemetry = .with { $0.perform = .with { $0.action = action } } })
            if case .machineOperation(let response)? = result.result, selectedMachineID == machineID {
                machineOperationMessage = response.message.isEmpty ? "Machine operation accepted." : response.message
            }
        } catch {
            guard selectedMachineID == machineID else { return }
            reportError(error)
        }
    }

    private func subscribe() {
        guard subscription == nil else { return }
        subscription = SliceSubscription(client: core, slice: .telemetry, scope: "") { [weak self] update in
            guard let self, case .telemetry(let slice) = update.value else { return }
            self.fold(slice)
        }
    }

    private func fold(_ slice: ClientTelemetrySlice) {
        for (daemonID, readings) in slice.machines {
            guard let machineID = machines.first(where: { $0.daemonID == daemonID })?.id else { continue }
            if readings.hasInformation, machineInformation[machineID] != readings.information {
                machineInformation[machineID] = readings.information
            }
            if machineCPUHistory[machineID] != readings.cpuHistory { machineCPUHistory[machineID] = readings.cpuHistory }
            let gpu = readings.gpuHistory.mapValues(\.values)
            if machineGPUHistory[machineID] != gpu { machineGPUHistory[machineID] = gpu }
            guard machineID == selectedMachineID else { continue }
            let loading = readings.loading && !readings.hasInformation
            if machineInformationLoading != loading { machineInformationLoading = loading }
            let error = readings.error.isEmpty ? nil : readings.error
            if machineInformationError != error { machineInformationError = error }
        }
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
