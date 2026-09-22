import Foundation
import DieterCore
import SwiftUI
import Testing
@testable import DieterMac

@Test @MainActor func projectOrderIsSharedThroughTheAppSessionAndPersisted() throws {
    let suite = "dieter-chat-project-navigation-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("test-account", forKey: "DieterSharedKV.activeAccount")
    let environment = DieterAppEnvironment.testing(defaults: defaults)
    let store = DieterStore(environment: environment, restoreSync: false)

    var navigation = store.sidebarProjectNavigation
    let moved = navigation.move("p_three", before: "p_one", availableIDs: ["p_one", "p_two", "p_three"])
    #expect(moved)
    store.sidebarProjectNavigation = navigation

    #expect(
        store.sidebarProjectNavigation.orderedIDs(from: ["p_one", "p_two", "p_three"]) == [
            "p_three", "p_one", "p_two",
        ])
    #expect(
        DieterStore(environment: environment, restoreSync: false).sidebarProjectNavigation
            == store.sidebarProjectNavigation)
}

@Test @MainActor func projectFoldersAreSharedThroughTheAppSessionAndPersisted() throws {
    let suite = "dieter-project-folder-navigation-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("test-account", forKey: "DieterSharedKV.activeAccount")
    let environment = DieterAppEnvironment.testing(defaults: defaults)
    let store = DieterStore(environment: environment, restoreSync: false)

    var folders = store.sidebarProjectFolders
    let createdFolderID = folders.createFolder(named: "Active work")
    let folderID = try #require(createdFolderID)
    let moved = folders.moveItem("p_one", to: folderID)
    #expect(moved)
    store.sidebarProjectFolders = folders

    #expect(
        DieterStore(environment: environment, restoreSync: false).sidebarProjectFolders
            == store.sidebarProjectFolders
    )
}

@Test @MainActor func projectPinsAreSharedThroughTheAppSessionAndPersisted() throws {
    let suite = "dieter-project-pin-navigation-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("test-account", forKey: "DieterSharedKV.activeAccount")
    let environment = DieterAppEnvironment.testing(defaults: defaults)
    let store = DieterStore(environment: environment, restoreSync: false)

    var pins = store.pinnedProjectNavigation
    #expect(pins.setPinned("p_one", pinned: true))
    #expect(pins.setPinned("p_two", pinned: true))
    store.pinnedProjectNavigation = pins

    let restored = DieterStore(environment: environment, restoreSync: false)
    #expect(restored.pinnedProjectNavigation.projectOrder == ["p_one", "p_two"])

    pins = restored.pinnedProjectNavigation
    #expect(pins.setPinned("p_one", pinned: false))
    restored.pinnedProjectNavigation = pins
    #expect(
        DieterStore(environment: environment, restoreSync: false).pinnedProjectNavigation.projectOrder == ["p_two"])
}

@Test @MainActor func chatFoldersAreSharedThroughTheAppSessionAndPersisted() throws {
    let suite = "dieter-chat-folder-navigation-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("test-account", forKey: "DieterSharedKV.activeAccount")
    let environment = DieterAppEnvironment.testing(defaults: defaults)
    let store = DieterStore(environment: environment, restoreSync: false)

    var folders = store.allChatsFolders
    let createdFolderID = folders.createFolder(named: "Research")
    let folderID = try #require(createdFolderID)
    let moved = folders.moveItem("c_one", to: folderID)
    #expect(moved)
    store.allChatsFolders = folders

    #expect(
        DieterStore(environment: environment, restoreSync: false).allChatsFolders
            == store.allChatsFolders
    )
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
