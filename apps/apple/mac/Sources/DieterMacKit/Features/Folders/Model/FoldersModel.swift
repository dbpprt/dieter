import DieterAPI
import DieterClientAPI
import Foundation
import Observation

/// Synced folders as the shared core presents them: the list with each folder's status, and the
/// selected folder's members, trash and settings. The Mac keeps no copy of its own; a folder is on
/// this Mac only through the daemon running here, which the views call "This Mac". The core
/// lists, words and routes everything; this model folds its slices and sends its commands.
@MainActor @Observable
final class FoldersModel {
    /// Every folder that is not archived, with the daemons a folder can use.
    private(set) var list = ClientFoldersSlice()
    /// The selected folder, as its FOLDER surface (scoped by the folder ID) shows it.
    private(set) var detail: ClientFolderSlice?
    private(set) var selectedID: String?
    /// Why the last command failed; the views show it.
    var errorMessage: String?
    /// Daemon members as the member daemons describe themselves, with their path and limits.
    /// Only a member daemon knows its path, so it is read from that daemon on demand.
    private(set) var members: [MemberKey: Dieter_V1_FolderMember] = [:]
    /// Folders the daemon on this Mac reported it does not keep, after `refreshLocal`.
    private(set) var notOnThisMac: Set<String> = []
    private(set) var refreshingLocal = false
    @ObservationIgnored private var core: CoreClient?
    @ObservationIgnored private var listSubscription: SliceSubscription?
    @ObservationIgnored private var detailSubscription: SliceSubscription?
    @ObservationIgnored let scope: String
    /// The daemon on this Mac, so detaching it updates Settings at once.
    @ObservationIgnored private var localDaemonID: String?

    struct MemberKey: Hashable, Sendable {
        let folderID: String
        let daemonID: String
    }

    init(scope: String = "mac-folders") {
        self.scope = scope
    }

    /// Folders waiting for the person: conflicts, held deletions, a lost location.
    var attention: Int { list.folders.count(where: \.attention) }

    /// Observes the folder list.
    func attach(_ core: CoreClient) {
        guard listSubscription == nil else { return }
        self.core = core
        listSubscription = SliceSubscription(client: core, slice: .folders, scope: scope) { [weak self] update in
            guard let self, case .folders(let value) = update.value else { return }
            if self.list != value { self.list = value }
        }
    }

    /// Shows `folderID` (nil: none); its surface is scoped by the folder ID.
    func select(_ folderID: String?) {
        guard folderID != selectedID else { return }
        selectedID = folderID
        detail = nil
        detailSubscription = nil
        guard let folderID, let core else { return }
        detailSubscription = SliceSubscription(client: core, slice: .folder, scope: folderID) { [weak self] update in
            guard let self, case .folder(let value) = update.value else { return }
            self.foldDetail(value)
        }
    }

    private func foldDetail(_ value: ClientFolderSlice) {
        guard value.id == selectedID, detail != value else { return }
        detail = value
    }

    func member(folderID: String, daemonID: String) -> Dieter_V1_FolderMember? {
        members[MemberKey(folderID: folderID, daemonID: daemonID)]
    }

    // MARK: Shared definitions

    /// Creates a folder on `daemonID` (empty: any reachable daemon) and selects it.
    @discardableResult
    func create(name: String, projectID: String, daemonID: String) async -> String? {
        let result = await run { command in
            command.create = .with {
                $0.name = name
                $0.projectID = projectID
                $0.daemonID = daemonID
            }
        }
        guard case .syncedFolder(let folder)? = result?.result else { return nil }
        select(folder.id)
        return folder.id
    }

    /// Changes the shared definition; nil fields stay unchanged.
    @discardableResult
    func update(
        folderID: String, name: String? = nil, rules: [String]? = nil, trashDays: Int32? = nil,
        deleteGuard: Dieter_V1_FolderDeleteGuard? = nil, projectID: String? = nil
    ) async -> Bool {
        await run { command in
            command.update = .with {
                $0.folderID = folderID
                if let name { $0.name = name }
                if let rules {
                    $0.setRules = true
                    $0.rules = rules
                }
                if let trashDays { $0.trashDays = trashDays }
                if let deleteGuard { $0.deleteGuard = deleteGuard }
                if let projectID { $0.projectID = projectID }
            }
        } != nil
    }

    /// Stops every member; files stay where they are.
    @discardableResult
    func archive(folderID: String) async -> Bool {
        let done = await run { $0.archive = .with { $0.folderID = folderID } } != nil
        if done, selectedID == folderID { select(nil) }
        return done
    }

    // MARK: Daemon members

    /// Binds `path` on `daemonID`'s host to the folder; a dry run only plans the join.
    func attachDaemon(
        folderID: String, daemonID: String, path: String, mode: Dieter_V1_FolderMode, join: Dieter_V1_FolderJoin,
        dryRun: Bool
    ) async -> Dieter_V1_AttachFolderResult? {
        let result = await run { command in
            command.attachDaemon = .with {
                $0.folderID = folderID
                $0.daemonID = daemonID
                $0.path = path
                $0.mode = mode
                $0.join = join
                $0.dryRun = dryRun
            }
        }
        guard case .folderAttach(let attached)? = result?.result else { return nil }
        if !dryRun {
            members[MemberKey(folderID: folderID, daemonID: daemonID)] = attached.member
            notOnThisMac.remove(folderID)
        }
        return attached
    }

    /// Changes a daemon member's mode, pause or limits; unset fields stay unchanged.
    @discardableResult
    func updateDaemon(
        folderID: String, daemonID: String, _ change: (inout ClientFolderUpdateDaemon) -> Void
    ) async -> Bool {
        var update = ClientFolderUpdateDaemon()
        update.folderID = folderID
        update.daemonID = daemonID
        change(&update)
        let sent = update
        let result = await run { $0.updateDaemon = sent }
        guard case .folderMember(let member)? = result?.result else { return false }
        members[MemberKey(folderID: folderID, daemonID: daemonID)] = member
        return true
    }

    /// Reads a daemon member's own description (its path and limits): an update that changes
    /// nothing returns the member as that daemon keeps it.
    func readMember(folderID: String, daemonID: String) async throws -> Dieter_V1_FolderMember {
        guard let core else { throw CoreFailure(kind: .transient, message: "Dieter is not connected.") }
        var command = ClientFoldersCommand()
        command.updateDaemon = .with {
            $0.folderID = folderID
            $0.daemonID = daemonID
        }
        let sent = command
        let result = try await core.dispatch(.with { $0.folders = sent })
        guard case .folderMember(let member)? = result.result else {
            throw CoreFailure(kind: .permanent, message: "The machine did not describe its copy.")
        }
        members[MemberKey(folderID: folderID, daemonID: daemonID)] = member
        return member
    }

    /// Learns which folders the daemon on this Mac keeps, with their paths and limits. A folder
    /// it refuses to describe is not on this Mac; an unreachable daemon shows as the error.
    func refreshLocal(daemonID: String) async {
        guard !daemonID.isEmpty, !refreshingLocal else { return }
        localDaemonID = daemonID
        refreshingLocal = true
        defer { refreshingLocal = false }
        for row in list.folders {
            do {
                _ = try await readMember(folderID: row.id, daemonID: daemonID)
                notOnThisMac.remove(row.id)
            } catch let failure as CoreFailure where failure.kind != .transient {
                members[MemberKey(folderID: row.id, daemonID: daemonID)] = nil
                notOnThisMac.insert(row.id)
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }
    }

    /// Stops syncing on `daemonID`; its files stay on disk.
    @discardableResult
    func detachDaemon(folderID: String, daemonID: String) async -> Bool {
        let done =
            await run { command in
                command.detachDaemon = .with {
                    $0.folderID = folderID
                    $0.daemonID = daemonID
                }
            } != nil
        if done {
            members[MemberKey(folderID: folderID, daemonID: daemonID)] = nil
            if let local = localDaemonID, local == daemonID { notOnThisMac.insert(folderID) }
        }
        return done
    }

    func rescanDaemon(folderID: String, daemonID: String) async {
        await run { command in
            command.rescanDaemon = .with {
                $0.folderID = folderID
                $0.daemonID = daemonID
            }
        }
    }

    /// Applies (or undoes, restoring the files) the deletions a member's deletion guard holds.
    func resolveDeletions(folderID: String, daemonID: String, apply: Bool) async {
        await run { command in
            command.resolveDeletions = .with {
                $0.folderID = folderID
                $0.daemonID = daemonID
                $0.apply = apply
            }
        }
    }

    // MARK: Trash

    /// Reads a page of `daemonID`'s trash into the selected folder's surface.
    func listTrash(daemonID: String, after: String = "") async {
        guard let folderID = selectedID else { return }
        await run(scope: folderID) { command in
            command.listTrash = .with {
                $0.folderID = folderID
                $0.daemonID = daemonID
                $0.after = after
            }
        }
    }

    func restoreTrash(daemonID: String, ids: [String]) async {
        guard let folderID = selectedID, !ids.isEmpty else { return }
        await run(scope: folderID) { command in
            command.restoreTrash = .with {
                $0.folderID = folderID
                $0.daemonID = daemonID
                $0.ids = ids
            }
        }
    }

    /// Empty `ids` purge the daemon's whole trash of the folder.
    func purgeTrash(daemonID: String, ids: [String]) async {
        guard let folderID = selectedID else { return }
        await run(scope: folderID) { command in
            command.purgeTrash = .with {
                $0.folderID = folderID
                $0.daemonID = daemonID
                $0.ids = ids
            }
        }
    }

    /// Runs a command and folds the slice it returns; a failure becomes the error message. An
    /// empty scope reaches the surface of the folder the command names.
    @discardableResult
    private func run(scope: String = "", _ build: (inout ClientFoldersCommand) -> Void) async -> ClientResult? {
        guard let core else { return nil }
        var command = ClientFoldersCommand()
        command.scope = scope
        build(&command)
        let sent = command
        do {
            let result = try await core.dispatch(.with { $0.folders = sent })
            switch result.result {
            case .folder(let value)?: foldDetail(value)
            case .folders(let value)?: if list != value { list = value }
            default: break
            }
            if errorMessage != nil { errorMessage = nil }
            return result
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }
}
