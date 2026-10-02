import DieterAPI
import DieterCore
import Foundation
import SharedCore
import Testing
@testable import DieterMac

@MainActor private func waitForTerminals(_ condition: () -> Bool) async throws {
    for _ in 0..<1_000 {
        if condition() { return }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    throw CocoaError(.coderValueNotFound)
}

private func terminal(_ id: String, status: String = "running") -> Dieter_V1_Terminal {
    .with {
        $0.id = id
        $0.name = id
        $0.status = status
    }
}

@Test @MainActor func terminalsBindTheirTargetAndSendCommandsInOrder() async throws {
    let core = ScriptedCoreClient(), model = TerminalsModel()
    let target = ClientTerminalTarget.with {
        $0.daemonID = "machine"
        $0.kind = .card
        $0.projectID = "project"
        $0.cardID = "card"
    }
    core.handler = { _ in
        .with {
            $0.terminals = .with {
                $0.target = target
                $0.terminals = [terminal("shell")]
                $0.selectedID = "shell"
            }
        }
    }
    model.active = true
    model.bind(
        target: WorkspaceTarget(endpointID: "gateway#machine", projectID: "project", conversationID: "card"), core: core
    )
    await model.loadTerminals()
    model.sendTerminalInput(id: "shell", data: Data("ls\n".utf8))
    model.sendTerminalInput(id: "shell", data: Data("pwd\n".utf8))
    await model.resizeTerminal(id: "shell", columns: 90, rows: 25)
    await model.renameTerminal(id: "shell", name: "  build  ")
    #expect(
        core.commands.map(\.terminals.action) == [
            .bind(target), .active(.with { $0.on = true }), .load(ClientStep()),
            .input(.with { $0.data = Data("ls\n".utf8) }), .input(.with { $0.data = Data("pwd\n".utf8) }),
            .grid(
                .with {
                    $0.columns = 90; $0.rows = 25
                }),
            .rename(
                .with {
                    $0.terminalID = "shell"; $0.name = "build"
                }),
        ])
    #expect(Set(core.commands.map(\.terminals.scope)).count == 1)
    #expect(model.selectedTerminal?.id == "shell")
}

@Test @MainActor func terminalOutputFeedsTheScreenInOrderAndAResetReplacesIt() async throws {
    let core = ScriptedCoreClient(), model = TerminalsModel()
    let target = ClientTerminalTarget.with { $0.daemonID = "machine" }
    model.bind(target: WorkspaceTarget(endpointID: "gateway#machine", projectID: ""), core: core)
    await model.loadTerminals()
    let scope = try #require(core.commands.first?.terminals.scope)
    func emit(_ output: [(String, Bool)], terminals: [Dieter_V1_Terminal] = [terminal("shell")]) {
        core.emit(.terminals, scope: scope) {
            $0.terminals = .with {
                $0.target = target
                $0.terminals = terminals
                $0.selectedID = terminals.first?.id ?? ""
                $0.output = output.map { text, reset in
                    .with {
                        $0.terminalID = "shell"
                        $0.reset = reset
                        $0.data = Data(text.utf8)
                    }
                }
            }
        }
    }
    emit([("a", true)])
    emit([("b", false), ("c", false)])
    try await waitForTerminals { model.terminalScreens["shell"]?.data == Data("abc".utf8) }
    emit([("fresh", true)])
    try await waitForTerminals { model.terminalScreens["shell"]?.data == Data("fresh".utf8) }
    // A slice for another target is stale.
    core.emit(.terminals, scope: scope) {
        $0.terminals = .with {
            $0.target = .with { $0.daemonID = "other" }
            $0.terminals = [terminal("elsewhere")]
        }
    }
    #expect(model.terminals.map(\.id) == ["shell"])
    // A closed terminal's screen goes with it.
    emit([], terminals: [])
    #expect(model.terminalScreens.isEmpty)
}

@Test @MainActor func overviewEntriesNameTheirMachinesAndTheTerminalsFollowTheSelection() async throws {
    let core = ScriptedCoreClient(), terminals = TerminalsModel()
    var errors: [String] = []
    let overview = TerminalOverviewModel(
        terminalsModel: terminals, core: core, endpointID: { "gateway#\($0)" }, active: { true },
        reportError: { errors.append($0) })
    let slice = ClientTerminalOverviewSlice.with {
        $0.entries = [
            .with {
                $0.id = "home|t1"
                $0.daemonID = "home"
                $0.machineName = "mini-home"
                $0.terminal = terminal("t1")
            },
            .with {
                $0.id = "office|t2"
                $0.daemonID = "office"
                $0.machineName = "mb-office"
                $0.terminal = terminal("t2")
            },
        ]
        $0.selectedID = "office|t2"
        $0.errors = ["broken": "unreachable"]
        $0.terminals = .with {
            $0.target = .with { $0.daemonID = "office" }
            $0.terminals = [terminal("t2")]
            $0.selectedID = "t2"
        }
    }
    core.handler = { command in
        if case .terminalOverview? = command.command { return .with { $0.terminalOverview = slice } }
        return .with { $0.done = ClientDone() }
    }

    await overview.loadTerminalOverview(preferredMachineID: "gateway#office")
    let load = try #require(core.commands.first { if case .terminalOverview? = $0.command { true } else { false } })
    #expect(load.terminalOverview.load.preferredDaemonID == "office")
    #expect(overview.terminalOverviewEntries.map(\.id) == ["gateway#home|t1", "gateway#office|t2"])
    #expect(overview.selectedTerminalOverviewID == "gateway#office|t2")
    #expect(overview.terminalOverviewError == "broken: unreachable")
    #expect(terminals.target.endpointID == "gateway#office")
    #expect(terminals.machineName == "mb-office")
    #expect(terminals.selectedTerminalID == "t2")

    await overview.selectTerminalOverviewEntry("gateway#home|t1")
    #expect(core.commands.last?.terminalOverview.select.terminalID == "home|t1")

    // The followed terminals take commands under the overview's scope.
    terminals.active = true
    terminals.sendTerminalInput(id: "t2", data: Data("x".utf8))
    await terminals.renameTerminal(id: "t2", name: "renamed")
    let terminalCommands = core.commands.filter { if case .terminals? = $0.command { true } else { false } }
    #expect(terminalCommands.allSatisfy { $0.terminals.scope == load.terminalOverview.scope })
    #expect(terminalCommands.contains { $0.terminals.action == .input(.with { $0.data = Data("x".utf8) }) })
    #expect(errors.isEmpty)
}

@Test @MainActor func overviewCreatesAMachineHomeTerminalOnTheChosenMachine() async throws {
    let core = ScriptedCoreClient(), terminals = TerminalsModel()
    var errors: [String] = []
    let overview = TerminalOverviewModel(
        terminalsModel: terminals, core: core, endpointID: { "gateway#\($0)" }, active: { true },
        reportError: { errors.append($0) })
    var unavailable = true
    core.handler = { command in
        guard case .terminalOverview? = command.command else { return .with { $0.done = ClientDone() } }
        if unavailable { throw CoreFailure(kind: .transient, message: "The selected machine is unavailable.") }
        return .with { $0.terminalOverview = ClientTerminalOverviewSlice() }
    }
    terminals.createTerminalPresented = true
    func create() async {
        await overview.createOverviewTerminal(
            projectID: "", checkoutID: "", machineID: "gateway#home", machineHome: true, name: "Home shell",
            shell: "zsh", workingDirectory: "~")
    }

    await create()
    #expect(errors == ["The selected machine is unavailable."])
    #expect(terminals.createTerminalPresented, "a failed creation keeps the form")

    unavailable = false
    await create()
    let request = try #require(core.commands.last?.terminalOverview.create)
    #expect(request.daemonID == "home")
    #expect(request.machineHome)
    #expect(request.workingDirectory == "~")
    #expect(request.name == "Home shell")
    #expect(!terminals.createTerminalPresented)
}
