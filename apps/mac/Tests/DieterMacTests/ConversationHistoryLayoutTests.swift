import AppKit
import Testing
@testable import DieterMac

@Test @MainActor func historyAnchorAtNewerEdgeExcludesRowsBehindTheComposer() throws {
    let fixture = HistoryAnchorFixture()
    for index in 0..<10 {
        _ = fixture.row(id: "message-\(index)", y: CGFloat(index) * 180, height: 180)
    }
    fixture.scroll(to: 758)
    #expect(fixture.scrollView.contentInsets.bottom == 80)
    let anchor = try #require(fixture.controller.capture(preferBottom: true))
    // Row 6 intersects the native viewport but lies entirely under its 80pt
    // composer inset. The last readable row is the one we preserve.
    #expect(anchor.messageID == "message-5")
    #expect(abs(anchor.offset - 142) < 1)
}

@Test @MainActor func historyAnchorPreservesPartialRowOffsetAcrossBoundedPageReplacement() throws {
    let fixture = HistoryAnchorFixture()
    let rows = (0..<10).map { index in
        fixture.row(id: "message-\(index)", y: CGFloat(index) * 180, height: 180)
    }
    fixture.scroll(to: 758)
    let anchor = try #require(fixture.controller.capture())
    #expect(anchor.messageID == "message-4")
    #expect(abs(anchor.offset + 38) < 1)

    // Replace the window around the reader: remove two oldest rows and add
    // a different-height older row. The visible row moves in the document.
    for row in rows.prefix(2) {
        fixture.controller.unregister(row)
        row.removeFromSuperview()
    }
    for row in rows.dropFirst(2) { row.frame.origin.y -= 230 }
    _ = fixture.row(id: "older-page", y: 0, height: 130)
    fixture.document.frame.size.height -= 230
    #expect(fixture.controller.restore(anchor))
    let restored = try #require(fixture.controller.capture())
    #expect(restored.messageID == anchor.messageID)
    #expect(abs(restored.offset - anchor.offset) < 1)
    #expect(abs(fixture.scrollView.contentView.bounds.minY - 528) < 1)
}

@Test @MainActor func historyAnchorUsesVisibleMessageInsideARegroupedExpandedActivity() throws {
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
    let anchor = try #require(fixture.controller.capture())
    #expect(anchor.messageID == "message-2")
    #expect(abs(anchor.offset + 35) < 1)

    // Prepending activity changes the outer group identity and height, while
    // the message the user is reading keeps its own stable anchor.
    group.frame.size.height += 140
    for row in rows { row.frame.origin.y += 140 }
    fixture.controller.register(group, messageIDs: ["older-activity"] + (0..<10).map { "message-\($0)" })
    fixture.document.frame.size.height += 140
    #expect(fixture.controller.restore(anchor))
    let restored = try #require(fixture.controller.capture())
    #expect(restored.messageID == anchor.messageID)
    #expect(abs(restored.offset - anchor.offset) < 1)
    #expect(abs(fixture.scrollView.contentView.bounds.minY - 375) < 1)
}

@MainActor private final class HistoryAnchorFixture {
    let controller = ConversationScrollAnchorController()
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
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: offset))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}

private final class FlippedHistoryView: NSView {
    override var isFlipped: Bool { true }
}
