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

@Test func islandDisplayPreferenceSurvivesDisconnectAndResetsToAutomatic() {
    let suite = "DieterIslandDisplayTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let laptop = islandTestDisplay("laptop", frame: CGRect(x: 0, y: 0, width: 1512, height: 982), notched: true)
    let external = islandTestDisplay("external", frame: CGRect(x: -2560, y: 0, width: 2560, height: 1440))
    #expect(DieterIslandPreferences.displayID(in: defaults) == nil)
    DieterIslandPreferences.setDisplayID(external.id, in: defaults)
    #expect(
        DieterIslandDisplay.selected(
            preferredID: DieterIslandPreferences.displayID(in: defaults), displays: [laptop, external],
            mainDisplayID: laptop.id)?.id == external.id)

    // Unplugging temporarily falls back without forgetting the chosen monitor.
    #expect(
        DieterIslandDisplay.selected(
            preferredID: DieterIslandPreferences.displayID(in: defaults), displays: [laptop],
            mainDisplayID: laptop.id)?.id == laptop.id)
    #expect(DieterIslandPreferences.displayID(in: defaults) == external.id)
    #expect(
        DieterIslandDisplay.selected(
            preferredID: DieterIslandPreferences.displayID(in: defaults), displays: [external, laptop],
            mainDisplayID: laptop.id)?.id == external.id)

    DieterIslandPreferences.setDisplayID(nil, in: defaults)
    #expect(defaults.object(forKey: DieterIslandPreferences.displayKey) == nil)
    #expect(
        DieterIslandDisplay.selected(
            preferredID: DieterIslandPreferences.displayID(in: defaults), displays: [external, laptop],
            mainDisplayID: external.id)?.id == laptop.id)
    DieterIslandPreferences.setDisplayID(external.id, in: defaults)
    DieterIslandPreferences.setDisplayID("", in: defaults)
    #expect(DieterIslandPreferences.displayID(in: defaults) == nil)
}

@Test func islandAutomaticDisplayHandlesClamshellMissingMainAndNoScreens() {
    let left = islandTestDisplay("left", frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080))
    let right = islandTestDisplay("right", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
    #expect(
        DieterIslandDisplay.selected(preferredID: nil, displays: [left, right], mainDisplayID: right.id)?.id == right.id
    )
    #expect(
        DieterIslandDisplay.selected(preferredID: "disconnected", displays: [left, right], mainDisplayID: nil)?.id
            == left.id)
    #expect(DieterIslandDisplay.selected(preferredID: "disconnected", displays: [], mainDisplayID: right.id) == nil)
}

@Test func islandDisplayChoicesDisambiguateEqualMonitorNamesByIdentity() {
    let left = islandTestDisplay("left-lg", name: "LG HDR 4K", frame: CGRect(x: -3840, y: 0, width: 3840, height: 2160))
    let right = islandTestDisplay("right-lg", name: "LG HDR 4K", frame: CGRect(x: 0, y: 0, width: 3840, height: 2160))
    let laptop = islandTestDisplay(
        "laptop", name: "Built-in Retina Display", frame: CGRect(x: 0, y: -982, width: 1512, height: 982), notched: true
    )
    let titles = DieterIslandDisplay.titles(for: [left, right, laptop])
    #expect(titles[left.id] == "LG HDR 4K · Display 1")
    #expect(titles[right.id] == "LG HDR 4K · Display 2")
    #expect(titles[laptop.id] == "Built-in Retina Display")
    #expect(Set(titles.values).count == 3)
    #expect(
        DieterIslandDisplay.selected(preferredID: right.id, displays: [left, right, laptop], mainDisplayID: left.id)?.id
            == right.id)
}

@Test func islandDropFindsNegativeAndVerticallyStackedScreens() {
    let left = islandTestDisplay("left", frame: CGRect(x: -2560, y: 0, width: 2560, height: 1440))
    let main = islandTestDisplay("main", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
    let above = islandTestDisplay("above", frame: CGRect(x: 0, y: 1080, width: 1920, height: 1080))
    let below = islandTestDisplay("below", frame: CGRect(x: 0, y: -1080, width: 1920, height: 1080))
    let displays = [left, main, above, below]
    #expect(DieterIslandDisplay.containing(CGPoint(x: -1280, y: 720), in: displays)?.id == left.id)
    #expect(DieterIslandDisplay.containing(CGPoint(x: 960, y: 540), in: displays)?.id == main.id)
    #expect(DieterIslandDisplay.containing(CGPoint(x: 960, y: 1620), in: displays)?.id == above.id)
    #expect(DieterIslandDisplay.containing(CGPoint(x: 960, y: -540), in: displays)?.id == below.id)
    #expect(DieterIslandDisplay.containing(CGPoint(x: -1280, y: -540), in: displays) == nil)
    for display in displays {
        for expanded in [false, true] {
            let frame = display.geometry.windowFrame(expanded: expanded)
            #expect(display.geometry.screenFrame.contains(frame))
        }
    }
}

@Test func islandDragUsesItsInitialGlobalAnchorWithoutAccumulatingMovement() {
    let frame = CGRect(x: -540, y: 880, width: 270, height: 38)
    let drag = DieterIslandDrag(displayID: "left", frame: frame, pointer: CGPoint(x: -400, y: 900))
    let firstPoint = CGPoint(x: -100, y: 1050)
    let stackedDisplayPoint = CGPoint(x: 500, y: 1500)
    #expect(drag.frame(at: firstPoint) == CGRect(x: -240, y: 1030, width: 270, height: 38))
    #expect(drag.translation(to: firstPoint) == CGSize(width: 300, height: -150))
    for _ in 0..<10 {
        #expect(drag.frame(at: stackedDisplayPoint) == CGRect(x: 360, y: 1480, width: 270, height: 38))
        #expect(drag.frame(at: firstPoint) == CGRect(x: -240, y: 1030, width: 270, height: 38))
    }
    #expect(drag.translation(to: stackedDisplayPoint) == CGSize(width: 900, height: -600))
    #expect(drag.frame(at: drag.pointer) == frame)
    #expect(drag.displayID == "left")
}

private func islandTestDisplay(
    _ id: String, name: String = "External display", frame: CGRect, notched: Bool = false
) -> DieterIslandDisplay {
    DieterIslandDisplay(
        id: id, name: name,
        geometry: .resolve(
            screenFrame: frame,
            visibleFrame: CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height - 32),
            safeAreaTop: notched ? 32 : 0, auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil),
        isBuiltin: notched)
}
