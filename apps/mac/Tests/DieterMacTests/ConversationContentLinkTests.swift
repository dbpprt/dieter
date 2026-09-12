import Foundation
import Testing
@testable import DieterMac

@Suite struct ConversationContentLinkTests {
    private let root = "/remote/worktrees/task"

    @Test(arguments: [
        ("docs/plan.md", "docs/plan.md", nil as Int?),
        ("./docs/Plan%20draft.md", "docs/Plan draft.md", nil),
        ("Sources/Feature.swift#L12", "Sources/Feature.swift", 12),
        ("Sources/Feature.swift#L12-L14", "Sources/Feature.swift", 12),
        ("Sources/Feature.swift:12:3", "Sources/Feature.swift", 12),
        ("README.md:4", "README.md", 4),
        ("Sources/Feature.swift:12#L18", "Sources/Feature.swift", 18),
        ("docs/plan.md#implementation", "docs/plan.md", nil),
        ("docs/part%231.md", "docs/part#1.md", nil),
        ("docs/version%3A12", "docs/version:12", nil),
    ])
    func resolvesWorkspaceLinks(example: (String, String, Int?)) throws {
        let url = try #require(URL(string: example.0))
        #expect(
            try ConversationContentLink.resolve(url, workspaceRoot: root) == .file(path: example.1, line: example.2))
    }

    @Test(arguments: [
        "/remote/worktrees/task/docs/plan.md",
        "file:///remote/worktrees/task/docs/plan.md",
        "file://localhost/remote/worktrees/task/docs/plan.md",
    ])
    func acceptsAbsoluteFilesInsideTheConversationWorkspace(link: String) throws {
        let url = try #require(URL(string: link))
        #expect(try ConversationContentLink.resolve(url, workspaceRoot: root) == .file(path: "docs/plan.md", line: nil))
    }

    @Test func resolvesNestedDocumentLinksWithoutUsingTheClientFilesystem() throws {
        let sibling = try #require(URL(string: "../design/plan.md#L9"))
        #expect(
            try ConversationContentLink.resolve(sibling, workspaceRoot: root, relativeTo: "docs/notes/overview.md")
                == .file(path: "docs/design/plan.md", line: 9))

        let fragment = try #require(URL(string: "#L3"))
        #expect(
            try ConversationContentLink.resolve(fragment, workspaceRoot: root, relativeTo: root + "/docs/plan.md")
                == .file(path: "docs/plan.md", line: 3))
    }

    @Test func preservesCompleteWebURLsEvenWithoutAnAvailableWorkspace() throws {
        let url = try #require(URL(string: "https://example.com/path?q=task%20plan#details"))
        #expect(try ConversationContentLink.resolve(url, workspaceRoot: "") == .web(url))
    }

    @Test(arguments: [
        "../secret.txt",
        "docs/../../secret.txt",
        "%2E%2E/secret.txt",
        "docs/%2E%2E/%2E%2E/secret.txt",
        "/remote/worktrees/task-other/secret.txt",
        "/remote/worktrees/task/../other/secret.txt",
        "file:///Users/local/secret.txt",
    ])
    func rejectsLinksOutsideTheConversationWorkspace(link: String) throws {
        let url = try #require(URL(string: link))
        #expect(throws: ConversationContentLink.ResolutionError.outsideWorkspace) {
            try ConversationContentLink.resolve(url, workspaceRoot: root)
        }
    }

    @Test func rejectsAnOutsideDocumentBase() throws {
        let url = try #require(URL(string: "plan.md"))
        #expect(throws: ConversationContentLink.ResolutionError.outsideWorkspace) {
            try ConversationContentLink.resolve(url, workspaceRoot: root, relativeTo: "/other/docs/readme.md")
        }
    }

    @Test(arguments: ["file://other-host/remote/worktrees/task/plan.md", "//other-host/plan.md"])
    func rejectsFileLinksToAnotherMachine(link: String) throws {
        let url = try #require(URL(string: link))
        #expect(throws: ConversationContentLink.ResolutionError.unsupportedFileHost) {
            try ConversationContentLink.resolve(url, workspaceRoot: root)
        }
    }

    @Test(arguments: ["javascript:alert(1)", "data:text/html,test", "mailto:user@example.com", "vscode://file/plan.md"])
    func rejectsUnsupportedURLSchemes(link: String) throws {
        let url = try #require(URL(string: link))
        #expect(throws: ConversationContentLink.ResolutionError.unsupportedScheme(try #require(url.scheme))) {
            try ConversationContentLink.resolve(url, workspaceRoot: root)
        }
    }

    @Test(arguments: [
        "file.swift:0", "file.swift:12:0", "file.swift#L0", "file.swift#L12-L2", "file.swift:9999999999999999999999",
    ])
    func rejectsInvalidLineReferences(link: String) throws {
        let url = try #require(URL(string: link))
        #expect(throws: ConversationContentLink.ResolutionError.invalidLine) {
            try ConversationContentLink.resolve(url, workspaceRoot: root)
        }
    }

    @Test func rejectsMissingWorkspaceAndMalformedWebLinks() throws {
        let file = try #require(URL(string: "docs/plan.md"))
        #expect(throws: ConversationContentLink.ResolutionError.invalidWorkspace) {
            try ConversationContentLink.resolve(file, workspaceRoot: "")
        }
        let web = try #require(URL(string: "https:example.com"))
        #expect(throws: ConversationContentLink.ResolutionError.invalidWebURL) {
            try ConversationContentLink.resolve(web, workspaceRoot: root)
        }
    }

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
}
