import DieterAPI
import DieterClientAPI
import Foundation
import Testing

@testable import DieterMacKit

/// Agent memory over a scripted core: the settings form reads and saves on
/// the machine the core picks, with the core's defaults, pickers, wording and
/// checks; a project's state and a dream started from its settings, a
/// conversation's switch and a dream's review each send exactly what the
/// user chose.
@MainActor
struct MemoryModelTests {
    /// The reviewer tests' agents, and Strix, which cannot dream.
    static let catalog: Dieter_V1_HarnessCatalog = {
        var catalog = CodeReviewModelTests.catalog
        catalog.harnesses.append(
            .with {
                $0.id = "strix"
                $0.name = "Strix"
                $0.defaultModel = "scan"
                $0.models = [
                    .with {
                        $0.id = "scan"
                        $0.name = "Scan"
                    }
                ]
            })
        return catalog
    }()

    static func settings(configured: Bool = true) -> Dieter_V1_MemorySettings {
        guard configured else { return Dieter_V1_MemorySettings() }
        return .with {
            $0.dreaming = true
            $0.harness = "claude-code"
            $0.model = "opus"
            $0.effort = "high"
            $0.accountID = "pa_work"
            $0.runOn = "here"
            $0.minHours = 12
            $0.minNewTasks = 3
            $0.window = "01:00-05:00"
            $0.apply = "review"
            $0.maxOperations = 20
            $0.maxRetirePercent = 10
            $0.instructions = "Keep the decisions."
            $0.configured = true
            $0.revision = "r1"
        }
    }

    static func scriptedCore(_ settings: Dieter_V1_MemorySettings = settings()) -> ScriptedCoreClient {
        let core = ScriptedCoreClient()
        core.handler = { command in
            switch command.memory.action {
            case .settings?: return .with { $0.memorySettings = settings }
            case .updateSettings(let update)?:
                var saved = update.settings
                saved.configured = true
                saved.revision = "r2"
                return .with { $0.memorySettings = saved }
            default: return .with { $0.done = ClientDone() }
            }
        }
        return core
    }

    static let here = ClientMachineEntry.with {
        $0.id = "here"
        $0.name = "here"
        $0.displayName = "Here Mac"
        $0.available = true
        $0.local = true
    }

    static let far = ClientMachineEntry.with {
        $0.id = "far"
        $0.name = "far"
        $0.displayName = "Studio"
        $0.available = true
    }

    @Test func theFormEditsThisMacsMachineAndOffersTheCoresChoices() {
        let off = ClientMachineEntry.with {
            $0.id = "off"
            $0.local = true
        }
        #expect(MemoryRules.machine([Self.far, Self.here, off]) == "here")
        #expect(MemoryRules.machine([off, Self.far]) == "far")
        #expect(MemoryRules.machine([off]) == nil)
        #expect(MemoryRules.applyModes == ["auto", "review"])
        #expect(MemoryRules.applyTitle("review") == "Review first")
        #expect(MemoryRules.applyTitle("") == "Apply at once", "an empty mode is the auto default")
        #expect(!MemoryRules.applyDetail("review").isEmpty)
        let machines = [Self.here, Self.far]
        #expect(MemoryRules.runOnIDs(machines, runOn: "") == ["", "here", "far"])
        #expect(MemoryRules.runOnIDs(machines, runOn: "gone") == ["", "here", "far", "gone"])
        #expect(MemoryRules.runOnTitle(machines, runOn: "") == "Automatic")
        #expect(MemoryRules.runOnTitle(machines, runOn: "far") == "Studio")
        #expect(MemoryRules.runOnDetail("") != MemoryRules.runOnDetail("far"))
        #expect(MemoryRules.windowProblem("") == nil && MemoryRules.windowProblem("22:00-04:30") == nil)
        #expect(MemoryRules.windowProblem("late") != nil)
        #expect(MemoryRules.defaultsLabel == "Defaults" && MemoryRules.defaultWindow == "02:00-06:00")
        #expect(MemoryRules.hours == 1...168 && MemoryRules.newTasks == 1...100)
        #expect(MemoryRules.operations == 1...100 && MemoryRules.retirePercent == 1...100)
    }

    @Test func theSettingIsReadFromTheChosenMachineAndRoundTripsUnchanged() async {
        let core = Self.scriptedCore()
        let model = MemoryModel()
        model.core = core
        await model.load(daemonID: "here")
        #expect(core.commands.last?.memory.settings.daemonID == "here")
        let draft = model.draft
        #expect(draft == MemoryDraft(Self.settings()))
        #expect(draft?.settings == Self.settings(), "every field survives the form")
        #expect(model.problem == nil && !model.canSave, "an unchanged saved setting has nothing to save")
        #expect(draft?.status(catalog: Self.catalog) == "Claude Code · Opus · Review first")
        var off = draft
        off?.dreaming = false
        #expect(off?.status(catalog: Self.catalog) == "Dreaming off")
    }

    @Test func defaultsNobodySavedShowAsTheDaemonsAndCanBeSaved() async throws {
        let core = Self.scriptedCore(Self.settings(configured: false))
        let model = MemoryModel()
        model.core = core
        await model.load(daemonID: "here")
        let draft = try #require(model.draft)
        #expect(draft.harness == "claude-code" && draft.model == "opus")
        #expect(draft.minHours == 24 && draft.minNewTasks == 5 && draft.apply == "auto")
        #expect(draft.maxOperations == 40 && draft.maxRetirePercent == 25)
        #expect(draft.window == "" && !draft.dreaming, "an empty window is any time")
        #expect(!draft.configured)
        #expect(model.canSave, "saving the defaults keeps them")
    }

    @Test func aSaveSendsTheDraftAtItsReadRevisionAndShowsWhatTheMachineKept() async {
        let core = Self.scriptedCore()
        let model = MemoryModel()
        model.core = core
        await model.load(daemonID: "here")
        model.draft?.apply = "auto"
        model.draft?.minHours = 48
        model.draft?.runOn = ""
        model.draft?.instructions = "Retire stale facts."
        #expect(model.canSave && model.draftProblem == nil && !model.showsSaved)
        #expect(await model.save())
        let update = core.commands.last?.memory.updateSettings
        #expect(update?.daemonID == "here")
        #expect(update?.settings.revision == "r1", "compare-and-set on the revision the form read")
        #expect(update?.settings.apply == "auto" && update?.settings.minHours == 48)
        #expect(update?.settings.runOn == "" && update?.settings.instructions == "Retire stale facts.")
        #expect(update?.settings.accountID == "pa_work" && update?.settings.maxRetirePercent == 10)
        #expect(model.saved?.revision == "r2" && model.draft == model.saved)
        #expect(model.showsSaved && !model.canSave)
        model.draft?.minHours = 12
        #expect(!model.showsSaved, "an edit after the save hides the confirmation")
    }

    @Test func aStaleSaveShowsTheMachinesRefusal() async {
        let core = Self.scriptedCore()
        let model = MemoryModel()
        model.core = core
        await model.load(daemonID: "here")
        core.handler = { _ in
            throw CoreFailure(kind: .permanent, message: "The memory setting changed elsewhere; read it again.")
        }
        model.draft?.minHours = 30
        #expect(await model.save() == false)
        #expect(model.problem == "The memory setting changed elsewhere; read it again.")
        #expect(model.draft?.minHours == 30, "the edit stays for another try")
    }

    @Test func anInvalidDraftSaysWhyAndCannotBeSaved() async {
        let core = Self.scriptedCore()
        let model = MemoryModel()
        model.core = core
        await model.load(daemonID: "here")
        model.draft?.minHours = 200
        #expect(!model.canSave)
        #expect(model.draftProblem == "Dreams start at most every 1 to 168 hours.")
        model.draft?.minHours = 12
        model.draft?.window = "late"
        #expect(model.draftProblem == MemoryRules.windowProblem("late"))
        model.draft?.window = ""
        model.draft?.harness = "strix"
        #expect(model.draftProblem == "Strix cannot dream; choose another agent.")
    }

    @Test func failuresAndMissingMachinesShowAsTheFormsProblem() async {
        let core = ScriptedCoreClient()
        core.handler = { _ in throw CoreFailure(kind: .transient, message: "box is offline.") }
        let model = MemoryModel()
        model.core = core
        await model.load(daemonID: nil)
        #expect(model.problem == "No machine is online; the setting can change when one is.")
        #expect(core.commands.isEmpty)
        await model.load(daemonID: "box")
        #expect(model.problem == "box is offline." && model.draft == nil)
    }

    @Test func thePickersLeaveStrixOutAndAnotherAgentTakesItsDefaults() {
        let draft = MemoryDraft(Self.settings())
        let controls = draft.controls(catalog: Self.catalog)
        #expect(controls.providers.map(\.id) == ["claude-code", "codex"], "Strix cannot dream")
        #expect(controls.models.map(\.id) == ["opus", "sonnet"])
        #expect(controls.options.isEmpty && controls.accounts.isEmpty, "no provider options or accounts")
        let codex = draft.choosing(.provider("codex"), catalog: Self.catalog)
        #expect(codex.harness == "codex" && codex.model == "sol")
        #expect(codex.accountID.isEmpty, "an account belongs to the agent it was chosen for")
        #expect(codex.runOn == draft.runOn && codex.revision == draft.revision, "only the agent changes")
        let sonnet = draft.choosing(.model("sonnet"), catalog: Self.catalog)
        #expect(sonnet.model == "sonnet" && sonnet.effort == "low" && sonnet.accountID == "pa_work")
        let followDefault = draft.choosing(.account(""), catalog: Self.catalog)
        #expect(followDefault.accountID.isEmpty && followDefault.harness == "claude-code")
        let memo = MemoryControlsMemo()
        #expect(memo.controls(draft, catalog: Self.catalog) == controls)
        var edited = draft
        edited.instructions = "Only the instructions changed."
        #expect(memo.controls(edited, catalog: Self.catalog) == controls)
        #expect(memo.controls(codex, catalog: Self.catalog).models.map(\.id) == ["sol"])
    }

    @Test func theAccountPickerJudgesAccountsOnTheRunOnMachine() {
        let providers = ClientProvidersSlice.with {
            $0.groups = [
                .with {
                    $0.provider = "claude"
                    $0.providerName = "Claude"
                    $0.accounts = [
                        .with {
                            $0.id = "pa_work"
                            $0.label = "Work"
                            $0.included = true
                            $0.machines = [
                                .with {
                                    $0.daemonID = "here"
                                    $0.name = "here"
                                    $0.online = true
                                    $0.state = "signed_in"
                                }
                            ]
                        }
                    ]
                }
            ]
        }
        let draft = MemoryDraft(Self.settings())
        let controls = draft.controls(catalog: Self.catalog, providers: providers)
        #expect(controls.accounts.map(\.id) == ["pa_work"])
        #expect(controls.accounts.first?.ready == true, "signed in on the run-on machine")
    }

    @Test func aProjectsStateReadsInTheCoresWordsAndADreamStartsThere() async throws {
        let core = ScriptedCoreClient()
        var dreams = 0
        core.handler = { command in
            switch command.memory.action {
            case .status?:
                return .with {
                    $0.memoryStatus = .with {
                        $0.machine = "Studio"
                        $0.projects = [
                            .with {
                                $0.projectID = "p_other"
                                $0.cards = 99
                            },
                            .with {
                                $0.projectID = "p_one"
                                $0.enabled = true
                                $0.cards = 12
                                $0.saved = dreams == 0 ? 1 : 2
                                $0.backlog = 2
                                $0.lastDreamAt = "2026-11-25T10:00:00Z"
                                $0.nextDream = "dreams run on far"
                            },
                        ]
                    }
                }
            case .startDream?:
                dreams += 1
                return .with {
                    $0.memoryDream = .with {
                        $0.cardID = "c_dream"
                        $0.status = "running"
                        $0.running = true
                        $0.title = "Dreaming…"
                        $0.dream = .with { $0.cardID = "c_dream" }
                    }
                }
            default: return .with { $0.done = ClientDone() }
            }
        }
        let model = MemoryModel()
        model.core = core
        await model.loadProject("p_one")
        #expect(core.commands.last?.memory.status.projectID == "p_one")
        let status = try #require(model.projects["p_one"]?.status)
        #expect(status.summary == "12 conversations indexed on Studio · 1 saved memory · 2 waiting to be indexed")
        let now = try #require(ISO8601DateFormatter().date(from: "2026-11-27T10:00:00Z"))
        #expect(status.dreams(now: now, machines: [Self.here, Self.far]) == "Last dream 2d ago · Dreams run on Studio")
        await model.startDream("p_one")
        let commands = core.commands.map(\.memory.action).compactMap { $0 }
        #expect(
            Array(commands.suffix(2)) == [
                .startDream(.with { $0.projectID = "p_one" }), .status(.with { $0.projectID = "p_one" }),
            ])
        let memory = try #require(model.projects["p_one"])
        #expect(memory.started?.cardID == "c_dream" && memory.started?.title == "Dreaming…")
        #expect(memory.started?.hasDream == false, "the form keeps the core's layout only")
        #expect(!memory.starting && memory.problem == nil)
        #expect(memory.status?.summary.contains("2 saved memories") == true, "the state is read again")
    }

    @Test func aProjectTheMachineHasNotIndexedReadsAsNothingIndexed() async throws {
        let core = ScriptedCoreClient()
        core.handler = { _ in .with { $0.memoryStatus = .with { $0.machine = "Studio" } } }
        let model = MemoryModel()
        model.core = core
        await model.loadProject("p_new")
        let status = try #require(model.projects["p_new"]?.status)
        #expect(status.summary == "0 conversations indexed on Studio · 0 saved memories")
        #expect(status.dreams(now: Date(), machines: []) == "No dream yet")
    }

    @Test func aRefusedDreamShowsWhyAndLeavesTheStateAsItWas() async {
        let core = ScriptedCoreClient()
        core.handler = { command in
            if case .startDream? = command.memory.action {
                throw CoreFailure(kind: .permanent, message: "A dream is awaiting review.")
            }
            return .with { $0.memoryStatus = .with { $0.machine = "Studio" } }
        }
        let model = MemoryModel()
        model.core = core
        await model.loadProject("p_one")
        await model.startDream("p_one")
        #expect(model.projects["p_one"]?.problem == "A dream is awaiting review.")
        #expect(model.projects["p_one"]?.starting == false && model.projects["p_one"]?.started == nil)
        #expect(core.commands.count == 2, "a refused dream changed nothing to read again")
        await model.startDream("")
        #expect(core.commands.count == 2, "no project, no command")
    }

    @Test func aConversationsSwitchAndDreamReviewGoToItsCard() async throws {
        let core = ScriptedCoreClient()
        let model = ConversationModel()
        model.core = core
        model.observe("c_card")
        defer { model.observe(nil) }
        try await model.setMemory(enabled: false)
        try await model.reviewDream(.apply)
        try await model.reviewDream(.discard)
        try await model.reviewDream(.undo)
        let card = ClientMemoryCardRef.with { $0.cardID = "c_card" }
        let commands = core.commands.map(\.memory.action).compactMap { $0 }
        #expect(
            commands == [
                .setEnabled(
                    .with {
                        $0.cardID = "c_card"
                        $0.enabled = false
                    }),
                .applyDream(card), .discardDream(card), .undoDream(card),
            ])
    }

    @Test func theChromeCarriesTheSwitchAndTheDreamsLayout() {
        let state = ClientConversationState.with {
            $0.memory = .with {
                $0.dreamer = true
                $0.enabled = true
                $0.dream = .with {
                    $0.cardID = "c_card"
                    $0.status = "staged"
                    $0.title = "Dream awaiting review"
                    $0.canApply = true
                    $0.canDiscard = true
                    $0.dream = .with { $0.added = 2 }
                }
            }
        }
        let chrome = ConversationChrome(state)
        #expect(chrome.memory?.dreamer == true && chrome.memory?.shown == false, "a dream shows no switch")
        #expect(chrome.memory?.dream.canApply == true && chrome.memory?.dream.title == "Dream awaiting review")
        #expect(chrome.memory?.dream.hasDream == false, "the machine's record is left out")
        #expect(ConversationChrome(ClientConversationState()).memory == nil, "unset until the card is known")
    }

    @Test func theCreationFormFollowsTheProjectsDefaultUntilTheUserChooses() {
        let form = CreationFormModel(chat: false)
        #expect(form.memory == false, "no preview yet: the project's default is unknown")
        form.memory = false
        #expect(form.intent.hasMemory && form.intent.memory == false)
        form.memory = true
        #expect(form.intent.memory == true && form.memory)
    }
}
