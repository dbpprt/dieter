import AppKit
import DieterAPI
import Foundation
@testable import MarkdownEngine
import SwiftUI
import Testing
@testable import DieterMac

private func presentedSnapshot(_ id: String, cardID: String = "card") -> Dieter_V1_ConversationSnapshot {
    var snapshot = Dieter_V1_ConversationSnapshot()
    snapshot.detail.card.id = cardID
    snapshot.conversation.cardID = cardID
    snapshot.conversation.presentedContent.id = id
    snapshot.conversation.presentedContent.path = "docs/plan.md"
    return snapshot
}

@Test @MainActor func presentationIsConsumedOnceAcrossReadsDeltasAndReconnects() async {
    let model = ConversationModel()
    model.bind(client: nil, endpointID: "machine-A")
    model.selectedCardID = "card"
    var received: [String] = []
    model.onContentPresentation = { value, id in received.append("\(id):\(value.id)") }
    let first = presentedSnapshot("first")
    await model.acceptConversation(first, chat: false)
    await model.acceptConversation(first, chat: false)
    var delta = Dieter_V1_ConversationUpdate()
    delta.presentedContent = first.conversation.presentedContent
    await model.applyConversationUpdate(delta, cardID: "card")
    #expect(received == ["card:first"])

    delta.presentedContent.id = "second"
    delta.presentedContent.path = "source.swift"
    delta.presentedContent.line = 42
    await model.applyConversationUpdate(delta, cardID: "card")
    #expect(model.conversation?.conversation.presentedContent.path == "source.swift")
    #expect(model.conversation?.conversation.presentedContent.line == 42)
    var replacement = Dieter_V1_ConversationUpdate()
    replacement.snapshot = first
    await model.applyConversationUpdate(replacement, cardID: "card")
    #expect(received == ["card:first", "card:second"])

    // Identity includes the authenticated machine, even if card/request IDs
    // happen to match. Reconnecting to the original machine still deduplicates.
    model.bind(client: nil, endpointID: "machine-B")
    await model.acceptConversation(first, chat: false)
    model.bind(client: nil, endpointID: "machine-A")
    await model.acceptConversation(first, chat: false)
    #expect(received == ["card:first", "card:second", "card:first"])
}

@Test @MainActor func cachedOrUnselectedPresentationCannotOpenAnotherConversationsWorkspace() async {
    let model = ConversationModel()
    model.bind(client: nil, endpointID: "machine")
    model.selectedChatID = "card"
    var received: [String] = []
    model.onContentPresentation = { value, _ in received.append(value.id) }
    let snapshot = presentedSnapshot("open-plan")
    await model.acceptConversation(snapshot, chat: true, cache: false)
    #expect(received.isEmpty)
    await model.acceptConversation(presentedSnapshot("other-request", cardID: "other"), chat: true)
    #expect(received.isEmpty)
    await model.acceptConversation(snapshot, chat: true)
    #expect(received == ["open-plan"])
    model.selectedChatID = "other"
    var delta = Dieter_V1_ConversationUpdate()
    delta.presentedContent.id = "late"
    delta.presentedContent.path = "private.md"
    await model.applyConversationUpdate(delta, cardID: "card")
    #expect(received == ["open-plan"])
}

@Test func presentedPathsAreEncodedAsFileNamesAndKeepTheirLine() throws {
    for path in ["docs/plan #1? 50%.md", "docs/note:12", "/remote/worktree/docs/plan #1.md"] {
        var value = Dieter_V1_ContentPresentation()
        value.path = path
        value.line = 17
        let url = try #require(ConversationPresentedContent.url(for: value))
        let link = try ConversationContentLink.resolve(url, workspaceRoot: "/remote/worktree")
        let expected = path.hasPrefix("/") ? "docs/plan #1.md" : path
        #expect(link == .file(path: expected, line: 17))
    }
}

@Test func malformedPresentationCannotBypassLinkRouting() {
    var value = Dieter_V1_ContentPresentation()
    #expect(ConversationPresentedContent.url(for: value) == nil)
    value.url = "javascript:alert(1)"
    #expect(ConversationPresentedContent.url(for: value) == nil)
    value.url = "https://example.com"
    #expect(ConversationPresentedContent.url(for: value)?.host == "example.com")
    value.path = "docs/plan.md"
    #expect(ConversationPresentedContent.url(for: value) == nil)
    value.url = ""
    value.line = -1
    #expect(ConversationPresentedContent.url(for: value) == nil)
}

@Test @MainActor func richMarkdownURLActivationUsesTheOwningPaneHandler() throws {
    let destination = try #require(URL(string: "../source.swift#L12"))
    var received: URL?
    let wrapper = NativeTextViewWrapper(
        text: .constant("A linked file"),
        onURLClick: { url in
            received = url; return true
        })
    let coordinator = wrapper.makeCoordinator()
    let text = NSTextView()
    text.string = "A linked file"
    text.isEditable = false
    #expect(coordinator.textView(text, clickedOnLink: destination, at: 4))
    #expect(received == destination)
    let unhandled = NativeTextViewWrapper(text: .constant("A linked file")).makeCoordinator()
    #expect(!unhandled.textView(text, clickedOnLink: destination, at: 4))
}

@Test func previewLinksKeepTheirLiteralHrefBeforeWorkspaceResolution() throws {
    let url = try #require(MarkdownPreviewNavigation.contentURL(href: "../guide.md#L12"))
    #expect(
        try ConversationContentLink.resolve(url, workspaceRoot: "/workspace", relativeTo: "docs/plan.md")
            == .file(path: "guide.md", line: 12))
    let sameFile = try #require(MarkdownPreviewNavigation.contentURL(href: "#L17"))
    #expect(
        try ConversationContentLink.resolve(sameFile, workspaceRoot: "/workspace", relativeTo: "docs/plan.md")
            == .file(path: "docs/plan.md", line: 17))
}

@Test @MainActor func richMarkdownStyledLinksPreserveTheirOriginalDestination() throws {
    for destination in ["../source.swift#L12", "sibling.md", "#L17", "https://example.com/docs"] {
        let source = "[View source](\(destination))"
        let storage = NSMutableAttributedString(string: source)
        for (range, attributes) in MarkdownASTStyler.styleAttributes(
            text: source, fontName: NSFont.systemFont(ofSize: 14).fontName, fontSize: 14
        ) {
            storage.addAttributes(attributes, range: range)
        }
        let index = (source as NSString).range(of: "source").location + 2
        let styledLink = try #require(storage.attribute(.link, at: index, effectiveRange: nil) as? URL)
        var received: URL?
        let coordinator = NativeTextViewWrapper(
            text: .constant(source),
            onURLClick: {
                received = $0; return true
            }
        ).makeCoordinator()
        let text = NSTextView()
        text.isEditable = false
        text.textStorage?.setAttributedString(storage)
        #expect(coordinator.textView(text, clickedOnLink: styledLink, at: index))
        let receivedURL = try #require(received)
        #expect(receivedURL.relativeString == destination)
        if destination == "../source.swift#L12" {
            #expect(
                try ConversationContentLink.resolve(
                    receivedURL, workspaceRoot: "/workspace", relativeTo: "docs/plan.md")
                    == .file(path: "source.swift", line: 12))
        }
        let unhandled = NativeTextViewWrapper(text: .constant(source)).makeCoordinator()
        #expect(!unhandled.textView(text, clickedOnLink: styledLink, at: index))
    }
}
