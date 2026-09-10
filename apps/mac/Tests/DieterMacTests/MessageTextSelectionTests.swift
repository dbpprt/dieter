import AppKit
import DieterAPI
import Observation
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

@Test @MainActor func rejectedMessageSizingProposalsDoNotMoveDisplayedGlyphsOrScrollBounds() throws {
    let view = MessageTextView()
    view.update(source: messageSizingFixture, color: .labelColor)
    view.frame = NSRect(origin: .zero, size: view.fittingSize(width: 620))
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 650, height: 240))
    scroll.documentView = view
    let layout = try #require(view.layoutManager)
    let container = try #require(view.textContainer)
    layout.ensureLayout(for: container)
    let frame = view.frame
    let scrollBounds = try #require(scroll.documentView).bounds
    let containerSize = container.containerSize
    let marker = (view.string as NSString).range(of: "Final reachable line.")
    #expect(marker.location != NSNotFound)
    let glyphs = layout.glyphRange(forCharacterRange: marker, actualCharacterRange: nil)
    let finalRect = layout.boundingRect(forGlyphRange: glyphs, in: container)
    view.setSelectedRange(marker)

    // SwiftUI asks several questions before choosing a size. None of these
    // rejected proposals is permission to change the live NSTextView frame.
    for width in [CGFloat(1), 1700, 430, 180, 1000] {
        let proposed = view.fittingSize(width: width)
        #expect(proposed.height > 0)
        layout.ensureLayout(for: container)
        #expect(view.frame == frame)
        #expect(scroll.documentView?.bounds == scrollBounds)
        #expect(container.containerSize == containerSize)
        #expect(layout.boundingRect(forGlyphRange: glyphs, in: container) == finalRect)
        #expect(view.selectedRange() == marker)
    }
    #expect(!view.isVerticallyResizable && view.clipsToBounds)
}

@Test @MainActor func messageStreamingAndResizingKeepFinalGlyphInsideScrollableContent() throws {
    let view = MessageTextView()
    view.update(source: "# Starting response\n\nFirst paragraph.", color: .labelColor)
    view.frame = NSRect(origin: .zero, size: view.fittingSize(width: 620))
    let originalFrame = view.frame
    view.update(source: messageSizingFixture, color: .labelColor)
    #expect(view.frame == originalFrame, "Streaming must wait for SwiftUI to assign the new frame")
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 650, height: 240))
    scroll.documentView = view
    let layout = try #require(view.layoutManager)
    let container = try #require(view.textContainer)
    for width in [CGFloat(320), 620, 900, 430] {
        let measured = view.fittingSize(width: width)
        view.frame = NSRect(origin: .zero, size: measured)
        layout.ensureLayout(for: container)
        let marker = (view.string as NSString).range(of: "Final reachable line.")
        let glyphs = layout.glyphRange(forCharacterRange: marker, actualCharacterRange: nil)
        let finalRect = layout.boundingRect(forGlyphRange: glyphs, in: container)
        #expect(layout.usedRect(for: container).maxY <= measured.height)
        #expect(finalRect.maxY <= view.bounds.maxY)
        #expect(finalRect.width > 0 && finalRect.height > 0)
        // NSClipView aligns its origin to backing pixels. Round the requested
        // glyph bounds outward so a half-point descender on a 1x CI display is
        // not lost when AppKit rounds an otherwise sufficient scroll offset.
        view.scrollToVisible(finalRect.integral)
        #expect(scroll.documentVisibleRect.contains(finalRect), "The last line must be reachable at width \(width)")
    }
}

private let messageSizingFixture = """
    # Starting response

    First paragraph.

    **A sizing detail:** Inline `code`, [links](https://example.com), and emphasized _words_ use different glyph metrics.

    - A bullet with several words that wraps when the conversation becomes narrow.
    - Another bullet followed by a code sample.

    ```swift
    let explanation = "Long source lines must remain inside the height allocated by the conversation timeline."
    ```

    | Name | Description |
    | --- | --- |
    | First row | A table cell with enough words to wrap differently as the window becomes narrow. |
    | Second row | More content in another table cell. |

    \(String(repeating: "A streamed response keeps all earlier paragraphs selectable while more text arrives. ", count: 24))

    Final reachable line.
    """

@Test @MainActor func hostedMessageRowsReflowAfterStreamingAndResizeWithoutInteraction() async throws {
    let state = HostedMessageSizingState()
    let store = DieterStore(restoreSync: false)
    let host = NSHostingView(rootView: HostedMessageSizingView(state: state).environment(store.conversationContext))
    host.sizingOptions = []
    let window = NSWindow(
        contentRect: .init(x: 0, y: 0, width: 700, height: 600),
        styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.setContentSize(.init(width: 700, height: 600))
    defer { window.close() }
    host.layoutSubtreeIfNeeded()

    for (width, source) in [
        (700.0, "Starting response."),
        (700.0, messageSizingFixture),
        (320.0, messageSizingFixture),
        (960.0, messageSizingFixture),
        (460.0, messageSizingFixture + "\n\n" + String(repeating: "More streamed words. ", count: 40)),
        (700.0, "A shorter replacement response."),
    ] {
        state.source = source
        window.setContentSize(.init(width: width, height: 600))
        let expectedStrings = [source, "Following user bubble.", "Following assistant response."].map {
            MessageTextView.attributedText(source: $0, color: .labelColor).string
        }
        // Observe ordinary SwiftUI layout updates. Do not assign child frames,
        // force glyph layout, select text, or scroll to repair stale geometry.
        for _ in 0..<100 {
            if hostedMessageRowsFit(host, expectedStrings: expectedStrings) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(
            hostedMessageRowsFit(host, expectedStrings: expectedStrings),
            "Streaming and resizing to \(width) must update native heights and keep following rows separate")
    }
}

@MainActor private func hostedMessageRowsFit(_ host: NSView, expectedStrings: [String]) -> Bool {
    func textViews(in view: NSView) -> [MessageTextView] {
        (view as? MessageTextView).map { [$0] } ?? view.subviews.flatMap { textViews(in: $0) }
    }
    let views = textViews(in: host)
    guard views.count == expectedStrings.count else { return false }
    var frames = [NSRect]()
    for expected in expectedStrings {
        guard let view = views.first(where: { $0.string == expected }), view.bounds.width > 0 else { return false }
        let reference = MessageTextView()
        reference.update(source: expected, color: .labelColor)
        // Use the live attributed content so headings, tables and code retain
        // their metrics instead of parsing their already-displayed plain text.
        reference.textStorage?.setAttributedString(view.attributedString())
        let layout = reference.layoutManager!
        let container = reference.textContainer!
        container.widthTracksTextView = false
        container.containerSize = .init(width: view.bounds.width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        guard view.bounds.height + 1 >= ceil(layout.usedRect(for: container).maxY) else { return false }
        frames.append(view.convert(view.bounds, to: host))
    }
    return !frames[0].intersects(frames[1]) && !frames[0].intersects(frames[2]) && !frames[1].intersects(frames[2])
}

@MainActor @Observable private final class HostedMessageSizingState {
    var source = "Starting response."
}

private struct HostedMessageSizingView: View {
    let state: HostedMessageSizingState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                MessageView(message: message(id: "streaming", role: "assistant", text: state.source))
                MessageView(message: message(id: "following-user", role: "user", text: "Following user bubble."))
                MessageView(
                    message: message(
                        id: "following-assistant", role: "assistant", text: "Following assistant response."))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
    }

    private func message(id: String, role: String, text: String) -> Dieter_V1_UiMessage {
        var part = Dieter_V1_MessagePart()
        part.type = "text"
        part.text = text
        var result = Dieter_V1_UiMessage()
        result.id = id
        result.role = role
        result.parts = [part]
        return result
    }
}
