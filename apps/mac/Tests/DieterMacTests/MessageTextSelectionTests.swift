import AppKit
import DieterAPI
import SwiftUI
import Testing
@testable import DieterMac

@Test @MainActor func messageSelectionSpansParagraphsAndCopiesTheWholeResponse() throws {
    let view = MessageTextView()
    view.update(source: "First **paragraph**.\n\nSecond paragraph with `code`.\n\nFinal paragraph.", color: .labelColor)
    view.frame = NSRect(origin: .zero, size: view.fittingSize(width: 420))
    let expected = "First paragraph.\n\nSecond paragraph with code.\n\nFinal paragraph."
    #expect(view.string == expected)
    #expect(!view.isEditable && view.isSelectable)

    // Exercise AppKit's native keyboard selection across the paragraph boundary.
    view.setSelectedRange(NSRange(location: 6, length: 0))
    view.moveToEndOfDocumentAndModifySelection(nil)
    #expect(view.selectedRange() == NSRange(location: 6, length: (expected as NSString).length - 6))
    view.selectAll(nil)
    #expect(view.selectedRange() == NSRange(location: 0, length: (expected as NSString).length))
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    #expect(view.writeSelection(to: pasteboard, types: view.writablePasteboardTypes))
    #expect(pasteboard.string(forType: .string) == expected)
}

@Test @MainActor func messageSelectionSurvivesStreamingAndThemeUpdates() {
    let view = MessageTextView()
    let source = "First paragraph 👋.\n\nSecond paragraph."
    view.update(source: source, color: .white)
    let selected = NSRange(location: 3, length: 25)
    view.setSelectedRange(selected)
    view.update(source: source, color: .white)
    #expect(view.selectedRange() == selected)
    view.update(source: source + " More text.", color: .white)
    #expect(view.selectedRange() == selected)
    view.update(source: source + " More text.", color: .black)
    #expect(view.selectedRange() == selected)
    view.update(source: "Replacement", color: .black)
    #expect(view.selectedRange().length == 0)
}

@Test @MainActor func messageTextPreservesFormattingAndFitsNarrowLayouts() throws {
    let source =
        "**Bold** *italic* `code` [link](https://example.com)\n\n" + String(repeating: "Wrapping text. ", count: 25)
    let view = MessageTextView()
    view.update(source: source, color: .white)
    let storage = try #require(view.textStorage)
    let bold = try #require(storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
    #expect(NSFontManager.shared.traits(of: bold).contains(.boldFontMask))
    let italic = try #require(storage.attribute(.font, at: 5, effectiveRange: nil) as? NSFont)
    #expect(NSFontManager.shared.traits(of: italic).contains(.italicFontMask))
    #expect(storage.attribute(.link, at: 17, effectiveRange: nil) as? URL == URL(string: "https://example.com"))
    let wide = view.fittingSize(width: 600)
    let narrow = view.fittingSize(width: 220)
    #expect(narrow.height > wide.height)
    #expect(narrow.width <= 220)
    #expect(wide.height > 0)
}

@Test @MainActor func messageTextSelectionUsesOneNativeViewForAdjacentTextParts() throws {
    func text(_ value: String) -> Dieter_V1_MessagePart {
        var part = Dieter_V1_MessagePart()
        part.type = "text"
        part.text = value
        return part
    }
    var attachment = Dieter_V1_MessagePart()
    attachment.type = "file"
    attachment.filename = "notes.txt"
    let parts = [text("First paragraph."), text("Second paragraph."), attachment, text("After attachment.")]
    let grouped = ConversationMessagePartGroup.group(parts)
    #expect(grouped.count == 3)
    #expect(grouped[0].parts[0].text == "First paragraph.\n\nSecond paragraph.")
    #expect(grouped[1].parts[0] == attachment)

    for role in ["user", "assistant"] {
        var message = Dieter_V1_UiMessage()
        message.id = "selection-test"
        message.role = role
        message.parts = Array(parts.prefix(2))
        let store = DieterStore(restoreSync: false)
        let host = NSHostingView(rootView: MessageView(message: message).environment(store.conversationContext))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        host.layoutSubtreeIfNeeded()
        func textViews(_ view: NSView) -> [MessageTextView] {
            (view as? MessageTextView).map { [$0] } ?? view.subviews.flatMap(textViews)
        }
        let nativeViews = textViews(host)
        #expect(nativeViews.count == 1, "\(role) text must share one selection surface")
        let native = try #require(nativeViews.first)
        native.selectAll(nil)
        #expect(native.string == "First paragraph.\n\nSecond paragraph.")
        #expect(native.selectedRange().length == (native.string as NSString).length)
        #expect(native.frame.height > 0 && native.frame.width <= 600)
    }
}

@Test @MainActor func messageSelectionIncludesUpstreamMarkdownBlocks() throws {
    let source =
        "# Heading\n\nFirst paragraph.\n\n- Item\n\n```swift\nlet value = 1\n```\n\n| Name | Value |\n| --- | ---: |\n| Alpha | 42 |\n\nLast paragraph."
    let view = MessageTextView()
    view.update(source: source, color: .labelColor)
    view.frame = NSRect(origin: .zero, size: view.fittingSize(width: 420))
    #expect(view.string.contains("Heading\n\nFirst paragraph."))
    #expect(view.string.contains("• Item"))
    #expect(view.string.contains("let value = 1"))
    #expect(view.string.contains("Alpha\n42"))
    let storage = try #require(view.textStorage)
    let heading = try #require(storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
    #expect(heading.pointSize == 17)
    let cellIndex = (view.string as NSString).range(of: "42").location
    let style = try #require(
        storage.attribute(.paragraphStyle, at: cellIndex, effectiveRange: nil) as? NSParagraphStyle)
    #expect(style.alignment == .right)
    #expect(style.textBlocks.first is NSTextTableBlock)
    view.selectAll(nil)
    #expect(view.selectedRange().length == storage.length)
    #expect(view.frame.height.isFinite && view.frame.height > 0)
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    #expect(view.writeSelection(to: pasteboard, types: view.writablePasteboardTypes))
    let copied = try #require(pasteboard.string(forType: .string))
    #expect(copied.contains("First paragraph.") && copied.contains("42") && copied.contains("Last paragraph."))
}
