import DieterAPI
import DieterClientAPI
import Foundation
import Testing

@testable import DieterMacKit

/// The synced folders view model over a scripted core: it folds the list and the selected
/// folder's surface, its commands carry what the person chose, and it learns which folders the
/// daemon on this Mac keeps (with their paths) from that daemon.
@MainActor
struct FoldersModelTests {
    private func row(_ id: String, _ name: String, attention: Bool = false) -> ClientFolderRow {
        .with {
            $0.id = id
            $0.name = name
            $0.status = "Up to date"
            $0.attention = attention
        }
    }

    @Test func itFoldsTheListAndTheSelectedFolder() {
        let core = ScriptedCoreClient()
        let model = FoldersModel(scope: "test-folders")
        model.attach(core)
        model.attach(core)
        #expect(core.isObserved(.folders, scope: "test-folders"))

        core.emit(.folders, scope: "test-folders") {
            $0.folders = .with { $0.folders = [row("f1", "Inbox", attention: true), row("f2", "Reports")] }
        }
        #expect(model.list.folders.map(\.name) == ["Inbox", "Reports"])
        #expect(model.attention == 1)

        model.select("f1")
        #expect(core.isObserved(.folder, scope: "f1"), "a folder's surface is scoped by its ID")
        core.emit(.folder, scope: "f1") {
            $0.folder = .with {
                $0.id = "f1"; $0.found = true; $0.name = "Inbox"
                $0.members = [
                    .with {
                        $0.memberID = "mini"; $0.name = "Mac mini"; $0.daemon = true
                    }
                ]
            }
        }
        #expect(model.detail?.members.map(\.name) == ["Mac mini"])

        model.select("f2")
        #expect(model.detail == nil && !core.isObserved(.folder, scope: "f1"))
    }

    @Test func commandsCarryThePersonsChoices() async {
        let core = ScriptedCoreClient()
        let model = FoldersModel(scope: "test-folders")
        model.attach(core)
        core.handler = { command in
            switch command.folders.action {
            case .create?:
                .with {
                    $0.syncedFolder = .with {
                        $0.id = "f9"; $0.name = "Inbox"
                    }
                }
            case .attachDaemon(let attach)?:
                .with {
                    $0.folderAttach = .with {
                        $0.dryRun = attach.dryRun
                        $0.newFiles = 2
                        $0.member = .with { $0.path = attach.path }
                    }
                }
            case .updateDaemon?:
                .with {
                    $0.folderMember = .with {
                        $0.path = "/Users/me/Inbox"; $0.paused = true
                    }
                }
            default: .with { $0.done = ClientDone() }
            }
        }
        let created = await model.create(name: "Inbox", projectID: "p1", daemonID: "")
        #expect(created == "f9" && model.selectedID == "f9")

        let plan = await model.attachDaemon(
            folderID: "f9", daemonID: "mini", path: "/Users/me/Inbox", mode: .twoWay, join: .merge, dryRun: true)
        #expect(plan?.newFiles == 2)
        #expect(model.member(folderID: "f9", daemonID: "mini") == nil, "a plan attaches nothing")
        _ = await model.attachDaemon(
            folderID: "f9", daemonID: "mini", path: "/Users/me/Inbox", mode: .twoWay, join: .merge, dryRun: false)
        #expect(model.member(folderID: "f9", daemonID: "mini")?.path == "/Users/me/Inbox")

        await model.updateDaemon(folderID: "f9", daemonID: "mini") { $0.paused = true }
        #expect(model.member(folderID: "f9", daemonID: "mini")?.paused == true)
        await model.update(folderID: "f9", rules: ["-*.tmp"], trashDays: -1)
        await model.resolveDeletions(folderID: "f9", daemonID: "mini", apply: false)
        model.select("f9")
        await model.listTrash(daemonID: "mini")

        let commands = core.commands.map(\.folders)
        #expect(commands[0].create.name == "Inbox" && commands[0].create.projectID == "p1")
        #expect(commands[1].attachDaemon.dryRun && commands[1].attachDaemon.join == .merge)
        #expect(!commands[2].attachDaemon.dryRun && commands[2].attachDaemon.daemonID == "mini")
        #expect(commands[3].updateDaemon.hasPaused && !commands[3].updateDaemon.hasMode, "unset fields stay")
        #expect(commands[4].update.setRules && commands[4].update.rules == ["-*.tmp"])
        #expect(commands[4].update.trashDays == -1 && !commands[4].update.hasName)
        #expect(commands[5].resolveDeletions.daemonID == "mini" && !commands[5].resolveDeletions.apply)
        #expect(commands[6].scope == "f9" && commands[6].listTrash.daemonID == "mini", "trash pages fill the surface")
    }

    @Test func itLearnsWhichFoldersTheDaemonOnThisMacKeeps() async {
        let core = ScriptedCoreClient()
        let model = FoldersModel(scope: "test-folders")
        model.attach(core)
        core.emit(.folders, scope: "test-folders") {
            $0.folders = .with { $0.folders = [row("f1", "Inbox"), row("f2", "Reports")] }
        }
        core.handler = { command in
            guard command.folders.updateDaemon.folderID == "f1" else {
                throw CoreFailure(kind: .permanent, message: "That folder is not on this machine.")
            }
            return .with {
                $0.folderMember = .with {
                    $0.path = "/Users/me/Dieter/Inbox"; $0.concurrency = 4
                }
            }
        }
        await model.refreshLocal(daemonID: "mini")
        let reads = core.commands.map(\.folders.updateDaemon)
        #expect(reads.map(\.folderID) == ["f1", "f2"])
        #expect(reads.allSatisfy { !$0.hasMode && !$0.hasPaused && !$0.hasConcurrency }, "a read changes nothing")
        #expect(model.member(folderID: "f1", daemonID: "mini")?.path == "/Users/me/Dieter/Inbox")
        #expect(model.notOnThisMac == ["f2"])
        #expect(model.errorMessage == nil)

        core.handler = { _ in throw CoreFailure(kind: .transient, message: "No machine is reachable.") }
        await model.refreshLocal(daemonID: "mini")
        #expect(model.errorMessage == "No machine is reachable.")
        #expect(model.notOnThisMac == ["f2"], "an unreachable daemon changes no membership")
    }

    @Test func browsingAMembersCopyBindsFilesToTheFolderOnThatMachine() async {
        let core = ScriptedCoreClient()
        let files = FilesModel()
        files.bind(target: .init(endpointID: "https://gateway:443#mini", projectID: "", folderID: "f1"), core: core)
        // The bind is queued; a load runs after it.
        await files.loadFiles()
        let bind = core.commands.compactMap { command -> ClientFilesTarget? in
            guard case .bind(let target)? = command.files.action else { return nil }
            return target
        }
        #expect(bind.count == 1)
        #expect(bind.first?.daemonID == "mini" && bind.first?.folderID == "f1")
        #expect(bind.first?.projectID.isEmpty == true, "the folder member is the root, not a project")
    }

    @Test func onlyAnExistingLocalDirectoryIsRevealed() {
        #expect(FileExternalActions.localDirectory(verifiedLocal: true, path: "relative/path") == nil)
        #expect(FileExternalActions.localDirectory(verifiedLocal: true, path: "/definitely/missing/dir") == nil)
        let temporary = FileManager.default.temporaryDirectory.path
        #expect(
            FileExternalActions.localDirectory(verifiedLocal: false, path: temporary) == nil, "only this Mac's copy")
        #expect(FileExternalActions.localDirectory(verifiedLocal: true, path: temporary) != nil)
    }
}
