import DieterAPI
import DieterCore
import Foundation
import Testing
@testable import DieterMac

private struct FleetFailure: Error {}

private actor ControlledMachine: MachineTelemetryRPC {
    var operations: [CheckedContinuation<Dieter_V1_MachineOperationResponse, Error>] = []
    var operationCount: Int { operations.count }
    func machineInformation() async throws -> Dieter_V1_MachineInformation { .init() }
    func performMachineOperation(_ action: Dieter_V1_MachineOperationAction, confirmation: String) async throws
        -> Dieter_V1_MachineOperationResponse
    {
        try await withCheckedThrowingContinuation { operations.append($0) }
    }
    func fail(_ index: Int) { operations[index].resume(throwing: FleetFailure()) }
}

@Test(.timeLimit(.minutes(1))) @MainActor func retiredFleetOperationCannotReportErrorOrClearSuccessor() async {
    let machine = DieterEndpoint(name: "Fixture", host: "127.0.0.1", port: 4242)
    let client = ControlledMachine()
    var errors = 0
    var returned = 0
    let fleet = FleetModel(
        machines: { [machine] },
        acquire: { _ in FeatureClientLease(client: client, release: { returned += 1 }) },
        reportError: { _ in errors += 1 })
    fleet.selectedMachineID = machine.id
    let old = Task { await fleet.performMachineOperation(.init(rawValue: 1)!, confirmation: "fixture") }
    while await client.operationCount < 1 { await Task.yield() }
    fleet.dismissMachinePopover()
    fleet.selectedMachineID = machine.id
    let current = Task { await fleet.performMachineOperation(.init(rawValue: 1)!, confirmation: "fixture") }
    while await client.operationCount < 2 { await Task.yield() }
    await fleet.refreshSelectedMachineInformation()
    await client.fail(0)
    await old.value
    #expect(errors == 0)
    #expect(fleet.machineOperationInFlight)
    await client.fail(1)
    await current.value
    #expect(errors == 1)
    #expect(!fleet.machineOperationInFlight)
    #expect(returned == 3)
}

@Test(.timeLimit(.minutes(1))) @MainActor func retiredFleetAcquisitionNeverStartsMachineOperation() async {
    let machine = DieterEndpoint(name: "Fixture", host: "127.0.0.1", port: 4242)
    let client = ControlledMachine()
    var acquisition: CheckedContinuation<Void, Never>?
    var returned = 0
    let fleet = FleetModel(
        machines: { [machine] },
        acquire: { _ in
            await withCheckedContinuation { acquisition = $0 }
            return FeatureClientLease(client: client, release: { returned += 1 })
        },
        reportError: { _ in Issue.record("Retired acquisition reported an error") })
    fleet.selectedMachineID = machine.id
    let old = Task { await fleet.performMachineOperation(.init(rawValue: 1)!, confirmation: "fixture") }
    while acquisition == nil { await Task.yield() }
    fleet.dismissMachinePopover()
    acquisition?.resume()
    await old.value
    #expect(await client.operationCount == 0)
    #expect(!fleet.machineOperationInFlight)
    #expect(returned == 1)
}
