import Foundation
import Testing
@testable import DieterMac

@Suite struct ConversationContentLinkTests {
    private let root = "/remote/worktrees/task"

    @Test func resolvesTheURLProducedByConversationMarkdown() throws {
        let markdown = try AttributedString(
            markdown: "Read [the plan](docs/plan.md) and [the implementation](Sources/Feature.swift:12).",
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        let links = markdown.runs.compactMap(\.link)
        #expect(links.count == 2)
        #expect(
            try links.map { try ConversationContentLink.resolve($0, workspaceRoot: root) } == [
                .file(path: "docs/plan.md", line: nil),
                .file(path: "Sources/Feature.swift", line: 12),
            ])
    }

    @Test func failuresCarryTheCoresWording() throws {
        let url = try #require(URL(string: "javascript:alert(1)"))
        #expect(
            throws: ConversationContentLink.ResolutionError(
                message: "Links using javascript: cannot be opened in this pane.")
        ) {
            try ConversationContentLink.resolve(url, workspaceRoot: root)
        }
    }
}
