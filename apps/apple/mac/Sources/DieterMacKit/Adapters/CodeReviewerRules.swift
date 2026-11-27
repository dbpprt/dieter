import DieterAPI
import DieterClientAPI
import DieterCore
import Foundation

extension CodeReviewerDraft {
    /// The account's reviewer setting (`dieter.v1.ReviewerSettings`) as the form edits it.
    init(_ settings: Dieter_V1_ReviewerSettings) {
        self.init(
            harness: settings.harness, model: settings.model, effort: settings.effort, accountID: settings.accountID,
            depth: settings.depth, maxFindings: Int(settings.maxFindings), minConfidence: Int(settings.minConfidence),
            instructions: settings.instructions, ignoreGlobs: settings.ignoreGlobs, maxRounds: Int(settings.maxRounds),
            configured: settings.configured, revision: settings.revision)
    }

    /// What a save sends: the edited values at the revision they were read at.
    var settings: Dieter_V1_ReviewerSettings {
        .with {
            $0.harness = harness
            $0.model = model
            $0.effort = effort
            $0.accountID = accountID
            $0.depth = depth
            $0.maxFindings = Int32(clamping: maxFindings)
            $0.minConfidence = Int32(clamping: minConfidence)
            $0.instructions = instructions
            $0.ignoreGlobs = ignoreGlobs
            $0.maxRounds = Int32(clamping: maxRounds)
            $0.configured = configured
            $0.revision = revision
        }
    }

    /// The agent, model and effort pickers over `catalog`, the edited
    /// machine's agents, as the core offers them to the reviewer.
    func controls(catalog: Dieter_V1_HarnessCatalog) -> ClientAgentControlsState {
        ClientAgentControlsState(
            rules: SharedRules.shared.reviewerAgentControls(settings: settings.rulesData, catalog: catalog.rulesData))
    }

    /// The draft after a picker's `choice`: another agent takes its default
    /// model and effort, another model its default effort.
    func choosing(_ choice: ClientAgentChoice.OneOf_Choice, catalog: Dieter_V1_HarnessCatalog) -> CodeReviewerDraft {
        let picked = ClientAgentChoice.with { $0.choice = choice }
        let next = Dieter_V1_ReviewerSettings(
            rules: SharedRules.shared.reviewerChoosing(
                settings: settings.rulesData, catalog: catalog.rulesData, choice: picked.rulesData))
        var draft = self
        draft.harness = next.harness
        draft.model = next.model
        draft.effort = next.effort
        draft.accountID = next.accountID
        return draft
    }

    /// "Defaults" until someone saved the setting, else "Claude Code · opus".
    func status(catalog: Dieter_V1_HarnessCatalog) -> String {
        SharedRules.shared.reviewerStatus(settings: settings.rulesData, catalog: catalog.rulesData)
    }

    /// Why the draft cannot be saved, as the daemon would refuse it; nil when it can.
    var problem: String? {
        let problem = SharedRules.shared.reviewerProblem(settings: settings.rulesData)
        return problem.isEmpty ? nil : problem
    }
}

/// The reviewer settings form's fixed wording and bounds, from the core.
enum CodeReviewerRules {
    /// The machine the form reads and saves on: this Mac's when it is
    /// available, else the first available one; nil while none is.
    static func machine(_ entries: [ClientMachineEntry]) -> String? {
        let id = SharedRules.shared.reviewerMachine(machines: entries.map(\.rulesData))
        return id.isEmpty ? nil : id
    }

    /// "quick" and "thorough".
    static var depths: [String] { SharedRules.shared.reviewerDepths() }

    static func depthTitle(_ depth: String) -> String { SharedRules.shared.reviewerDepthTitle(depth: depth) }

    /// What a depth does, in one line; an empty depth is the quick default.
    static func depthDetail(_ depth: String) -> String { SharedRules.shared.reviewerDepthDetail(depth: depth) }

    /// The note a form shows while nobody saved the setting yet.
    static var defaultsLabel: String { SharedRules.shared.reviewerDefaultsLabel() }

    static var findings: ClosedRange<Int> {
        Int(SharedRules.shared.reviewerMinFindings())...Int(SharedRules.shared.reviewerMaxFindings())
    }

    static var rounds: ClosedRange<Int> {
        Int(SharedRules.shared.reviewerMinRounds())...Int(SharedRules.shared.reviewerMaxRounds())
    }
}

/// The reviewer pickers last resolved for a draft's agent and a catalog. The
/// form redraws as its other fields change, e.g. on every keystroke of its
/// instructions; only a change of these asks the core again, rather than
/// serializing the whole catalog each time.
@MainActor final class CodeReviewerControlsMemo {
    private struct Agent: Equatable {
        let harness: String
        let model: String
        let effort: String
        let accountID: String
    }

    private var agent: Agent?
    private var catalog: Dieter_V1_HarnessCatalog?
    private var value = ClientAgentControlsState()

    func controls(_ draft: CodeReviewerDraft, catalog: Dieter_V1_HarnessCatalog) -> ClientAgentControlsState {
        let agent = Agent(harness: draft.harness, model: draft.model, effort: draft.effort, accountID: draft.accountID)
        if agent == self.agent, catalog == self.catalog { return value }
        value = draft.controls(catalog: catalog)
        self.agent = agent
        self.catalog = catalog
        return value
    }
}
