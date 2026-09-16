import DieterAPI
import DieterCore
import Foundation
import Testing
@testable import DieterMac

private actor TerminalRoutingFixture: TerminalsRPC {
    private(set) var createRequests: [Dieter_V1_CreateTerminalRequest] = []

    func terminals(projectID: String, cardID: String) async throws -> Dieter_V1_TerminalsResponse {
        var first = Dieter_V1_Terminal()
        first.id = "first"
        first.name = "First"
        first.status = "running"
        var second = Dieter_V1_Terminal()
        second.id = "second"
        second.name = "Second"
        second.status = "running"
        var response = Dieter_V1_TerminalsResponse()
        response.terminals = [first, second]
        return response
    }

    func createTerminal(_ request: Dieter_V1_CreateTerminalRequest) async throws -> Dieter_V1_Terminal {
        createRequests.append(request)
        var terminal = Dieter_V1_Terminal()
        terminal.id = "machine-home"
        terminal.name = request.name
        terminal.status = "running"
        return terminal
    }

    func watchTerminal(
        id: String, after: UInt64,
        receive: @escaping @Sendable (Dieter_V1_TerminalFrame) async -> Void
    ) async throws {}

    func writeTerminal(id: String, data: Data) async throws -> Dieter_V1_Terminal { .init() }
    func resizeTerminal(id: String, columns: Int, rows: Int) async throws -> Dieter_V1_Terminal { .init() }
    func renameTerminal(id: String, name: String) async throws -> Dieter_V1_Terminal { .init() }
    func closeTerminal(id: String) async throws {}
}

@MainActor
@Test func terminalSelectionPersistsPerMachineAcrossModelRecreation() async throws {
    let suiteName = "TerminalRoutingTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let rpc = TerminalRoutingFixture()
    let home = WorkspaceTarget(endpointID: "home", projectID: "")
    let office = WorkspaceTarget(endpointID: "office", projectID: "")

    let firstModel = TerminalsModel(selectionDefaults: defaults)
    firstModel.bind(target: home, client: rpc)
    await firstModel.loadTerminals()
    firstModel.selectTerminal("second")
    firstModel.bind(target: office, client: rpc)
    await firstModel.loadTerminals()
    #expect(firstModel.selectedTerminalID == "first")
    firstModel.bind(target: home, client: rpc)
    await firstModel.loadTerminals()
    #expect(firstModel.selectedTerminalID == "second")

    let restoredModel = TerminalsModel(selectionDefaults: defaults)
    restoredModel.bind(target: home, client: rpc)
    await restoredModel.loadTerminals()
    #expect(restoredModel.selectedTerminalID == "second")
}

@MainActor
@Test func terminalModelForwardsMachineHomeScope() async throws {
    let rpc = TerminalRoutingFixture()
    let model = TerminalsModel()
    model.bind(target: WorkspaceTarget(endpointID: "home", projectID: ""), client: rpc)

    await model.createTerminal(
        projectID: "", machineHome: true, name: "Home shell", shell: "zsh", workingDirectory: "~")

    let request = try #require(await rpc.createRequests.last)
    #expect(request.machineHome)
    #expect(request.projectID.isEmpty)
    #expect(request.cardID.isEmpty)
    #expect(request.workingDirectory == "~")
}

@Test func terminalOverviewCombinesMachinesAndKeepsAStableSelection() throws {
    func entry(machineID: String, machineName: String, terminalID: String, createdAt: String) -> TerminalOverviewEntry {
        var terminal = Dieter_V1_Terminal()
        terminal.id = terminalID
        terminal.name = terminalID
        terminal.createdAt = createdAt
        return TerminalOverviewEntry(machineID: machineID, machineName: machineName, terminal: terminal)
    }

    let office = entry(
        machineID: "office", machineName: "mb-office", terminalID: "terminal-office",
        createdAt: "2026-09-13T12:00:00Z")
    let home = entry(
        machineID: "home", machineName: "mini-home", terminalID: "terminal-home",
        createdAt: "2026-09-13T11:00:00Z")
    let values = TerminalOverviewCatalog.sorted([office, home])

    #expect(values.map(\.id) == [home.id, office.id])
    #expect(TerminalOverviewCatalog.selection(in: values, currentID: office.id)?.id == office.id)
    #expect(
        TerminalOverviewCatalog.selection(in: values, currentID: "missing", preferredMachineID: "home")?.id
            == home.id)
}
