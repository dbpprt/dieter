import DieterClientAPI
import Foundation
import Observation

/// The agent memory setting as its settings form edits it: one account-wide
/// record every machine replicates. The adapter maps it to and from the
/// setting the core reads and saves.
struct MemoryDraft: Equatable, Sendable {
    /// Dreams start on their schedule; one can always start from a project.
    var dreaming = false
    var harness = ""
    var model = ""
    var effort = ""
    var accountID = ""
    /// The machine that runs dreams; empty: per project, the machine with
    /// most of its conversations.
    var runOn = ""
    var minHours = 0
    var minNewTasks = 0
    /// The local start window on the dreaming machine, "HH:MM-HH:MM"; empty: any time.
    var window = ""
    /// "auto" or "review".
    var apply = ""
    var maxOperations = 0
    var maxRetirePercent = 0
    var instructions = ""
    /// False while nobody saved the setting; the values are then the defaults.
    var configured = false
    /// The record revision the values were read at; a save is compare-and-set on it.
    var revision = ""
}

/// A project's memory state as the machine that answered reported it; the
/// core words it (`ProjectMemoryState.summary`, `dreams(now:machines:)`).
struct ProjectMemoryState: Equatable, Sendable {
    /// The machine that answered, by name.
    var machine = ""
    /// The project's state on that machine, encoded as the core reads it.
    var encoded = Data()
}

/// A project's memory as its settings show it: its state, and a dream
/// started from there.
struct ProjectMemory: Equatable, Sendable {
    /// Nil until the state arrives.
    var status: ProjectMemoryState?
    /// Why the state could not be read, or the dream not started.
    var problem: String?
    var starting = false
    /// The dream started from here, running or failed.
    var started: ClientMemoryDreamState?
}

/// Agent memory: Settings › Agent memory, the account's memory setting read
/// from and saved on one machine (`MemoryRules.machine`) whose catalog the
/// form's pickers show, and projects' memory state and dreams. The core
/// reads, checks and saves everything; this model keeps what the views show.
@MainActor @Observable final class MemoryModel {
    /// The setting as last read or saved, with the daemon's defaults shown; nil until it arrives.
    private(set) var saved: MemoryDraft?
    /// What the form shows and edits; every read or save replaces it.
    var draft: MemoryDraft?
    /// The machine the form reads and saves on; nil while none is available.
    private(set) var daemonID: String?
    /// Why the setting could not be read or saved, as the core says it.
    private(set) var problem: String?
    private(set) var loading = false
    private(set) var saving = false
    /// The last save went through; the form says so until the draft changes.
    private(set) var confirmed = false
    /// Project ID → its memory state and the dream started for it.
    private(set) var projects: [String: ProjectMemory] = [:]
    @ObservationIgnored var core: CoreClient?

    init() {}

    /// A save can go out: the draft is valid and differs from what was read,
    /// or shows defaults nobody saved yet.
    var canSave: Bool {
        guard let draft, let saved, daemonID != nil, !saving, draft.problem == nil else { return false }
        return draft.changed(from: saved)
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
            let result = try await core.dispatch { $0.memory.settings = .with { $0.daemonID = daemonID } }
            guard self.daemonID == daemonID else { return }
            show(MemoryDraft(result.memorySettings))
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
                $0.memory.updateSettings = .with {
                    $0.daemonID = daemonID
                    $0.settings = settings
                }
            }
            show(MemoryDraft(result.memorySettings))
            confirmed = true
            problem = nil
            return true
        } catch {
            problem = error.localizedDescription
            return false
        }
    }

    /// Reads `projectID`'s memory state, e.g. when its settings open.
    func loadProject(_ projectID: String) async {
        guard let core, !projectID.isEmpty else { return }
        do {
            let result = try await core.dispatch { $0.memory.status = .with { $0.projectID = projectID } }
            let status = ProjectMemoryState(result.memoryStatus, projectID: projectID)
            update(projectID) {
                $0.status = status
                $0.problem = nil
            }
        } catch {
            update(projectID) { $0.problem = error.localizedDescription }
        }
    }

    /// Starts a dream of `projectID` now; once the machine took it, the
    /// project's state is read again.
    func startDream(_ projectID: String) async {
        guard let core, !projectID.isEmpty, projects[projectID]?.starting != true else { return }
        update(projectID) {
            $0.starting = true
            $0.problem = nil
            $0.started = nil
        }
        do {
            let result = try await core.dispatch { $0.memory.startDream = .with { $0.projectID = projectID } }
            var dream = result.memoryDream
            // The form shows the core's layout, not the machine's record.
            dream.clearDream()
            update(projectID) {
                $0.started = dream
                $0.starting = false
            }
        } catch {
            update(projectID) {
                $0.problem = error.localizedDescription
                $0.starting = false
            }
            return
        }
        await loadProject(projectID)
    }

    private func show(_ settings: MemoryDraft) {
        saved = settings
        draft = settings
    }

    private func update(_ projectID: String, _ change: (inout ProjectMemory) -> Void) {
        var memory = projects[projectID] ?? ProjectMemory()
        change(&memory)
        if projects[projectID] != memory { projects[projectID] = memory }
    }
}
