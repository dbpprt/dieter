import DieterAPI
import Foundation
import SharedCore
import Testing
@testable import DieterMac

private let fixture = MachineEndpoint(name: "Fixture", host: "127.0.0.1", port: 4242, daemonID: "d_fixture")

/// A fixture machine as the fleet addresses it: available while online.
private func fleetMachine(_ machine: MachineEndpoint) -> FleetMachine {
    FleetMachine(
        id: machine.id, daemonID: machine.daemonID ?? "", name: machine.name,
        entry: .with {
            $0.available = machine.online
            $0.unavailableMessage = machine.online ? "" : "\(machine.name) is offline."
        })
}

@Test @MainActor func fleetShowsTheSelectedMachineThroughTheCoreUnderItsMachineID() async throws {
    let core = ScriptedCoreClient()
    let fleet = FleetModel(machines: { [fleetMachine(fixture)] }, core: core, reportError: { _ in })
    await fleet.openMachine(fixture.id)
    #expect(
        core.commands.last?.telemetry.action
            == .select(
                .with {
                    $0.daemonID = "d_fixture"
                    $0.active = true
                }))
    core.emit(.telemetry) {
        $0.telemetry = .with {
            $0.machines = [
                "d_fixture": .with {
                    $0.information = .with { $0.hostname = "fixture.local" }
                    $0.cpuHistory = [10, 20]
                    $0.gpuHistory = ["gpu0": .with { $0.values = [5] }]
                },
                "d_unknown": .with { $0.information = .with { $0.hostname = "elsewhere" } },
            ]
            $0.operationResult = "Restart scheduled."
        }
    }
    #expect(fleet.machineInformation[fixture.id]?.hostname == "fixture.local")
    #expect(fleet.machineInformation.count == 1)
    #expect(fleet.machineCPUHistory[fixture.id] == [10, 20])
    #expect(fleet.machineGPUHistory[fixture.id]?["gpu0"] == [5])
    #expect(fleet.machineOperationMessage == "Restart scheduled.")

    // Closing the popover stops the readings; the shells and history stay.
    fleet.dismissMachinePopover()
    for _ in 0..<1_000 where core.commands.last?.telemetry.action != .select(ClientTelemetrySelect()) {
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    #expect(core.commands.last?.telemetry.action == .select(ClientTelemetrySelect()))
    #expect(fleet.selectedMachineID == nil)
}

@Test @MainActor func fleetOperationsGoToTheCoreAndAnOfflineMachineIsRefused() async throws {
    let core = ScriptedCoreClient()
    var errors: [String] = []
    var machines = [fixture]
    let fleet = FleetModel(
        machines: { machines.map(fleetMachine) }, core: core,
        reportError: { errors.append($0.localizedDescription) })
    core.handler = { command in
        if case .perform? = command.telemetry.action {
            return .with { $0.machineOperation = .with { $0.message = "Update started." } }
        }
        return .with { $0.done = ClientDone() }
    }
    fleet.selectedMachineID = fixture.id
    await fleet.performMachineOperation(.updateDaemon)
    #expect(core.commands.last?.telemetry.action == .perform(.with { $0.action = .updateDaemon }))
    #expect(fleet.machineOperationMessage == "Update started.")
    #expect(!fleet.machineOperationInFlight)

    let commands = core.commands.count
    machines = [MachineEndpoint(name: "Fixture", host: "127.0.0.1", port: 4242, daemonID: "d_fixture", online: false)]
    await fleet.performMachineOperation(.restart)
    #expect(core.commands.count == commands)
    #expect(errors == ["Fixture is offline."])
}
