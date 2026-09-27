import DieterAPI
import DieterCore
import Foundation
import Observation

@MainActor @Observable final class FleetModel {
    var selectedMachineID: String?
    var machineInformation: [String: Dieter_V1_MachineInformation] = [:]
    var machineCPUHistory: [String: [Double]] = [:]
    var machineGPUHistory: [String: [String: [Double]]] = [:]
    var machineInformationLoading = false
    var machineInformationError: String?
    var machineOperationMessage: String?
    var machineOperationInFlight = false
    var machineTelemetryTask: Task<Void, Never>?
    var machineInformationGeneration: UInt64 = 0

    private var selectionGeneration: UInt64 = 0
    private var operationID: UUID?
    private let directory: () -> [DieterEndpoint]
    private let acquire: @MainActor (DieterEndpoint) async throws -> FeatureClientLease<any MachineTelemetryRPC>
    private let reportError: (Error) -> Void
    private let clock: ClientClock
    private var machines: [DieterEndpoint] { directory() }
    init(
        machines: @escaping () -> [DieterEndpoint],
        acquire: @escaping @MainActor (DieterEndpoint) async throws -> FeatureClientLease<any MachineTelemetryRPC>,
        reportError: @escaping (Error) -> Void, clock: ClientClock = .live
    ) {
        directory = machines; self.acquire = acquire; self.reportError = reportError; self.clock = clock
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
        stopMachineTelemetry()
        selectedMachineID = machine.id
        machineInformationError = nil
        let selection = selectionGeneration
        await refreshMachineInformation(machineID: machine.id)
        guard selection == selectionGeneration, selectedMachineID == machine.id else { return }
        startMachineTelemetry(machineID: machine.id)
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
        machineTelemetryTask?.cancel()
        machineTelemetryTask = Task { [weak self, clock] in
            while !Task.isCancelled {
                try? await clock.sleep(.seconds(2))
                guard let self, !Task.isCancelled, self.selectedMachineID == machineID else { return }
                await self.refreshMachineInformation(machineID: machineID)
            }
        }
    }

    func stopMachineTelemetry() {
        machineInformationGeneration &+= 1
        selectionGeneration &+= 1
        operationID = nil; machineOperationInFlight = false
        machineTelemetryTask?.cancel()
        machineTelemetryTask = nil
        machineInformationLoading = false
    }

    func refreshMachineInformation(machineID: String) async {
        guard selectedMachineID == machineID else { return }
        machineInformationGeneration &+= 1
        let generation = machineInformationGeneration
        guard
            let machine = machines.first(where: { $0.id == machineID })

        else {
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
        machineInformationLoading = machineInformation[machineID] == nil
        defer { if generation == machineInformationGeneration { machineInformationLoading = false } }

        var borrowedPlane: FeatureClientLease<any MachineTelemetryRPC>?
        do {
            let client: any MachineTelemetryRPC
            let plane = try await acquire(machine)
            borrowedPlane = plane
            client = plane.client
            defer {
                borrowedPlane?.release()
            }
            let information = try await client.machineInformation()
            guard selectedMachineID == machineID, generation == machineInformationGeneration else {
                return
            }
            machineInformation[machineID] = information
            var history = machineCPUHistory[machineID, default: []]
            history.append(information.cpuUsagePercent)
            if history.count > 12 { history.removeFirst(history.count - 12) }
            machineCPUHistory[machineID] = history
            var gpuHistory = machineGPUHistory[machineID, default: [:]]
            let liveGPUIds = Set(information.gpu.devices.map(\.id))
            gpuHistory = gpuHistory.filter { liveGPUIds.contains($0.key) }
            for gpu in information.gpu.devices where gpu.hasUtilizationPercent {
                var values = gpuHistory[gpu.id, default: []]
                values.append(gpu.utilizationPercent)
                if values.count > 12 { values.removeFirst(values.count - 12) }
                gpuHistory[gpu.id] = values
            }
            machineGPUHistory[machineID] = gpuHistory
            machineInformationError = nil
        } catch is CancellationError {
        } catch {
            guard selectedMachineID == machineID, generation == machineInformationGeneration else {
                return
            }
            machineInformationError = DieterRPCFailure.message(for: error)
        }
    }

    func performMachineOperation(
        _ action: Dieter_V1_MachineOperationAction,
        confirmation: String
    ) async {
        guard let machineID = selectedMachineID,
            let machine = machines.first(where: { $0.id == machineID })

        else { return }
        guard machine.online else {
            reportError(
                NSError(
                    domain: "DieterMachine", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "\(machine.name) is offline."]))
            return
        }
        guard !machineOperationInFlight else { return }
        let operation = UUID()
        operationID = operation
        machineOperationInFlight = true
        defer { if operationID == operation { machineOperationInFlight = false; operationID = nil } }
        guard machine.compatibilityState != .incompatible else {
            machineOperationMessage = machine.incompatibilityDescription
            return
        }
        var borrowedPlane: FeatureClientLease<any MachineTelemetryRPC>?
        do {
            let client: any MachineTelemetryRPC
            let plane = try await acquire(machine)
            borrowedPlane = plane
            client = plane.client
            defer {
                borrowedPlane?.release()
            }
            guard !Task.isCancelled, operationID == operation, selectedMachineID == machineID else {
                return
            }
            let response = try await client.performMachineOperation(action, confirmation: confirmation)
            guard !Task.isCancelled, operationID == operation, selectedMachineID == machineID else {
                return
            }
            machineOperationMessage = response.message
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled, operationID == operation, selectedMachineID == machineID else {
                return
            }
            reportError(error)
        }
    }

}
