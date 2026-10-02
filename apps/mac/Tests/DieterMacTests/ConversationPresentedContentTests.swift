import AppKit
import DieterAPI
import Foundation
@testable import MarkdownEngine
import SwiftUI
import SharedCore
import Testing
@testable import DieterMac

@Test @MainActor func presentationIsConsumedOncePerMachineAcrossUpdates() {
    let core = ScriptedCoreClient()
    let model = ConversationModel()
    model.core = core
    model.selectedCardID = "card"
    model.observe("card")
    defer { model.observe(nil) }
    var received: [String] = []
    model.onContentPresentation = { value, id in received.append("\(id):\(value.id)") }
    func present(_ id: String, path: String = "docs/plan.md", line: Int32 = 0, machine: String = "machine-A") {
        core.emitConversation("card", daemonID: machine) {
            $0.conversation.presentedContent.id = id
            $0.conversation.presentedContent.path = path
            $0.conversation.presentedContent.line = line
        }
    }
    present("first")
    present("first")
    #expect(received == ["card:first"])
    present("second", path: "source.swift", line: 42)
    #expect(model.conversation?.conversation.presentedContent.path == "source.swift")
    #expect(model.conversation?.conversation.presentedContent.line == 42)
    present("first")
    #expect(received == ["card:first", "card:second"])
    // Identity includes the machine that runs the conversation, even if card
    // and request IDs happen to match; returning to it still deduplicates.
    present("first", machine: "machine-B")
    present("first", machine: "machine-A")
    #expect(received == ["card:first", "card:second", "card:first"])
}

@Test @MainActor func unselectedPresentationCannotOpenAnotherConversationsWorkspace() {
    let core = ScriptedCoreClient()
    let model = ConversationModel()
    model.core = core
    model.selectedChatID = "card"
    model.observe("card")
    defer { model.observe(nil) }
    var received: [String] = []
    model.onContentPresentation = { value, _ in received.append(value.id) }
    core.emitConversation("card") {
        $0.conversation.presentedContent.id = "open-plan"
        $0.conversation.presentedContent.path = "docs/plan.md"
    }
    #expect(received == ["open-plan"])
    model.selectedChatID = "other"
    core.emitConversation("card") {
        $0.conversation.presentedContent.id = "late"
        $0.conversation.presentedContent.path = "private.md"
    }
    #expect(received == ["open-plan"])
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
