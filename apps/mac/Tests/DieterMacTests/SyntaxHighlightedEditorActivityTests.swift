import AppKit
import Testing
@testable import DieterMac

@MainActor
struct SyntaxHighlightedEditorActivityTests {
    @Test func hiddenSourceKeepsMirroredTextAndUndoThenCatchesUpHighlighting() async throws {
        let session = FileEditorSession()
        let editor = HighlightActivityTextView()
        let original = "# Original\nBody"
        let replacement = "# Changed 💡\n\nMore text"
        let coordinator = SyntaxHighlightedEditor(
            session: session, documentKey: "hidden-source", text: original, filename: "README.md", active: false
        ).makeCoordinator()
        coordinator.textView = editor
        editor.delegate = coordinator
        coordinator.setActive(false)
        defer { coordinator.setActive(false) }
        session.attach(editor, documentKey: "hidden-source", initialText: original)
        editor.textStorage?.addAttribute(
            .foregroundColor, value: NSColor.systemRed, range: .init(location: 0, length: (original as NSString).length)
        )
        let revision = session.revision
        let sourceGeneration = session.sourceEditGeneration

        #expect(session.applyReplacement(replacement, documentKey: "hidden-source"))
        #expect(session.currentText() == replacement)
        #expect(session.lineCount == 3)
        #expect(session.revision == revision + 1)
        #expect(session.sourceEditGeneration == sourceGeneration)
        #expect(headingColor(in: editor) == .systemRed, "Hidden rich edits must not apply source highlighting")
        #expect(editor.testUndoManager.canUndo)
        editor.testUndoManager.undo()
        #expect(session.currentText() == original)
        #expect(session.lineCount == 2)
        editor.testUndoManager.redo()
        #expect(session.currentText() == replacement)
        #expect(headingColor(in: editor) == .systemRed)

        coordinator.setActive(true)
        for _ in 0..<100 {
            if headingColor(in: editor) == .systemPurple { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(headingColor(in: editor) == .systemPurple, "Reopening Source must highlight its latest contents")
        #expect(session.currentText() == replacement)
        #expect(editor.testUndoManager.canUndo)
        editor.testUndoManager.undo()
        #expect(session.currentText() == original, "Highlight catch-up must preserve native source Undo")
    }

    @Test func hidingSourceCancelsAnAlreadyScheduledHighlight() async throws {
        let session = FileEditorSession()
        let editor = HighlightActivityTextView()
        let source = "# Keep existing attributes\nBody"
        let coordinator = SyntaxHighlightedEditor(
            session: session, documentKey: "cancel-highlight", text: source, filename: "README.md"
        ).makeCoordinator()
        coordinator.textView = editor
        editor.delegate = coordinator
        session.attach(editor, documentKey: "cancel-highlight", initialText: source)
        editor.textStorage?.addAttribute(
            .foregroundColor, value: NSColor.systemRed, range: .init(location: 0, length: (source as NSString).length))
        coordinator.highlight(force: true)
        coordinator.setActive(false)
        // Let the queued zero-delay highlight execute its cancellation guard.
        for _ in 0..<30 { await Task.yield() }
        #expect(headingColor(in: editor) == .systemRed)
        #expect(session.currentText() == source)
        #expect(!session.isDirty)
    }

    @Test func hiddenSourceDefersTextContainerResizingAndRejectsFocus() throws {
        let container = SyntaxEditorContainer(frame: .init(x: 0, y: 0, width: 400, height: 300))
        container.layoutSubtreeIfNeeded()
        let textContainer = try #require(container.textView.textContainer)
        let originalWidth = textContainer.containerSize.width
        #expect(originalWidth > 0)
        container.setActive(false)
        container.frame.size = .init(width: 850, height: 500)
        container.layoutSubtreeIfNeeded()
        #expect(textContainer.containerSize.width == originalWidth)
        #expect(!container.textView.isVerticallyResizable)
        #expect(!container.textView.acceptsFirstResponder)
        #expect(container.textView.layoutManager?.backgroundLayoutEnabled == false)
        #expect(container.hitTest(.init(x: 20, y: 20)) == nil)

        container.setActive(true)
        container.layoutSubtreeIfNeeded()
        #expect(abs(textContainer.containerSize.width - container.scrollView.contentSize.width) < 1)
        #expect(textContainer.containerSize.width > originalWidth)
        #expect(container.textView.isVerticallyResizable && container.textView.acceptsFirstResponder)
        #expect(container.textView.layoutManager?.backgroundLayoutEnabled == true)
    }

    private func headingColor(in editor: NSTextView) -> NSColor? {
        editor.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
    }
}

@MainActor
private final class HighlightActivityTextView: NSTextView {
    let testUndoManager = UndoManager()
    private let retainedStorage: NSTextStorage
    override var undoManager: UndoManager? { testUndoManager }

    init() {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: .init(width: 600, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        retainedStorage = storage
        super.init(frame: .zero, textContainer: container)
        isRichText = false
        allowsUndo = true
    }

    required init?(coder: NSCoder) { nil }
}
