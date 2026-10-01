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

@Test @MainActor func projectOrderIsSharedThroughTheCore() async throws {
    let core = ScriptedCoreClient()
    let store = DieterStore(core: core, restoreSync: false)
    var navigation = store.sidebarProjectNavigation
    let moved = navigation.move("p_three", before: "p_one", availableIDs: ["p_one", "p_two", "p_three"])
    #expect(moved)
    store.sidebarProjectNavigation = navigation
    #expect(
        store.sidebarProjectNavigation.orderedIDs(from: ["p_one", "p_two", "p_three"]) == [
            "p_three", "p_one", "p_two",
        ])
    let sent = await navigationCommands(core, of: store)
    guard case .setProjectOrder(let order) = sent.last else {
        Issue.record("expected a project order, sent \(sent)")
        return
    }
    #expect(order.projectIds == store.sidebarProjectNavigation.projectOrder)
    // What the core restores on the next launch shows as sent.
    let relaunched = DieterStore(core: ScriptedCoreClient(), restoreSync: false)
    relaunched.foldNavigation(.with { $0.projectOrder = order.projectIds })
    #expect(relaunched.sidebarProjectNavigation == store.sidebarProjectNavigation)
}

@Test @MainActor func projectFoldersAreSharedThroughTheCore() async throws {
    let core = ScriptedCoreClient()
    let store = DieterStore(core: core, restoreSync: false)
    var folders = store.sidebarProjectFolders
    let created = folders.createFolder(named: "Active work")
    let folderID = try #require(created)
    let moved = folders.moveItem("p_one", to: folderID)
    #expect(moved)
    store.sidebarProjectFolders = folders
    let sent = await navigationCommands(core, of: store)
    guard case .setFolders(let set) = sent.last else {
        Issue.record("expected folders, sent \(sent)")
        return
    }
    #expect(set.scope == .projects)
    #expect(set.folders.map(\.name) == ["Active work"] && set.folders.first?.itemIds == ["p_one"])
    let relaunched = DieterStore(core: ScriptedCoreClient(), restoreSync: false)
    relaunched.foldNavigation(.with { $0.projectFolders = set.folders })
    #expect(relaunched.sidebarProjectFolders == store.sidebarProjectFolders)
}

@Test @MainActor func projectPinsAreSharedThroughTheCore() async throws {
    let core = ScriptedCoreClient()
    let store = DieterStore(core: core, restoreSync: false)
    var pins = store.pinnedProjectNavigation
    let pinnedOne = pins.setPinned("p_one", pinned: true)
    let pinnedTwo = pins.setPinned("p_two", pinned: true)
    #expect(pinnedOne && pinnedTwo)
    store.pinnedProjectNavigation = pins
    let unpinned = pins.setPinned("p_one", pinned: false)
    #expect(unpinned)
    store.pinnedProjectNavigation = pins
    let sent = await navigationCommands(core, of: store).compactMap { command -> [String]? in
        if case .setPinnedProjects(let pinned) = command { pinned.projectIds } else { nil }
    }
    #expect(sent == [["p_one", "p_two"], ["p_two"]])
    // A fold from the core is mirrored without being sent back.
    store.foldNavigation(.with { $0.pinnedProjects = ["p_two"] })
    #expect(store.pinnedProjectNavigation.projectOrder == ["p_two"])
    #expect(await navigationCommands(core, of: store).count == 2)
}

@Test @MainActor func chatFoldersAreSharedThroughTheCore() async throws {
    let core = ScriptedCoreClient()
    let store = DieterStore(core: core, restoreSync: false)
    var folders = store.allChatsFolders
    let created = folders.createFolder(named: "Research")
    let folderID = try #require(created)
    let moved = folders.moveItem("c_one", to: folderID)
    #expect(moved)
    store.allChatsFolders = folders
    let sent = await navigationCommands(core, of: store)
    guard case .setFolders(let set) = sent.last else {
        Issue.record("expected folders, sent \(sent)")
        return
    }
    #expect(set.scope == .chats && set.folders.first?.itemIds == ["c_one"])
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
