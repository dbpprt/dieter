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

@Test @MainActor func presentationStaysConsumedAfterChatReopenAndAppRecreation() throws {
    let suite = "PresentationTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    var received: [String] = []

    func openChat() -> (ScriptedCoreClient, ConversationModel) {
        let core = ScriptedCoreClient()
        let model = ConversationModel(presentationDefaults: defaults)
        model.core = core
        model.selectedChatID = "chat"
        model.onContentPresentation = { value, _ in received.append(value.id) }
        model.observe("chat")
        return (core, model)
    }
    func emit(_ core: ScriptedCoreClient, id: String = "first", machine: String = "machine") {
        core.emitConversation("chat", daemonID: machine) {
            $0.refreshedAtMillis = 1
            $0.conversation.presentedContent.id = id
            $0.conversation.presentedContent.url = "https://example.com"
        }
    }

    let (core, model) = openChat()
    // A cached transcript can arrive before its owner is resolved. It must
    // not consume the request under an empty machine identity.
    emit(core, machine: "")
    #expect(received.isEmpty)
    emit(core)
    #expect(received.isEmpty, "Opening a chat must not replay its retained URL")
    emit(core, id: "second")
    #expect(received == ["second"])
    model.observe(nil)
    model.selectedChatID = nil
    model.selectedChatID = "chat"
    model.observe("chat")
    emit(core)
    #expect(received == ["second"])
    model.observe(nil)

    let (reopenedCore, reopenedModel) = openChat()
    defer { reopenedModel.observe(nil) }
    emit(reopenedCore, machine: "")
    emit(reopenedCore)
    #expect(received == ["second"])
    // A fresh request for the same URL still presents once.
    emit(reopenedCore, id: "third")
    emit(reopenedCore, id: "third")
    #expect(received == ["second", "third"])
    emit(reopenedCore, machine: "other-machine")
    #expect(received == ["second", "third"])
    emit(reopenedCore, id: "second", machine: "other-machine")
    #expect(received == ["second", "third", "second"])
}

@Test @MainActor func openingChatIgnoresCachedAndFreshRetainedURLsUntilSynchronized() {
    let core = ScriptedCoreClient()
    let model = ConversationModel()
    model.core = core
    model.selectedChatID = "chat"
    model.observe("chat")
    defer { model.observe(nil) }
    var received: [String] = []
    model.onContentPresentation = { value, _ in received.append(value.id) }

    // Loading metadata without a conversation does not establish the baseline.
    core.emitConversation("chat") {
        $0.clearConversation()
        $0.loading = true
    }
    for (id, refreshed) in [("cached", Int64(0)), ("retained", Int64(1)), ("live", Int64(2))] {
        core.emitConversation("chat") {
            // Cached content can be readable without a syncing indicator.
            $0.refreshedAtMillis = refreshed
            $0.conversation.presentedContent.id = id
            $0.conversation.presentedContent.url = "https://example.com/\(id)"
        }
    }
    #expect(received == ["live"])
    model.observe(nil)
    model.observe("chat")
    core.emitConversation("chat") {
        $0.refreshedAtMillis = 3
        $0.conversation.presentedContent.id = "unseen-while-closed"
        $0.conversation.presentedContent.url = "https://example.com/another"
    }
    #expect(received == ["live"])
}

@Test @MainActor func firstLiveURLPresentsAfterAnEmptyInitialConversation() {
    let core = ScriptedCoreClient()
    let model = ConversationModel()
    model.core = core
    model.selectedChatID = "chat"
    model.observe("chat")
    defer { model.observe(nil) }
    var received: [String] = []
    model.onContentPresentation = { value, _ in received.append(value.id) }
    core.emitConversation("chat") { $0.refreshedAtMillis = 1 }
    core.emitConversation("chat") {
        $0.refreshedAtMillis = 2
        $0.conversation.presentedContent.id = "first-live-request"
        $0.conversation.presentedContent.url = "https://example.com"
    }
    #expect(received == ["first-live-request"])
}

@Test @MainActor func oldPresentationIsNotReplayedAfterManyOtherRequests() {
    let core = ScriptedCoreClient()
    let model = ConversationModel()
    model.core = core
    model.selectedCardID = "card"
    model.observe("card")
    defer { model.observe(nil) }
    var received = 0
    model.onContentPresentation = { _, _ in received += 1 }
    for index in 0...512 {
        core.emitConversation("card") {
            $0.conversation.presentedContent.id = "request-\(index)"
        }
    }
    model.observe(nil)
    model.observe("card")
    core.emitConversation("card") {
        $0.conversation.presentedContent.id = "request-0"
    }
    #expect(received == 513)
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
