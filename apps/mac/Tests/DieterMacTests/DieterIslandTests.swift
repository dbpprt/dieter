import DieterAPI
import Foundation
import Testing
@testable import DieterMac

@Test func islandPreferenceDefaultsOnAndPersistsItsToggle() {
    let suite = "DieterIslandTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }

    #expect(DieterIslandPreferences.isEnabled(in: defaults))
    DieterIslandPreferences.setEnabled(false, in: defaults)
    #expect(!DieterIslandPreferences.isEnabled(in: defaults))
    DieterIslandPreferences.setEnabled(true, in: defaults)
    #expect(DieterIslandPreferences.isEnabled(in: defaults))
}

@Test func islandActivityCountsRunningReviewAndOnlyTodaysCompletedCards() {
    let now = Date(timeIntervalSince1970: 1_787_853_600)  // 2026-08-27 18:00:00 UTC
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!

    func card(_ id: String, runtime: String, lane: String, updatedAt: String) -> Dieter_V1_Card {
        var card = Dieter_V1_Card()
        card.id = id; card.title = id; card.runtime = runtime; card.lane = lane; card.runtimeUpdatedAt = updatedAt
        return card
    }
    let activity = DieterIslandActivity.resolve(
        cards: [
            card("running", runtime: "running", lane: "running", updatedAt: "2026-08-27T11:58:00Z"),
            card("review", runtime: "waiting_for_user", lane: "review", updatedAt: "2026-08-27T11:00:00Z"),
            card("done-today", runtime: "completed", lane: "done", updatedAt: "2026-08-27T09:00:00Z"),
            card("done-yesterday", runtime: "completed", lane: "done", updatedAt: "2026-08-26T09:00:00Z"),
        ], now: now, calendar: calendar)

    #expect(activity.runningCount == 1)
    #expect(activity.reviewCount == 1)
    #expect(activity.doneTodayCount == 1)
    #expect(activity.items.map(\.cardID) == ["running", "review", "done-today"])
}

@Test @MainActor func islandCardProjectionIncludesUnopenedProjectsAndOptimisticSelectedCards() {
    let store = DieterStore(restoreSync: false)

    func card(_ id: String, projectID: String, runtime: String) -> Dieter_V1_Card {
        var card = Dieter_V1_Card()
        card.id = id
        card.projectID = projectID
        card.runtime = runtime
        return card
    }

    let selected = card("selected", projectID: "p_selected", runtime: "running")
    let unopened = card("unopened", projectID: "p_unopened", runtime: "waiting_for_user")
    var optimisticSelected = selected
    optimisticSelected.runtime = "completed"
    store.navigationCards = [
        "p_selected": [selected],
        "p_unopened": [unopened],
    ]
    store.state.cards = [optimisticSelected]

    let projected = Dictionary(uniqueKeysWithValues: store.synchronizedCards.map { ($0.id, $0) })
    #expect(Set(projected.keys) == Set(["selected", "unopened"]))
    #expect(projected["selected"]?.runtime == "completed")
}

@Test func islandGeometryUsesTheNotchAndFallsBackToATopRightPill() {
    let screen = CGRect(x: 0, y: 0, width: 1_512, height: 982)
    let visible = CGRect(x: 0, y: 0, width: 1_512, height: 945)
    let notched = DieterIslandDisplayGeometry.resolve(
        screenFrame: screen,
        visibleFrame: visible,
        safeAreaTop: 32,
        auxiliaryLeftWidth: 656,
        auxiliaryRightWidth: 656
    )
    #expect(notched.hasPhysicalNotch)
    #expect(notched.notchWidth == 204)
    #expect(notched.windowFrame(expanded: false).midX == screen.midX)
    #expect(notched.windowFrame(expanded: false).maxY == screen.maxY)
    #expect(notched.collapsedSize == CGSize(width: 336, height: 42))
    #expect(notched.expandedSize(itemCount: 1) == CGSize(width: 600, height: 220))
    #expect(notched.expandedSize(itemCount: 4) == CGSize(width: 600, height: 412))

    let external = DieterIslandDisplayGeometry.resolve(
        screenFrame: screen,
        visibleFrame: visible,
        safeAreaTop: 0,
        auxiliaryLeftWidth: nil,
        auxiliaryRightWidth: nil
    )
    #expect(!external.hasPhysicalNotch)
    #expect(external.collapsedSize == CGSize(width: 270, height: 38))
    #expect(external.windowFrame(expanded: false).maxX == visible.maxX - 12)
    #expect(external.windowFrame(expanded: false).maxY == visible.maxY - 8)
}

@Test func islandExpandedHeightFitsItsRowsAndStaysBounded() {
    let empty = DieterIslandLayout.expandedSize(itemCount: 0)
    let one = DieterIslandLayout.expandedSize(itemCount: 1)
    let two = DieterIslandLayout.expandedSize(itemCount: 2)
    let four = DieterIslandLayout.expandedSize(itemCount: 4)
    #expect(empty == CGSize(width: 600, height: 248))
    #expect(one.height < empty.height)
    #expect(two.height - one.height == 64)
    #expect(four.height - two.height == 128)
    #expect(DieterIslandLayout.expandedSize(itemCount: -1) == empty)
    #expect(DieterIslandLayout.expandedSize(itemCount: 100) == four)

    let geometry = DieterIslandDisplayGeometry.resolve(
        screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
        safeAreaTop: 0, auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil)
    let shortFrame = geometry.windowFrame(expanded: true, activityItemCount: 1)
    let fullFrame = geometry.windowFrame(expanded: true, activityItemCount: 4)
    #expect(shortFrame.maxY == fullFrame.maxY)
    #expect(shortFrame.maxX == fullFrame.maxX)
}

@Test func islandPushRequiresHorizontalIntentAndKeepsBothEdgesOnExternalDisplay() {
    #expect(DieterIslandEdge.right.pushed(horizontal: -70, vertical: 4) == .left)
    #expect(DieterIslandEdge.left.pushed(horizontal: 70, vertical: 4) == .right)
    #expect(DieterIslandEdge.right.pushed(horizontal: -20, vertical: 0) == .right)
    #expect(DieterIslandEdge.right.pushed(horizontal: -70, vertical: 100) == .right)
    let geometry = DieterIslandDisplayGeometry.resolve(
        screenFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
        visibleFrame: CGRect(x: -1920, y: 40, width: 1920, height: 1015),
        safeAreaTop: 0, auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil)
    for expanded in [false, true] {
        let left = geometry.windowFrame(expanded: expanded, edge: .left)
        let right = geometry.windowFrame(expanded: expanded, edge: .right)
        #expect(left.minX == geometry.visibleFrame.minX + 12)
        #expect(right.maxX == geometry.visibleFrame.maxX - 12)
        #expect(left.maxY == right.maxY)
    }
    let notched = DieterIslandDisplayGeometry.resolve(
        screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
        safeAreaTop: 32, auxiliaryLeftWidth: 650, auxiliaryRightWidth: 650)
    #expect(notched.windowFrame(expanded: true, edge: .left) == notched.windowFrame(expanded: true, edge: .right))
}
