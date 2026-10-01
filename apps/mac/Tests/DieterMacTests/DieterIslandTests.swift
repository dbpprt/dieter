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

@Test @MainActor func islandUsesInboxKindsOrderingAndFullCountsBeforeLimitingRows() {
    let store = DieterStore(restoreSync: false)
    store.activityRows = ["RECENT", "FAILED", "REVIEW", "UNREAD", "ANSWER", "RUNNING"].map { kind in
        .with {
            $0.card.id = kind
            $0.card.title = kind
            $0.card.scope = kind == "ANSWER" ? "chat" : "board"
            $0.kind = kind
            $0.detail = "Inbox detail for \(kind)"
        }
    }
    let activity = store.islandActivity
    #expect(activity.runningCount == 1)
    #expect(activity.attentionCount == 2)
    #expect(activity.recentCount == 3)
    #expect(activity.items.map(\.cardID) == ["RUNNING", "UNREAD", "ANSWER", "RECENT"])
    #expect(activity.items.map(\.kind) == [.running, .unread, .answer, .recent])
    #expect(activity.items[2].chat)
    #expect(activity.items[1].detail == "Inbox detail for UNREAD")
    // A seen response moves out of attention using the same core update as Inbox.
    store.activityRows[3].kind = "REVIEW"
    #expect(store.islandActivity.attentionCount == 1)
    #expect(store.islandActivity.recentCount == 4)
    store.activityRows = []
    #expect(store.islandActivity == .empty)
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
    #expect(notched.collapsedSize == CGSize(width: 356, height: 42))
    #expect(notched.expandedSize(itemCount: 1) == CGSize(width: 600, height: 258))
    #expect(notched.expandedSize(itemCount: 4) == CGSize(width: 600, height: 450))

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

@Test func islandContentClearsNotchesAcrossDisplayCoordinatesAndSafeAreaHeights() {
    for top: CGFloat in [32, 38, 48] {
        let geometry = DieterIslandDisplayGeometry.resolve(
            screenFrame: CGRect(x: -1512, y: 1080, width: 1512, height: 982),
            visibleFrame: CGRect(x: -1512, y: 1080, width: 1512, height: 930),
            safeAreaTop: top, auxiliaryLeftWidth: 646, auxiliaryRightWidth: 646)
        let collapsed = geometry.windowFrame(expanded: false)
        let notchLeft = geometry.screenFrame.midX - geometry.notchWidth / 2
        let notchRight = geometry.screenFrame.midX + geometry.notchWidth / 2
        #expect(collapsed.minX + DieterIslandLayout.collapsedWingWidth <= notchLeft)
        #expect(collapsed.maxX - DieterIslandLayout.collapsedWingWidth >= notchRight)
        for count in [0, 1, 4] {
            let expanded = geometry.windowFrame(expanded: true, activityItemCount: count)
            let contentTop = expanded.maxY - geometry.expandedTopInset
            #expect(contentTop < geometry.screenFrame.maxY - top)
            #expect(
                expanded.height - geometry.expandedTopInset == DieterIslandLayout.expandedSize(itemCount: count).height)
        }
    }
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
