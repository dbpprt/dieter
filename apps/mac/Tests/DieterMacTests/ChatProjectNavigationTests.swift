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

@Test @MainActor func sharedProjectMachineBadgeRendersOnlineAndOfflineStates() {
    let machine = DieterEndpoint(
        name: "Build Mac", host: "build.example", port: 443, daemonID: "build-mac", online: true)

    for online in [true, false] {
        let renderer = ImageRenderer(content: ProjectMachineBadge(machine: machine, online: online))
        renderer.proposedSize = .init(width: 100, height: 20)
        #expect(renderer.nsImage != nil)
    }
}
