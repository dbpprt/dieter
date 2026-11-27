import DieterAPI
import DieterClientAPI
import DieterCore
import Foundation

extension MemoryDraft {
    /// The account's memory setting (`dieter.v1.MemorySettings`) as the form
    /// shows it: the daemon's defaults fill what nobody set, so the steppers
    /// show real values.
    init(_ settings: Dieter_V1_MemorySettings) {
        let shown = Dieter_V1_MemorySettings(
            rules: SharedRules.shared.memoryWithDefaults(settings: settings.rulesData))
        self.init(
            dreaming: shown.dreaming, harness: shown.harness, model: shown.model, effort: shown.effort,
            accountID: shown.accountID, runOn: shown.runOn, minHours: Int(shown.minHours),
            minNewTasks: Int(shown.minNewTasks), window: shown.window, apply: shown.apply,
            maxOperations: Int(shown.maxOperations), maxRetirePercent: Int(shown.maxRetirePercent),
            instructions: shown.instructions, configured: shown.configured, revision: shown.revision)
    }

    /// What a save sends: the edited values at the revision they were read at.
    var settings: Dieter_V1_MemorySettings {
        .with {
            $0.dreaming = dreaming
            $0.harness = harness
            $0.model = model
            $0.effort = effort
            $0.accountID = accountID
            $0.runOn = runOn
            $0.minHours = Int32(clamping: minHours)
            $0.minNewTasks = Int32(clamping: minNewTasks)
            $0.window = window
            $0.apply = apply
            $0.maxOperations = Int32(clamping: maxOperations)
            $0.maxRetirePercent = Int32(clamping: maxRetirePercent)
            $0.instructions = instructions
            $0.configured = configured
            $0.revision = revision
        }
    }

    /// The dreaming agent's pickers over `catalog`, the edited machine's
    /// agents (Strix left out), with the provider accounts of `providers`
    /// judged on the run-on machine.
    func controls(
        catalog: Dieter_V1_HarnessCatalog, providers: ClientProvidersSlice = ClientProvidersSlice()
    ) -> ClientAgentControlsState {
        ClientAgentControlsState(
            rules: SharedRules.shared.memoryAgentControls(
                settings: settings.rulesData, catalog: catalog.rulesData, providers: Self.encoded(providers),
                daemonId: runOn))
    }

    /// The draft after a picker's `choice`: another agent takes its default
    /// model and effort and the provider default account, another model its
    /// default effort. The empty account goes back to the provider default.
    func choosing(
        _ choice: ClientAgentChoice.OneOf_Choice, catalog: Dieter_V1_HarnessCatalog,
        providers: ClientProvidersSlice = ClientProvidersSlice()
    ) -> MemoryDraft {
        var draft = self
        if case .account(let id) = choice, id.isEmpty {
            draft.accountID = ""
            return draft
        }
        let picked = ClientAgentChoice.with { $0.choice = choice }
        let next = Dieter_V1_MemorySettings(
            rules: SharedRules.shared.memoryChoosing(
                settings: settings.rulesData, catalog: catalog.rulesData, choice: picked.rulesData,
                providers: Self.encoded(providers), daemonId: runOn))
        draft.harness = next.harness
        draft.model = next.model
        draft.effort = next.effort
        draft.accountID = next.accountID
        return draft
    }

    /// "Dreaming off", else "Claude Code · Opus · Review first".
    func status(catalog: Dieter_V1_HarnessCatalog) -> String {
        SharedRules.shared.memoryStatus(settings: settings.rulesData, catalog: catalog.rulesData)
    }

    /// Why the draft cannot be saved, as the daemon would refuse it; nil when it can.
    var problem: String? {
        let problem = SharedRules.shared.memoryProblem(settings: settings.rulesData)
        return problem.isEmpty ? nil : problem
    }

    /// The draft differs from `saved`, the setting it was read from, as a
    /// save would store it, or nobody saved one yet.
    func changed(from saved: MemoryDraft) -> Bool {
        SharedRules.shared.memoryChanged(draft: settings.rulesData, saved: saved.settings.rulesData)
    }

    private static func encoded(_ providers: ClientProvidersSlice) -> Data {
        providers == ClientProvidersSlice() ? Data() : providers.rulesData
    }
}

extension ProjectMemoryState {
    /// `projectID`'s state in a machine's memory status; a project the
    /// machine has not indexed yet reads as nothing indexed.
    init(_ status: Dieter_V1_MemoryStatus, projectID: String) {
        let project =
            status.projects.first { $0.projectID == projectID } ?? .with { $0.projectID = projectID }
        self.init(machine: status.machine, encoded: project.rulesData)
    }

    /// "12 conversations indexed on Studio · 5 saved memories".
    var summary: String {
        SharedRules.shared.memoryProjectSummary(status: encoded, machine: machine)
    }

    /// "Last dream 2d ago · Next dream in 5h"; `machines` name the machine
    /// dreams run on.
    func dreams(now: Date, machines: [ClientMachineEntry]) -> String {
        SharedRules.shared.memoryProjectDreams(
            status: encoded, nowMillis: now.epochMillis, machines: machines.map(\.rulesData))
    }
}

/// The memory settings form's fixed wording, choices and bounds, from the core.
enum MemoryRules {
    /// The machine the form reads and saves on: this Mac's when it is
    /// available, else the first available one; nil while none is.
    static func machine(_ entries: [ClientMachineEntry]) -> String? {
        let id = SharedRules.shared.memoryMachine(machines: entries.map(\.rulesData))
        return id.isEmpty ? nil : id
    }

    /// "auto" and "review".
    static var applyModes: [String] { SharedRules.shared.memoryApplyModes() }

    /// "Apply at once", "Review first"; an empty mode is the default, auto.
    static func applyTitle(_ apply: String) -> String { SharedRules.shared.memoryApplyTitle(apply: apply) }

    /// What an apply mode does, in one line.
    static func applyDetail(_ apply: String) -> String { SharedRules.shared.memoryApplyDetail(apply: apply) }

    /// The run-on picker's machine IDs: "" (automatic) first, then `entries`,
    /// then an unknown `runOn`.
    static func runOnIDs(_ entries: [ClientMachineEntry], runOn: String) -> [String] {
        SharedRules.shared.memoryRunOnIds(machines: entries.map(\.rulesData), runOn: runOn)
    }

    /// "Automatic", or the machine's name.
    static func runOnTitle(_ entries: [ClientMachineEntry], runOn: String) -> String {
        SharedRules.shared.memoryRunOnTitle(machines: entries.map(\.rulesData), runOn: runOn)
    }

    /// What the run-on choice means.
    static func runOnDetail(_ runOn: String) -> String { SharedRules.shared.memoryRunOnDetail(runOn: runOn) }

    /// Why `window` is not a start window; nil for "HH:MM-HH:MM" or empty (any time).
    static func windowProblem(_ window: String) -> String? {
        let problem = SharedRules.shared.memoryWindowProblem(window: window)
        return problem.isEmpty ? nil : problem
    }

    /// The note a form shows while nobody saved the setting yet.
    static var defaultsLabel: String { SharedRules.shared.memoryDefaultsLabel() }

    /// The default start window, e.g. "02:00-06:00".
    static var defaultWindow: String { SharedRules.shared.memoryDefaultWindow() }

    static var hours: ClosedRange<Int> {
        Int(SharedRules.shared.memoryMinHours())...Int(SharedRules.shared.memoryMaxHours())
    }

    static var newTasks: ClosedRange<Int> {
        Int(SharedRules.shared.memoryMinNewTasks())...Int(SharedRules.shared.memoryMaxNewTasks())
    }

    static var operations: ClosedRange<Int> {
        Int(SharedRules.shared.memoryMinOperations())...Int(SharedRules.shared.memoryMaxOperations())
    }

    static var retirePercent: ClosedRange<Int> {
        Int(SharedRules.shared.memoryMinRetirePercent())...Int(SharedRules.shared.memoryMaxRetirePercent())
    }
}

/// The dreaming agent's pickers last resolved for a draft's agent, run-on
/// machine, catalog and provider accounts. The form redraws as its other
/// fields change, e.g. on every keystroke of its instructions; only a change
/// of these asks the core again.
@MainActor final class MemoryControlsMemo {
    private struct Key: Equatable {
        let harness: String
        let model: String
        let effort: String
        let accountID: String
        let runOn: String
        let catalog: Dieter_V1_HarnessCatalog
        let providers: ClientProvidersSlice
    }

    private var key: Key?
    private var value = ClientAgentControlsState()

    func controls(
        _ draft: MemoryDraft, catalog: Dieter_V1_HarnessCatalog,
        providers: ClientProvidersSlice = ClientProvidersSlice()
    ) -> ClientAgentControlsState {
        let key = Key(
            harness: draft.harness, model: draft.model, effort: draft.effort, accountID: draft.accountID,
            runOn: draft.runOn, catalog: catalog, providers: providers)
        if key == self.key { return value }
        value = draft.controls(catalog: catalog, providers: providers)
        self.key = key
        return value
    }
}
