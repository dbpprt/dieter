import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite(.serialized)
struct NativeRenderedCodeBlockTests {
    @Test func initialDiagramCollapsesHundredsOfSourceLinesWithoutChangingMarkdown() throws {
        let json = (0..<650).map { "  \"field\($0)\": \($0)," }.joined(separator: "\n")
        let source =
            "```vega-lite\n{\n\(json)\n  \"mark\": \"bar\"\n}\n```\n\nFollowing paragraph\n\n```swift\nprint(1)\n```\n"
        let fixture = try EditorFixture(source)
        let editor = fixture.editor
        let storage = try #require(editor.textStorage)
        let anchor = try #require(fixture.imageAnchors().first)
        #expect(fixture.imageAnchors().count == 1)
        #expect(editor.selectedRange().location == 0)
        #expect(editor.string == source)
        #expect(fixture.source == source)
        #expect(editor.undoManager?.canUndo != true)
        let rect = fixture.rect(for: anchor)
        let following = (source as NSString).range(of: "Following paragraph")
        let followingRect = fixture.rect(for: following)
        #expect(followingRect.minY > rect.minY)
        #expect(followingRect.minY - rect.minY < fixture.renderer.height + 45)
        let swiftRange = (source as NSString).range(of: "print(1)")
        #expect(storage.attribute(.renderedCodeBlockRange, at: swiftRange.location, effectiveRange: nil) == nil)
        #expect(fixture.renderer.requests.allSatisfy { $0.language == "vega-lite" || $0.language == "swift" })
    }

    @Test func nativeDiagramClickRevealsOnlyThatFenceAndUndoPreservesItsSource() throws {
        let source = "```mermaid\ngraph LR\n A-->B\n```\n\nOutside\n\n```vega-lite\n{\"mark\":\"bar\"}\n```\n"
        let fixture = try EditorFixture(source)
        let editor = fixture.editor
        #expect(fixture.imageAnchors().count == 2)
        let first = try #require(fixture.imageAnchors().first)
        let imageRect = fixture.rect(for: first)
        let point = editor.convert(NSPoint(x: imageRect.midX, y: imageRect.midY), to: nil)
        let event = try #require(
            NSEvent.mouseEvent(
                with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        #expect(editor.revealRenderedCodeIfHit(event: event))
        #expect(fixture.imageAnchors().count == 1)
        let undo = try #require(editor.undoManager)
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        editor.insertText("C", replacementRange: (editor.string as NSString).range(of: "B"))
        undo.endUndoGrouping()
        #expect(editor.string == source.replacingOccurrences(of: "A-->B", with: "A-->C"))
        editor.setSelectedRange((editor.string as NSString).range(of: "Outside"))
        fixture.coordinator.textViewDidChangeSelection(
            Notification(name: NSTextView.didChangeSelectionNotification, object: editor))
        #expect(fixture.imageAnchors().count == 2)
        #expect(fixture.renderer.requests.contains { $0.code.contains("A-->C") })
        undo.undo()
        #expect(editor.string == source)
        #expect(fixture.source == source)
    }

    @Test func rendererCompletionAndWidthChangesRefreshWithoutEditing() async throws {
        let source = "```mermaid\ngraph LR\n A-->B\n```\n\nAfter\n"
        let fixture = try EditorFixture(source)
        let initialWidth = try #require(fixture.renderer.requests.last).width
        fixture.editor.setFrameSize(NSSize(width: 380, height: fixture.editor.frame.height))
        try await Task.sleep(for: .milliseconds(100))
        #expect(fixture.renderer.requests.contains { $0.width < initialWidth - 100 })
        fixture.renderer.height = 240
        fixture.renderer.generation += 1
        NotificationCenter.default.post(name: fixture.renderer.notification, object: nil)
        let anchor = try #require(fixture.imageAnchors().first)
        let bounds = try #require(
            fixture.editor.textStorage?.attribute(.latexBounds, at: anchor.location, effectiveRange: nil) as? NSValue)
        #expect(bounds.rectValue.height == 240)
        #expect(fixture.editor.string == source)
        #expect(fixture.source == source)
        #expect(fixture.editor.undoManager?.canUndo != true)
    }

    @Test func largeReportUsesBoundedStylesAndRefreshesOnlyDiagramAnchors() throws {
        let rows = (0..<925).map { "            {\"x\": \($0), \"y\": \($0 % 10)}," }.joined(separator: "\n")
        let source =
            (0..<7).map { "## Chart \($0)\n\n```vega-lite\n{\n\"data\": [\n\(rows)\n]}\n```\n\nParagraph \($0)\n" }
            .joined(separator: "\n") + "\n```swift\nprint(1)\n```\n"
        #expect(source.utf8.count > 190_000)
        let highlighter = CountingHighlighter()
        var configuration = MarkdownEditorConfiguration.default
        configuration.services.renderedCodeBlocks = TestCodeRenderer()
        configuration.services.syntaxHighlighter = highlighter
        let styleStart = ContinuousClock.now
        let styles = MarkdownStyler.styleAttributes(
            text: source, fontName: NSFont.systemFont(ofSize: 14).fontName, fontSize: 14,
            caretLocation: -1, activeTokenIndices: [], configuration: configuration)
        let styleTime = styleStart.duration(to: .now)
        #expect(styles.count < 250)
        #expect(highlighter.requests.allSatisfy { $0.language == "swift" })
        #expect(!highlighter.requests.isEmpty)
        let openStart = ContinuousClock.now
        let fixture = try EditorFixture(source, highlighter: highlighter)
        let openTime = openStart.duration(to: .now)
        #expect(fixture.imageAnchors().count == 7)
        let storage = try #require(fixture.editor.textStorage)
        let sentinel = NSAttributedString.Key("UnrelatedProsePresentation")
        let paragraph = (source as NSString).range(of: "Paragraph 6")
        storage.addAttribute(sentinel, value: "preserved", range: paragraph)
        let highlighterCalls = highlighter.requests.count
        let refreshStart = ContinuousClock.now
        for _ in 0..<7 {
            fixture.renderer.generation += 1
            NotificationCenter.default.post(name: fixture.renderer.notification, object: nil)
        }
        let refreshTime = refreshStart.duration(to: .now)
        #expect(highlighter.requests.count == highlighterCalls)
        #expect(storage.attribute(sentinel, at: paragraph.location, effectiveRange: nil) as? String == "preserved")
        #expect(fixture.editor.string == source)
        #expect(fixture.source == source)
        #expect(fixture.editor.undoManager?.canUndo != true)
        // An unchanged completion must not rewrite even the image anchor attributes.
        let anchor = try #require(fixture.imageAnchors().first)
        storage.addAttribute(sentinel, value: "anchor preserved", range: anchor)
        NotificationCenter.default.post(name: fixture.renderer.notification, object: nil)
        #expect(storage.attribute(sentinel, at: anchor.location, effectiveRange: nil) as? String == "anchor preserved")
        print(
            "Large Markdown report: \(source.utf8.count) bytes; styles=\(styles.count); style=\(styleTime); initial native layout=\(openTime); seven completions=\(refreshTime)"
        )
    }

    @Test func revealedDiagramReceivesNormalCodeHighlighting() throws {
        let highlighter = CountingHighlighter()
        let source = "```mermaid\ngraph LR\n A-->B\n```\n\nOutside\n"
        let fixture = try EditorFixture(source, highlighter: highlighter)
        #expect(highlighter.requests.isEmpty)
        fixture.coordinator.beginNativeInteraction()
        fixture.editor.setSelectedRange((source as NSString).range(of: "A-->B"))
        fixture.coordinator.textViewDidChangeSelection(
            Notification(name: NSTextView.didChangeSelectionNotification, object: fixture.editor))
        #expect(fixture.imageAnchors().isEmpty)
        #expect(highlighter.requests.contains { $0.language == "mermaid" && $0.code.contains("A-->B") })
    }

    @Test func emptyAndUnsupportedFencesStayEditableSource() throws {
        let source = "```mermaid\n```\n\n```swift\nlet x = 1\n```\n"
        let fixture = try EditorFixture(source)
        #expect(fixture.imageAnchors().isEmpty)
        #expect(fixture.editor.string == source)
    }
}

private final class TestCodeRenderer: RenderedCodeBlockRenderer, @unchecked Sendable {
    struct Request { let code: String; let language: String; let width: CGFloat }
    var requests: [Request] = []
    var cache: [String: RenderedCodeBlockResult] = [:]
    var height: CGFloat = 160
    var generation = 0
    let notification = Notification.Name("DieterRenderedCodeTest.\(UUID().uuidString)")
    var renderingDidChangeNotification: Notification.Name? { notification }
    func fingerprint() -> AnyHashable { generation }
    func render(code: String, language: String, availableWidth: CGFloat, theme: MarkdownEditorTheme)
        -> RenderedCodeBlockResult?
    {
        requests.append(Request(code: code, language: language, width: availableWidth))
        guard ["mermaid", "vega", "vega-lite"].contains(language) else { return nil }
        let key = "\(generation)|\(availableWidth)|\(height)|\(language)|\(code)"
        if let result = cache[key] { return result }
        let size = CGSize(width: availableWidth, height: height)
        let result = RenderedCodeBlockResult(image: NSImage(size: size), size: size)
        cache[key] = result
        return result
    }
}

@MainActor
private final class EditorFixture {
    let editor: NativeTextView
    let coordinator: NativeTextViewCoordinator
    let renderer = TestCodeRenderer()
    let scrollView: ClampedScrollView
    let container: NativeTextViewContainer
    let sourceBox: SourceBox
    var source: String { sourceBox.text }

    init(_ source: String, highlighter: CountingHighlighter? = nil) throws {
        _ = NSApplication.shared
        let box = SourceBox(source)
        sourceBox = box
        coordinator = NativeTextViewCoordinator(
            text: Binding(get: { box.text }, set: { box.text = $0 }),
            fontName: NSFont.systemFont(ofSize: 14).fontName, fontSize: 14,
            isWikiLinkActive: .constant(false), onLinkClick: nil, onInlineSelectionChange: nil)
        editor = NativeTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
        scrollView = ClampedScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
        container = NativeTextViewContainer(frame: scrollView.bounds)
        container.textView = editor
        container.addSubview(editor)
        scrollView.documentView = container
        var configuration = MarkdownEditorConfiguration.default
        configuration.services.renderedCodeBlocks = renderer
        if let highlighter { configuration.services.syntaxHighlighter = highlighter }
        editor.configuration = configuration
        editor.isEditable = true
        editor.isRichText = true
        editor.allowsUndo = true
        editor.textContainerInset = .zero
        let textContainer = try #require(editor.textContainer)
        textContainer.lineFragmentPadding = 0
        textContainer.widthTracksTextView = true
        textContainer.heightTracksTextView = false
        textContainer.size = NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude)
        let layout = try #require(editor.textLayoutManager)
        coordinator.layoutBridge = LayoutBridge(layout)
        editor.layoutBridge = coordinator.layoutBridge
        coordinator.layoutDelegate = MarkdownLayoutManagerDelegate()
        layout.delegate = coordinator.layoutDelegate
        coordinator.configuration = configuration
        coordinator.documentId = UUID().uuidString
        coordinator.textView = editor
        editor.delegate = coordinator
        coordinator.rebuildTextStorageAndStyle(editor, from: source)
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        coordinator.textViewDidChangeSelection(
            Notification(name: NSTextView.didChangeSelectionNotification, object: editor))
        layout.ensureLayout(for: layout.documentRange)
    }

    func imageAnchors() -> [NSRange] {
        guard let storage = editor.textStorage else { return [] }
        var result: [NSRange] = []
        storage.enumerateAttribute(.latexImage, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if value is NSImage { result.append(range) }
        }
        return result
    }

    func rect(for range: NSRange) -> CGRect {
        if let layout = editor.textLayoutManager { layout.ensureLayout(for: layout.documentRange) }
        guard let bridge = coordinator.layoutBridge, let container = editor.textContainer else { return .zero }
        return bridge.boundingRect(forCharacterRange: range, in: container)
    }
}

@MainActor
private final class SourceBox {
    var text: String
    init(_ text: String) { self.text = text }
}

private final class CountingHighlighter: SyntaxHighlighter, @unchecked Sendable {
    struct Request { let code: String; let language: String? }
    var requests: [Request] = []
    func codeFont(size: CGFloat) -> NSFont { .monospacedSystemFont(ofSize: size, weight: .regular) }
    func backgroundColor() -> NSColor { .clear }
    func highlight(code: String, language: String?) -> NSAttributedString? {
        requests.append(Request(code: code, language: language))
        return nil
    }
    var appearanceDidChangeNotification: Notification.Name? { nil }
}
