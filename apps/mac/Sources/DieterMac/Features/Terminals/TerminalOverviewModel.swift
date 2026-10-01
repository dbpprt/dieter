import DieterAPI
import DieterCore
import Foundation
import Observation
import SharedCore

/// Every terminal on every online, compatible machine, kept by the shared
/// core. Selecting an entry points the core's overview terminals, which the
/// terminals model follows, at that machine.
@MainActor @Observable final class TerminalOverviewModel {
    var terminalOverviewEntries: [TerminalOverviewEntry] = []
    var selectedTerminalOverviewID: String?
    var terminalOverviewLoading = false
    var terminalOverviewError: String?
    var terminalOverviewPreferredMachineID: String?

    private let terminalsModel: TerminalsModel
    private let core: CoreClient
    private let endpointID: (String) -> String
    private let isOverviewActive: () -> Bool
    private let reportError: (String) -> Void
    @ObservationIgnored private let scope = "overview-\(UUID().uuidString)"
    @ObservationIgnored private var subscription: SliceSubscription?
    @ObservationIgnored private var generation: UInt64 = 0

    /// `endpointID` names the machine of a daemon.
    init(
        terminalsModel: TerminalsModel, core: CoreClient, endpointID: @escaping (String) -> String,
        active: @escaping () -> Bool, reportError: @escaping (String) -> Void
    ) {
        self.terminalsModel = terminalsModel
        self.core = core
        self.endpointID = endpointID
        isOverviewActive = active
        self.reportError = reportError
    }

    /// Opens the overview and points the terminals model at it.
    private func start() {
        if subscription == nil {
            subscription = SliceSubscription(client: core, slice: .terminalOverview, scope: scope) {
                [weak self] update in
                guard let self, case .terminalOverview(let slice) = update.value else { return }
                self.fold(slice)
            }
        }
        terminalsModel.follow(overviewScope: scope, core: core)
    }

    /// Closes the overview; the core stops streaming and the shells keep running.
    func stop() {
        generation &+= 1
        subscription?.close()
        subscription = nil
        terminalOverviewLoading = false
    }

    func reset() {
        stop()
        terminalOverviewEntries = []
        selectedTerminalOverviewID = nil
        terminalOverviewError = nil
    }

    func loadTerminalOverview(preferredMachineID: String? = nil) async {
        start()
        let daemonID = preferredMachineID.map { WorkspaceTarget(endpointID: $0, projectID: "").daemonID } ?? ""
        terminalOverviewLoading = terminalOverviewEntries.isEmpty
        await run { $0.load = .with { $0.preferredDaemonID = daemonID } }
    }

    func selectTerminalOverviewEntry(_ id: String) async {
        guard isOverviewActive(), let entry = terminalOverviewEntries.first(where: { $0.id == id }) else { return }
        await run { command in command.select = .with { $0.terminalID = Self.coreID(entry) } }
    }

    func createOverviewTerminal(
        projectID: String, checkoutID: String, machineID: String?, machineHome: Bool,
        name: String, shell: String, workingDirectory: String
    ) async {
        guard let machineID, !WorkspaceTarget(endpointID: machineID, projectID: "").daemonID.isEmpty else {
            reportError("The selected machine is unavailable.")
            return
        }
        start()
        let result = await run(reportingFailure: true) { command in
            command.create = .with {
                $0.daemonID = WorkspaceTarget(endpointID: machineID, projectID: "").daemonID
                $0.projectID = projectID
                $0.checkoutID = checkoutID
                $0.machineHome = machineHome
                $0.name = name
                $0.shell = shell
                $0.workingDirectory = workingDirectory
            }
        }
        if result != nil { terminalsModel.createTerminalPresented = false }
    }

    /// Runs an overview command and folds the overview it returns. A failed
    /// load shows on the overview; a failed creation is reported.
    @discardableResult
    private func run(
        reportingFailure: Bool = false, _ build: (inout ClientTerminalOverviewCommand) -> Void
    ) async -> ClientResult? {
        var command = ClientTerminalOverviewCommand()
        command.scope = scope
        build(&command)
        let sent = command, started = generation
        do {
            let result = try await core.dispatch(.with { $0.terminalOverview = sent })
            guard started == generation else { return nil }
            if case .terminalOverview(let slice)? = result.result { fold(slice) }
            return result
        } catch let failure as CoreFailure {
            guard started == generation else { return nil }
            terminalOverviewLoading = false
            if reportingFailure { reportError(failure.message) } else { terminalOverviewError = failure.message }
            return nil
        } catch {
            return nil
        }
    }

    private func fold(_ slice: ClientTerminalOverviewSlice) {
        let entries = slice.entries.map {
            TerminalOverviewEntry(
                machineID: endpointID($0.daemonID), machineName: $0.machineName, terminal: $0.terminal)
        }
        if terminalOverviewEntries != entries { terminalOverviewEntries = entries }
        let selected = slice.entries.first { $0.id == slice.selectedID }.map {
            TerminalOverviewEntry.id(machineID: endpointID($0.daemonID), terminalID: $0.terminal.id)
        }
        if selectedTerminalOverviewID != selected { selectedTerminalOverviewID = selected }
        if terminalOverviewLoading != slice.loading { terminalOverviewLoading = slice.loading }
        let error =
            slice.noMachines
            ? "No compatible Dieter machines are online."
            : slice.errors.isEmpty
                ? nil : slice.errors.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
        if terminalOverviewError != error { terminalOverviewError = error }
        let daemonID = slice.terminals.target.daemonID
        if let name = slice.entries.first(where: { $0.daemonID == daemonID })?.machineName {
            terminalsModel.machineName = name
        }
        terminalsModel.fold(
            slice.terminals,
            target: WorkspaceTarget(endpointID: daemonID.isEmpty ? "" : endpointID(daemonID), projectID: ""))
    }

    /// The core names an entry `daemon|terminal`.
    private static func coreID(_ entry: TerminalOverviewEntry) -> String {
        "\(WorkspaceTarget(endpointID: entry.machineID, projectID: "").daemonID)|\(entry.terminal.id)"
    }
}
