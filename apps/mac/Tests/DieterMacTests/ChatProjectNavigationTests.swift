import Foundation
import DieterCore
import SwiftUI
import Testing
@testable import DieterMac

@Test @MainActor func projectOrderIsSharedThroughTheAppSessionAndPersisted() throws {
    let suite = "dieter-chat-project-navigation-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = DieterStore(environment: .testing(defaults: defaults), restoreSync: false)

    var navigation = store.sidebarProjectNavigation
    let moved = navigation.move("p_three", before: "p_one", availableIDs: ["p_one", "p_two", "p_three"])
    #expect(moved)
    store.sidebarProjectNavigation = navigation

    #expect(
        store.sidebarProjectNavigation.orderedIDs(from: ["p_one", "p_two", "p_three"]) == [
            "p_three", "p_one", "p_two",
        ])
    #expect(SidebarProjectNavigationPreferences.load(from: defaults) == store.sidebarProjectNavigation)
}

@Test @MainActor func projectFoldersAreSharedThroughTheAppSessionAndPersisted() throws {
    let suite = "dieter-project-folder-navigation-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = DieterStore(environment: .testing(defaults: defaults), restoreSync: false)

    var folders = store.sidebarProjectFolders
    let createdFolderID = folders.createFolder(named: "Active work")
    let folderID = try #require(createdFolderID)
    let moved = folders.moveItem("p_one", to: folderID)
    #expect(moved)
    store.sidebarProjectFolders = folders

    #expect(
        NavigationFolderPreferences.load(scope: .projects, from: defaults)
            == store.sidebarProjectFolders
    )
}

@Test @MainActor func chatFoldersAreSharedThroughTheAppSessionAndPersisted() throws {
    let suite = "dieter-chat-folder-navigation-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = DieterStore(environment: .testing(defaults: defaults), restoreSync: false)

    var folders = store.allChatsFolders
    let createdFolderID = folders.createFolder(named: "Research")
    let folderID = try #require(createdFolderID)
    let moved = folders.moveItem("c_one", to: folderID)
    #expect(moved)
    store.allChatsFolders = folders

    #expect(
        NavigationFolderPreferences.load(scope: .chats, from: defaults)
            == store.allChatsFolders
    )
}

@Test @MainActor func sharedProjectMachineBadgeRendersOnlineAndOfflineStates() {
    let machine = DieterEndpoint(
        name: "Build Mac", host: "build.example", port: 443, daemonID: "build-mac", online: true)

    for online in [true, false] {
        let renderer = ImageRenderer(content: ProjectMachineBadge(machine: machine, online: online))
        renderer.proposedSize = .init(width: 100, height: 20)
        #expect(renderer.nsImage != nil)
    }
}
