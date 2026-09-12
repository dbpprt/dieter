import AppKit
import SwiftUI
import Testing
@testable import DieterMac

@Test @MainActor func conversationLinksPreserveRelativePathsAndLineFragments() throws {
    let content = MessageTextView.attributedText(
        source: "[Plan](docs/plan.md) and [source](Sources/App.swift#L42)", color: .labelColor)
    #expect(content.string == "Plan and source")
    let plan = try #require(content.attribute(.link, at: 0, effectiveRange: nil) as? URL)
    #expect(plan.relativeString == "docs/plan.md")
    #expect(plan.baseURL == nil)
    let source = try #require(content.attribute(.link, at: 9, effectiveRange: nil) as? URL)
    #expect(source.relativeString == "Sources/App.swift#L42")
    #expect(source.baseURL == nil)
}

@Test @MainActor func conversationLinkDelegateHandlesDestinationsWithoutChangingSelection() throws {
    let view = MessageTextView()
    view.update(source: "Read the [plan](docs/plan.md).", color: .labelColor)
    let selection = NSRange(location: 0, length: 8)
    view.setSelectedRange(selection)
    var opened = [URL]()
    view.linkDelegate.handler = { url in
        opened.append(url)
        return true
    }
    let destination = try #require(URL(string: "docs/plan.md"))
    #expect(view.delegate === view.linkDelegate)
    #expect(view.linkDelegate.textView(view, clickedOnLink: destination, at: 9))
    #expect(opened == [destination])
    #expect(view.selectedRange() == selection)
    #expect(!view.isEditable && view.isSelectable)

    view.selectAll(nil)
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    #expect(view.writeSelection(to: pasteboard, types: view.writablePasteboardTypes))
    #expect(pasteboard.string(forType: .string) == "Read the plan.")
}

@Test @MainActor func conversationLinksFallBackWhenUnhandledOrCommandClicked() throws {
    let delegate = ConversationTextLinkDelegate()
    let destination = try #require(URL(string: "https://example.com"))
    #expect(!delegate.activate(destination))
    var opened = [URL]()
    delegate.handler = { url in
        opened.append(url)
        return false
    }
    #expect(!delegate.activate(destination))
    #expect(opened == [destination])
    #expect(!delegate.activate(destination, modifiers: .command))
    #expect(!delegate.activate(42))
    #expect(opened == [destination], "Modifier clicks and non-URL attributes stay with AppKit")
    delegate.handler = { url in
        opened.append(url)
        return true
    }
    #expect(delegate.activate("docs/plan.md"))
    #expect(opened.last?.relativeString == "docs/plan.md")
}

@Test @MainActor func conversationLinkEnvironmentReachesNativeMessageViews() throws {
    var opened = [URL]()
    let host = NSHostingView(
        rootView: ConversationMarkdownView(source: "[Plan](docs/plan.md)", inUserBubble: false)
            .environment(
                \.conversationLinkHandler,
                { url in
                    opened.append(url)
                    return true
                }))
    host.frame = NSRect(x: 0, y: 0, width: 500, height: 100)
    host.layoutSubtreeIfNeeded()
    func textView(in view: NSView) -> MessageTextView? {
        (view as? MessageTextView) ?? view.subviews.lazy.compactMap { textView(in: $0) }.first
    }
    let native = try #require(textView(in: host))
    #expect(native.linkDelegate.activate("docs/plan.md"))
    #expect(opened.first?.relativeString == "docs/plan.md")
}

@Test @MainActor func fullConversationSourceKeepsVerbatimTextAndActionableMarkdownLinks() throws {
    let source = "Résumé 👋: [document](docs/plan.md).\n\n[code](Sources/App.swift#L42)"
    let content = FullConversationTextEditor.attributedSource(source)
    #expect(content.string == source)
    for (label, destination) in [("document", "docs/plan.md"), ("code", "Sources/App.swift#L42")] {
        let range = (source as NSString).range(of: label)
        let link = try #require(content.attribute(.link, at: range.location, effectiveRange: nil) as? URL)
        #expect(link.relativeString == destination)
    }
    let fullSource = NSHostingView(
        rootView: FullConversationTextEditor(source: source)
            .environment(\.conversationLinkHandler, { _ in true }))
    fullSource.frame = NSRect(x: 0, y: 0, width: 500, height: 300)
    fullSource.layoutSubtreeIfNeeded()
    func textView(in view: NSView) -> NSTextView? {
        (view as? NSTextView) ?? view.subviews.lazy.compactMap { textView(in: $0) }.first
    }
    let native = try #require(textView(in: fullSource))
    #expect(native.string == source && native.isSelectable && !native.isEditable)
    let delegate = try #require(native.delegate as? ConversationTextLinkDelegate)
    #expect(delegate.activate("docs/plan.md"))
}
