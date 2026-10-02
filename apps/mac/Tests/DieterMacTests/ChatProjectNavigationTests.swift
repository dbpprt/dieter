import Foundation
import DieterAPI
import DieterCore
import SharedCore
import SwiftUI
import Testing
@testable import DieterMac

/// The navigation edits the session sent the core, once queued edits ran.
@MainActor private func navigationCommands(_ core: ScriptedCoreClient, of store: DieterStore) async -> [ClientCommand
    .OneOf_Command]
{
    await store.navigationEditTail?.value
    return core.commands.compactMap(\.command)
}

/// The navigation intents the session sent the core.
@MainActor private func navigationEdits(_ core: ScriptedCoreClient, of store: DieterStore) async
    -> [ClientNavigationCommand.OneOf_Action]
{
    await navigationCommands(core, of: store).compactMap { command in
        if case .navigation(let edit) = command { edit.action } else { nil }
    }
}

@Test @MainActor func projectMovesGoToTheCoreAndItsOrderShows() async throws {
    let core = ScriptedCoreClient()
    let store = DieterStore(core: core, liveEnvironment: false)
    store.moveProject("p_three", before: "p_one", ungrouped: false)
    store.moveProject("p_two", before: nil, ungrouped: true)
    let sent = await navigationEdits(core, of: store)
    #expect(
        sent == [
            .moveProject(
                .with {
                    $0.projectID = "p_three"; $0.beforeProjectID = "p_one"
                }),
            .moveProject(
                .with {
                    $0.projectID = "p_two"; $0.ungrouped = true
                }),
        ])
    // The sidebar shows the order the core lays out, not one of its own.
    #expect(store.navigation.projects.order.isEmpty)
    store.foldNavigation(.with { $0.projects.order = ["p_three", "p_one", "p_two"] })
    #expect(store.navigation.projects.order == ["p_three", "p_one", "p_two"])
    #expect(await navigationEdits(core, of: store).count == 2, "showing the core sends nothing back")
}

@Test @MainActor func projectFolderEditsGoToTheCore() async throws {
    let core = ScriptedCoreClient()
    let store = DieterStore(core: core, liveEnvironment: false)
    store.createFolder(.projects, name: "Active work")
    store.moveToFolder(.projects, itemID: "p_one", folderID: "f_work")
    store.renameFolder(.projects, folderID: "f_work", name: "Client work")
    store.setFolderExpanded(.projects, folderID: "f_work", expanded: false)
    store.moveToFolder(.projects, itemID: "p_one", folderID: nil)
    store.deleteFolder(.projects, folderID: "f_work")
    let sent = await navigationEdits(core, of: store)
    #expect(
        sent == [
            .createFolder(
                .with {
                    $0.scope = .projects; $0.name = "Active work"
                }),
            .moveToFolder(
                .with {
                    $0.scope = .projects; $0.itemID = "p_one"; $0.folderID = "f_work"
                }),
            .renameFolder(
                .with {
                    $0.scope = .projects; $0.folderID = "f_work"; $0.name = "Client work"
                }),
            .setFolderExpanded(
                .with {
                    $0.scope = .projects; $0.folderID = "f_work"
                }),
            .moveToFolder(
                .with {
                    $0.scope = .projects; $0.itemID = "p_one"
                }),
            .deleteFolder(
                .with {
                    $0.scope = .projects; $0.folderID = "f_work"
                }),
        ])
}

@Test @MainActor func projectPinsGoToTheCore() async throws {
    let core = ScriptedCoreClient()
    let store = DieterStore(core: core, liveEnvironment: false)
    store.setProjectPinned("p_one", pinned: true)
    store.setProjectPinned("p_two", pinned: true)
    store.setProjectPinned("p_one", pinned: false)
    let sent = await navigationEdits(core, of: store).compactMap { edit -> String? in
        if case .pinProject(let pin) = edit { "\(pin.projectID) \(pin.pinned)" } else { nil }
    }
    #expect(sent == ["p_one true", "p_two true", "p_one false"])
    store.foldNavigation(.with { $0.projects.pinned = ["p_two"] })
    #expect(store.navigation.projects.pinned == ["p_two"])
    #expect(await navigationEdits(core, of: store).count == 3, "showing the core sends nothing back")
}

@Test @MainActor func chatFolderAndPinnedChatEditsGoToTheCore() async throws {
    let core = ScriptedCoreClient()
    let store = DieterStore(core: core, liveEnvironment: false)
    store.createFolder(.chats, name: "Research")
    store.moveToFolder(.chats, itemID: "c_one", folderID: "f_research")
    store.movePinnedChat("c_two", onto: "c_one")
    let sent = await navigationEdits(core, of: store)
    #expect(
        sent == [
            .createFolder(
                .with {
                    $0.scope = .chats; $0.name = "Research"
                }),
            .moveToFolder(
                .with {
                    $0.scope = .chats; $0.itemID = "c_one"; $0.folderID = "f_research"
                }),
            .movePinnedChat(
                .with {
                    $0.chatID = "c_two"; $0.targetChatID = "c_one"
                }),
        ])
}

@Test @MainActor func sharedProjectMachineBadgeRendersOnlineAndOfflineStates() {
    let machine = DieterEndpoint(
        name: "mini-home-workstation", host: "build.example", port: 443, daemonID: "build-mac", online: true)

    for online in [true, false] {
        let renderer = ImageRenderer(content: ProjectMachineBadge(machine: machine, online: online))
        renderer.proposedSize = .init(width: 100, height: 20)
        #expect(renderer.nsImage != nil)

        let compactMachineBadge = NSHostingView(
            rootView: ProjectMachineBadge(
                machine: machine, online: online, compact: true, alignsWithStatus: true))
        let boardMachineBadge = NSHostingView(
            rootView: ProjectMachineBadge(
                machine: machine, online: online, compact: false, alignsWithStatus: true))
        let runtimeBadge = NSHostingView(rootView: StatusPill(text: "idle", color: DieterTheme.subtle))
        #expect(abs(compactMachineBadge.fittingSize.height - runtimeBadge.fittingSize.height) < 1)
        #expect(abs(boardMachineBadge.fittingSize.height - runtimeBadge.fittingSize.height) < 1)
        #expect(boardMachineBadge.fittingSize.width > 72)
    }
}
