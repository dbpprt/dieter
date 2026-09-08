import AppKit
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
    let table = try #require({
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
        ConversationMarkdownParser.tableCells("| name | a\\|b | `x|y` |") ==
            ["name", "a|b", "`x|y`"]
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

    _ = try? ConversationRenderCache.prepare("""
        | Node | CPU | GPU | Unified RAM |
        |---|---:|---:|---|
        | gx10-c674 | ~6% | 96% | 115.7 / 121.6 GiB (95.2%) |
        """)
    let renderer = ImageRenderer(content: view)
    renderer.proposedSize = .init(width: 320, height: 180)
    #expect(renderer.nsImage != nil)
}
