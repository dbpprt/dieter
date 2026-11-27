import DieterAPI
import DieterClientAPI
import Foundation
import Testing

@testable import DieterMacKit

/// The code reviewer over a scripted core: the settings form reads and saves
/// on the machine the core picks, with the core's pickers, wording and
/// checks; a conversation's switch, "Review changes" and a finding's
/// location each send exactly what the user chose.
@MainActor
struct CodeReviewModelTests {
    static let catalog = Dieter_V1_HarnessCatalog.with {
        $0.harnesses = [
            .with {
                $0.id = "claude-code"
                $0.name = "Claude Code"
                $0.defaultModel = "opus"
                $0.models = [
                    .with {
                        $0.id = "opus"
                        $0.name = "Opus"
                        $0.defaultEffort = "high"
                        $0.efforts = ["low", "high"]
                    },
                    .with {
                        $0.id = "sonnet"
                        $0.name = "Sonnet"
                        $0.defaultEffort = "low"
                    },
                ]
                $0.effort = .with {
                    $0.options = [
                        .with {
                            $0.id = "low"
                            $0.name = "Low"
                        },
                        .with {
                            $0.id = "high"
                            $0.name = "High"
                        },
                    ]
                }
                $0.options = [
                    .with {
                        $0.id = "fast_mode"
                        $0.type = "bool"
                        $0.mutable = true
                    }
                ]
            },
            .with {
                $0.id = "codex"
                $0.name = "Codex"
                $0.defaultModel = "sol"
                $0.models = [
                    .with {
                        $0.id = "sol"
                        $0.name = "Sol"
                    }
                ]
            },
        ]
    }

    static func settings(configured: Bool = true) -> Dieter_V1_ReviewerSettings {
        .with {
            $0.harness = "claude-code"
            $0.model = "opus"
            $0.effort = "high"
            $0.accountID = "pa_work"
            $0.depth = "quick"
            $0.maxFindings = 6
            $0.minConfidence = 4
            $0.maxRounds = 3
            $0.ignoreGlobs = ["*.lock"]
            $0.configured = configured
            $0.revision = "r1"
        }
    }

    private static func scriptedCore(_ settings: Dieter_V1_ReviewerSettings = settings()) -> ScriptedCoreClient {
        let core = ScriptedCoreClient()
        core.handler = { command in
            switch command.codeReview.action {
            case .settings?: return .with { $0.reviewerSettings = settings }
            case .updateSettings(let update)?:
                var saved = update.settings
                saved.configured = true
                saved.revision = "r2"
                return .with { $0.reviewerSettings = saved }
            default: return .with { $0.done = ClientDone() }
            }
        }
        return core
    }

    @Test func theFormEditsThisMacsMachineElseTheFirstAvailableOne() {
        let far = ClientMachineEntry.with {
            $0.id = "far"
            $0.available = true
        }
        let here = ClientMachineEntry.with {
            $0.id = "here"
            $0.available = true
            $0.local = true
        }
        let off = ClientMachineEntry.with {
            $0.id = "off"
            $0.local = true
        }
        #expect(CodeReviewerRules.machine([far, here, off]) == "here")
        #expect(CodeReviewerRules.machine([off, far]) == "far")
        #expect(CodeReviewerRules.machine([off]) == nil)
        #expect(CodeReviewerRules.depths == ["quick", "thorough"])
        #expect(CodeReviewerRules.depthTitle("thorough") == "Thorough")
        #expect(!CodeReviewerRules.depthDetail("").isEmpty, "an empty depth reads as the quick default")
        #expect(CodeReviewerRules.depthDetail("") == CodeReviewerRules.depthDetail("quick"))
        #expect(CodeReviewerRules.findings == 1...20 && CodeReviewerRules.rounds == 1...10)
    }

    @Test func theSettingIsReadFromTheChosenMachineAndRoundTripsUnchanged() async {
        let core = Self.scriptedCore()
        let model = CodeReviewerModel()
        model.core = core
        await model.load(daemonID: "here")
        #expect(core.commands.last?.codeReview.settings.daemonID == "here")
        let draft = model.draft
        #expect(draft == CodeReviewerDraft(Self.settings()))
        #expect(draft?.settings == Self.settings(), "every field survives the form")
        #expect(model.problem == nil && !model.canSave, "an unchanged saved setting has nothing to save")
        #expect(draft?.status(catalog: Self.catalog) == "Claude Code · Opus")
    }

    @Test func defaultsNobodySavedCanBeSavedAsTheyAre() async {
        let core = Self.scriptedCore(Self.settings(configured: false))
        let model = CodeReviewerModel()
        model.core = core
        await model.load(daemonID: "here")
        #expect(model.draft?.status(catalog: Self.catalog) == CodeReviewerRules.defaultsLabel)
        #expect(CodeReviewerRules.defaultsLabel == "Defaults")
        #expect(model.canSave)
    }

    @Test func aSaveSendsTheDraftAtItsReadRevisionAndShowsWhatTheMachineKept() async {
        let core = Self.scriptedCore()
        let model = CodeReviewerModel()
        model.core = core
        await model.load(daemonID: "here")
        model.draft?.depth = "thorough"
        model.draft?.maxFindings = 9
        model.draft?.instructions = "Mind the locks."
        #expect(model.canSave && model.draftProblem == nil && !model.showsSaved)
        #expect(await model.save())
        let update = core.commands.last?.codeReview.updateSettings
        #expect(update?.daemonID == "here")
        #expect(update?.settings.revision == "r1", "compare-and-set on the revision the form read")
        #expect(update?.settings.depth == "thorough" && update?.settings.maxFindings == 9)
        #expect(update?.settings.instructions == "Mind the locks.")
        #expect(update?.settings.ignoreGlobs == ["*.lock"] && update?.settings.accountID == "pa_work")
        #expect(model.saved?.revision == "r2" && model.draft == model.saved)
        #expect(model.showsSaved && !model.canSave)
        model.draft?.depth = "quick"
        #expect(!model.showsSaved, "an edit after the save hides the confirmation")
    }

    @Test func anInvalidDraftSaysWhyAndCannotBeSaved() async {
        let core = Self.scriptedCore()
        let model = CodeReviewerModel()
        model.core = core
        await model.load(daemonID: "here")
        model.draft?.maxRounds = 11
        #expect(!model.canSave)
        #expect(model.draftProblem == "Agents may ask for 1 to 10 reviews per task.")
        model.draft?.maxRounds = 3
        model.draft?.harness = ""
        #expect(model.draftProblem == "Choose the reviewer's agent.")
    }

    @Test func failuresAndMissingMachinesShowAsTheFormsProblem() async {
        let core = ScriptedCoreClient()
        core.handler = { _ in throw CoreFailure(kind: .transient, message: "box is offline.") }
        let model = CodeReviewerModel()
        model.core = core
        await model.load(daemonID: nil)
        #expect(model.problem == "No machine is online; the setting can change when one is.")
        #expect(core.commands.isEmpty)
        await model.load(daemonID: "box")
        #expect(model.problem == "box is offline." && model.draft == nil)
    }

    @Test func thePickersOfferAgentModelAndEffortAndAnotherAgentTakesItsDefaults() {
        let draft = CodeReviewerDraft(Self.settings())
        let controls = draft.controls(catalog: Self.catalog)
        #expect(controls.providers.map(\.id) == ["claude-code", "codex"])
        #expect(controls.models.map(\.id) == ["opus", "sonnet"])
        #expect(controls.options.isEmpty && controls.accounts.isEmpty, "no provider options or accounts")
        let codex = draft.choosing(.provider("codex"), catalog: Self.catalog)
        #expect(codex.harness == "codex" && codex.model == "sol")
        #expect(codex.accountID.isEmpty, "an account belongs to the agent it was chosen for")
        #expect(codex.depth == draft.depth && codex.revision == draft.revision, "only the agent changes")
        let sonnet = draft.choosing(.model("sonnet"), catalog: Self.catalog)
        #expect(sonnet.model == "sonnet" && sonnet.effort == "low" && sonnet.accountID == "pa_work")
        let memo = CodeReviewerControlsMemo()
        #expect(memo.controls(draft, catalog: Self.catalog) == controls)
        var edited = draft
        edited.instructions = "Only the instructions changed."
        #expect(memo.controls(edited, catalog: Self.catalog) == controls)
        #expect(memo.controls(codex, catalog: Self.catalog).models.map(\.id) == ["sol"])
    }

    @Test func aConversationsSwitchAndReviewChangesGoToItsCard() async throws {
        let core = ScriptedCoreClient()
        let model = ConversationModel()
        model.core = core
        model.observe("c_card")
        defer { model.observe(nil) }
        try await model.setCodeReview(enabled: true)
        try await model.startCodeReview()
        let commands = core.commands.map(\.codeReview.action).compactMap { $0 }
        #expect(
            commands == [
                .setEnabled(
                    .with {
                        $0.cardID = "c_card"
                        $0.enabled = true
                    }),
                .start(.with { $0.cardID = "c_card" }),
            ])
    }

    @Test func theChromeCarriesTheSwitchButNotTheLatestReview() {
        let state = ClientConversationState.with {
            $0.codeReview = .with {
                $0.enabled = true
                $0.canToggle = true
                $0.running = true
                $0.latest = .with {
                    $0.reviewID = "rev_1"
                    $0.running = true
                }
            }
        }
        let chrome = ConversationChrome(state)
        #expect(chrome.codeReview?.enabled == true && chrome.codeReview?.running == true)
        #expect(chrome.codeReview?.canStart == false && chrome.codeReview?.hasLatest == false)
        #expect(ConversationChrome(ClientConversationState()).codeReview == nil, "unset until the card is known")
    }

    @Test func aFindingsLocationSelectsItsFileOnceTheReviewReported() async throws {
        let core = ScriptedCoreClient()
        let model = WorktreeChangesModel()
        let target = WorkspaceTarget(endpointID: "gateway#machine", projectID: "project", conversationID: "c_card")
        model.bind(target: target, core: core, card: nil)
        model.show(path: "internal/git/unborn.go")
        await model.loadWorkspaceSurface()
        let scope = try #require(core.commands.first?.review.scope)
        #expect(!core.commands.contains { if case .select? = $0.review.action { true } else { false } })
        core.emit(.review, scope: scope) {
            $0.review = .with {
                $0.cardID = "c_card"
                $0.daemonID = "machine"
            }
        }
        for _ in 0..<1_000 where model.selectedChangePath.isEmpty {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(model.selectedChangePath == "internal/git/unborn.go")
        #expect(core.commands.contains { $0.review.select.path == "internal/git/unborn.go" })
    }
}
