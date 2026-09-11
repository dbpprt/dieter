import AppKit
import DieterAPI
import SwiftUI
import Testing
@testable import DieterMac

@Test func recognizesPipeTableWithoutSurroundingBlankLines() throws {
    let blocks = ConversationMarkdownParser.parse(
        """
        Snapshot at 21:33 CEST:
        | Node | CPU | GPU | Unified RAM |
        |---|---:|:---:|---|
        | gx10-c674 | ~6% | 96% | 115.7 GiB |
        | gx10-d6c4 | ~10% | 96% | 114.8 GiB |
        Available RAM remains low.
        """
    )

    #expect(blocks.count == 3)
    #expect(blocks[0] == .paragraph("Snapshot at 21:33 CEST:"))
    let table = try #require(
        {
            if case .table(let value) = blocks[1] { return value }
            return nil
        }())
    #expect(table.headers == ["Node", "CPU", "GPU", "Unified RAM"])
    #expect(table.alignments == [.leading, .trailing, .center, .leading])
    #expect(table.rows.first == ["gx10-c674", "~6%", "96%", "115.7 GiB"])
    #expect(blocks[2] == .paragraph("Available RAM remains low."))
}

@Test func pipeTableParserKeepsEscapedAndCodeSpanPipesInsideCells() {
    #expect(
        ConversationMarkdownParser.tableCells("| name | a\\|b | `x|y` |") == ["name", "a|b", "`x|y`"]
    )
}

@Test @MainActor func narrowConversationMarkdownTableRenders() {
    let view = ConversationMarkdownView(
        source: """
            | Node | CPU | GPU | Unified RAM |
            |---|---:|---:|---|
            | gx10-c674 | ~6% | 96% | 115.7 / 121.6 GiB (95.2%) |
            """,
        inUserBubble: false
    )
    .frame(width: 320)

    _ = try? ConversationRenderCache.prepare(
        """
        | Node | CPU | GPU | Unified RAM |
        |---|---:|---:|---|
        | gx10-c674 | ~6% | 96% | 115.7 / 121.6 GiB (95.2%) |
        """)
    let renderer = ImageRenderer(content: view)
    renderer.proposedSize = .init(width: 320, height: 180)
    #expect(renderer.nsImage != nil)
}

@Test @MainActor func wrappedConversationMarkdownReportsItsFullHeightAfterWidthChanges() throws {
    let source = (1...6).map { index in
        "Paragraph \(index) includes a long linked phrase about [responsive conversation layout](https://example.com/layout) so it must wrap at the narrow width."
    }.joined(separator: "\n\n")
    _ = try ConversationRenderCache.prepare(source)

    func renderedHeight(width: CGFloat) throws -> CGFloat {
        let renderer = ImageRenderer(
            content: ConversationMarkdownView(source: source, inUserBubble: false)
                .frame(width: width)
        )
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)
        return try #require(renderer.nsImage).size.height
    }

    let wideHeight = try renderedHeight(width: 720)
    let narrowHeight = try renderedHeight(width: 320)
    #expect(narrowHeight > wideHeight + 80)
}

@Test @MainActor func wrappedFinalMessageReservesSpaceBeforeItsPlan() throws {
    let source = """
        The isolated smoke harness could not connect to its disposable daemon, failing before UI setup with
        `GRPCCore.RPCError 1`; the same infrastructure failure occurred before and after the fix. Existing
        unrelated worktree changes were preserved.
        """
    _ = try ConversationRenderCache.prepare(source)

    var phase = Dieter_V1_TaskPlanPhase()
    phase.tasks = [
        task("Reproduce and isolate the overlapping timeline and navigation-size jump"),
        task("Implement focused SwiftUI/state fixes without disturbing existing worktree changes"),
        task("Run targeted tests/build and verify the packaged app UI"),
    ]
    var plan = Dieter_V1_TaskPlan()
    plan.id = "overlap-regression"
    plan.phases = [phase]

    func renderedHeight<Content: View>(_ content: Content, width: CGFloat) throws -> CGFloat {
        let renderer = ImageRenderer(content: content.frame(width: width))
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)
        return try #require(renderer.nsImage).size.height
    }

    let width: CGFloat = 720
    let messageHeight = try renderedHeight(
        ConversationMarkdownView(source: source, inUserBubble: false),
        width: width
    )
    let planHeight = try renderedHeight(TaskPlanView(plan: plan), width: width)
    let combinedHeight = try renderedHeight(
        VStack(spacing: 15) {
            ConversationMarkdownView(source: source, inUserBubble: false)
            TaskPlanView(plan: plan)
        },
        width: width
    )

    #expect(combinedHeight >= messageHeight + planHeight + 14)
}

private func task(_ content: String) -> Dieter_V1_TaskPlanItem {
    var item = Dieter_V1_TaskPlanItem()
    item.content = content
    item.status = "completed"
    return item
}
