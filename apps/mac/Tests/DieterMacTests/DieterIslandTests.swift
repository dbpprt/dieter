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
    let now = Date(timeIntervalSince1970: 1_787_853_600) // 2026-08-27 18:00:00 UTC
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!

    func card(_ id: String, runtime: String, lane: String, updatedAt: String) -> Dieter_V1_Card {
        var card = Dieter_V1_Card()
        card.id = id; card.title = id; card.runtime = runtime; card.lane = lane; card.runtimeUpdatedAt = updatedAt
        return card
    }
    let activity = DieterIslandActivity.resolve(cards: [
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
    let store = DieterStore()

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
    #expect(notched.expandedSize(itemCount: 1) == CGSize(width: 600, height: 302))
    #expect(notched.expandedSize(itemCount: 4) == CGSize(width: 600, height: 430))

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
