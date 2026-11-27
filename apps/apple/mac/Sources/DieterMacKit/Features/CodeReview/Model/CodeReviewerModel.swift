import DieterClientAPI
import Foundation
import Observation

/// The code reviewer's setting as its settings form edits it: one
/// account-wide record every machine replicates. The adapter maps it to and
/// from the setting the core reads and saves.
struct CodeReviewerDraft: Equatable, Sendable {
    var harness = ""
    var model = ""
    var effort = ""
    var accountID = ""
    /// "quick" or "thorough"; empty is the quick default.
    var depth = ""
    var maxFindings = 0
    var minConfidence = 0
    var instructions = ""
    var ignoreGlobs: [String] = []
    var maxRounds = 0
    /// False while nobody saved the setting; the values are then the defaults.
    var configured = false
    /// The record revision the values were read at; a save is compare-and-set on it.
    var revision = ""
}

/// Settings › Code reviewer: the account's reviewer setting, read from and
/// saved on one machine (`CodeReviewerRules.machine`) whose catalog the
/// form's pickers show. The core reads, checks and saves it; this model
/// keeps what the form shows.
@MainActor @Observable final class CodeReviewerModel {
    /// The setting as last read or saved; nil until it arrives.
    private(set) var saved: CodeReviewerDraft?
    /// What the form shows and edits; every read or save replaces it.
    var draft: CodeReviewerDraft?
    /// The machine the form reads and saves on; nil while none is available.
    private(set) var daemonID: String?
    /// Why the setting could not be read or saved, as the core says it.
    private(set) var problem: String?
    private(set) var loading = false
    private(set) var saving = false
    /// The last save went through; the form says so until the draft changes.
    private(set) var confirmed = false
    @ObservationIgnored var core: CoreClient?

    init() {}

    /// A save can go out: the draft is valid and changed, or shows defaults
    /// nobody saved yet.
    var canSave: Bool {
        guard let draft, daemonID != nil, !saving, draft.problem == nil else { return false }
        return draft != saved || !draft.configured
    }

    /// The form shows what the machine kept after a save.
    var showsSaved: Bool { confirmed && draft != nil && draft == saved }

    /// Why the edited draft cannot be saved; nil while it is unchanged or valid.
    var draftProblem: String? {
        guard let draft, draft != saved else { return nil }
        return draft.problem
    }

    /// Reads the setting from `daemonID`, the machine the form edits; nil
    /// while no machine is available.
    func load(daemonID: String?) async {
        self.daemonID = daemonID
        guard let daemonID else {
            problem = "No machine is online; the setting can change when one is."
            return
        }
        guard let core else { return }
        loading = true
        defer { loading = false }
        do {
            let result = try await core.dispatch { $0.codeReview.settings = .with { $0.daemonID = daemonID } }
            guard self.daemonID == daemonID else { return }
            show(CodeReviewerDraft(result.reviewerSettings))
            confirmed = false
            problem = nil
        } catch {
            guard self.daemonID == daemonID else { return }
            problem = error.localizedDescription
        }
    }

    /// Saves the draft on the machine it was read from; true once it kept it.
    @discardableResult
    func save() async -> Bool {
        guard let core, let draft, let daemonID, !saving else { return false }
        saving = true
        defer { saving = false }
        let settings = draft.settings
        do {
            let result = try await core.dispatch {
                $0.codeReview.updateSettings = .with {
                    $0.daemonID = daemonID
                    $0.settings = settings
                }
            }
            show(CodeReviewerDraft(result.reviewerSettings))
            confirmed = true
            problem = nil
            return true
        } catch {
            problem = error.localizedDescription
            return false
        }
    }

    private func show(_ settings: CodeReviewerDraft) {
        saved = settings
        draft = settings
    }
}
