import AppKit
import Testing
@testable import DieterMac

@Test @MainActor func readingPositionExcludesRowsBehindTheComposer() throws {
    let fixture = HistoryAnchorFixture()
    for index in 0..<10 {
        _ = fixture.row(id: "message-\(index)", y: CGFloat(index) * 180, height: 180)
    }
    fixture.scroll(to: 758)
    #expect(fixture.scrollView.contentInsets.bottom == 80)
    let position = try #require(fixture.controller.capture())
    // Row 6 intersects the native viewport but lies entirely under its 80pt
    // composer inset. Only readable rows can anchor the reader.
    #expect(position.anchors.map(\.messageIDs) == [["message-4"], ["message-5"]])
    #expect(abs(position.anchors[0].top + 38) < 1)
    #expect(abs(position.anchors[1].top - 142) < 1)
}

@Test @MainActor func heldReadingPositionSurvivesWindowReplacementInsideTheLayoutPass() throws {
    let fixture = HistoryAnchorFixture()
    let rows = (0..<10).map { index in
        fixture.row(id: "message-\(index)", y: CGFloat(index) * 180, height: 180)
    }
    fixture.scroll(to: 758)
    #expect(!fixture.controller.isFollowing, "Scrolling away from the end stops following")
    fixture.controller.holdReadingPosition()

    // Replace the window around the reader: remove two oldest rows and add
    // a different-height older row. The visible row moves in the document.
    for row in rows.prefix(2) {
        fixture.controller.unregister(row)
        row.removeFromSuperview()
    }
    for row in rows.dropFirst(2) { row.frame.origin.y -= 230 }
    _ = fixture.row(id: "older-page", y: 0, height: 130)
    fixture.document.frame.size.height -= 230
    // No explicit restore: the document's frame change is the layout pass.
    #expect(abs(fixture.scrollView.contentView.bounds.minY - 528) < 1)
    let restored = try #require(fixture.controller.capture())
    #expect(restored.anchors.first?.messageIDs == ["message-4"])
    #expect(abs((restored.anchors.first?.top ?? 0) + 38) < 1)
}

@Test @MainActor func readingPositionUsesVisibleMessageInsideARegroupedExpandedActivity() throws {
    let fixture = HistoryAnchorFixture()
    let group = fixture.row(id: "message-0", y: 0, height: 1000)
    fixture.controller.register(group, messageIDs: (0..<10).map { "message-\($0)" })
    let rows = (0..<10).map { index in
        let row = NSView(frame: NSRect(x: 0, y: CGFloat(index) * 100, width: 480, height: 100))
        group.addSubview(row)
        fixture.controller.register(row, messageIDs: ["message-\(index)"])
        return row
    }
    fixture.scroll(to: 235)
    let position = try #require(fixture.controller.capture())

    // Prepending activity changes the outer group identity and height, while
    // the message the user is reading keeps its own stable anchor.
    group.frame.size.height += 140
    for row in rows { row.frame.origin.y += 140 }
    fixture.controller.register(group, messageIDs: ["older-activity"] + (0..<10).map { "message-\($0)" })
    fixture.document.frame.size.height += 140
    #expect(fixture.controller.restore(position))
    #expect(abs(fixture.scrollView.contentView.bounds.minY - 375) < 1)
}

@Test @MainActor func followingPinsGrowthInsideTheLayoutPassUntilTheUserScrollsAway() throws {
    let fixture = HistoryAnchorFixture()
    _ = fixture.row(id: "message-0", y: 0, height: 1800)
    #expect(fixture.controller.isFollowing)
    fixture.document.frame.size.height += 300
    #expect(abs(fixture.scrollView.contentView.bounds.minY - (2100 - 400 + 80)) < 1)

    fixture.scroll(to: 900)
    #expect(!fixture.controller.isFollowing)
    fixture.document.frame.size.height += 300
    #expect(abs(fixture.scrollView.contentView.bounds.minY - 900) < 1, "A detached reader is never moved by growth")

    // Reaching the rendered end only rejoins the tail when it is the live end.
    fixture.controller.rendersLatest = false
    fixture.scroll(to: 2400 - 400 + 80)
    #expect(!fixture.controller.isFollowing)
    fixture.controller.rendersLatest = true
    fixture.scroll(to: 1900)
    fixture.scroll(to: 2400 - 400 + 80)
    #expect(fixture.controller.isFollowing)
}

@Test @MainActor func followingSurvivesNativeTailClampingAfterLayout() {
    let fixture = HistoryAnchorFixture()
    _ = fixture.row(id: "message-0", y: 0, height: 1800)
    fixture.document.frame.size.height += 300
    // AppKit can clamp to the document's end before applying the composer
    // inset. That layout adjustment must not detach a reader at the live tail.
    fixture.scrollView.contentView.scroll(to: NSPoint(x: 0, y: 2100 - 400))
    fixture.scrollView.reflectScrolledClipView(fixture.scrollView.contentView)
    #expect(fixture.controller.isFollowing)
    #expect(abs(fixture.scrollView.contentView.bounds.minY - (2100 - 400 + 80)) < 1)
    fixture.scroll(to: 900)
    #expect(!fixture.controller.isFollowing)
    #expect(abs(fixture.scrollView.contentView.bounds.minY - 900) < 1)
}

@MainActor private final class HistoryAnchorFixture {
    let controller = ConversationScrollController()
    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
    let document = FlippedHistoryView(frame: NSRect(x: 0, y: 0, width: 480, height: 1800))

    init() {
        scrollView.documentView = document
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 80, right: 0)
        scrollView.layoutSubtreeIfNeeded()
    }

    @discardableResult func row(id: String, y: CGFloat, height: CGFloat) -> NSView {
        let row = FlippedHistoryView(frame: NSRect(x: 0, y: y, width: 480, height: height))
        document.addSubview(row)
        controller.register(row, messageIDs: [id])
        return row
    }

    func scroll(to offset: CGFloat) {
        // User input arrives after the preceding layout pass has committed.
        // Flush its before-waiting observer before simulating the next gesture.
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.001))
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: offset))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}

private final class FlippedHistoryView: NSView {
    override var isFlipped: Bool { true }
}
