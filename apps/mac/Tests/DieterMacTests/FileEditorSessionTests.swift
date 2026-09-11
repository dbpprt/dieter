import AppKit
import Testing
@testable import DieterMac

@MainActor
struct FileEditorSessionTests {
    @Test func staleReplacementsAndSameTextEchoesPreserveTheDraft() {
        let session = FileEditorSession()
        let editor = NSTextView()
        session.attach(editor, documentKey: "A:1", initialText: "# Current\n")
        let revision = session.revision
        let sourceGeneration = session.sourceEditGeneration

        #expect(!session.applyReplacement("old file callback", documentKey: "B:1"))
        #expect(!session.applyReplacement("# Current\n", documentKey: "A:1"))
        #expect(editor.string == "# Current\n")
        #expect(session.revision == revision)
        #expect(session.lineCount == 2)
        #expect(!session.isDirty)

        #expect(session.applyReplacement("# Draft\n\nBody", documentKey: "A:1"))
        #expect(!session.applyReplacement("# Draft\n\nBody", documentKey: "A:1"))
        #expect(session.revision == revision + 1)
        #expect(session.lineCount == 3)
        #expect(session.isDirty)
        #expect(session.sourceEditGeneration == sourceGeneration)
    }

    @Test func detachedReplacementSurvivesSourceRemountAndRejectsAnOldSaveAcknowledgement() {
        let session = FileEditorSession()
        session.prepare(documentKey: "A:1", text: "Original")
        let submittedRevision = session.revision
        #expect(session.applyReplacement("# Edited\n\nParagraph", documentKey: "A:1"))
        #expect(session.revision == submittedRevision + 1)
        #expect(session.lineCount == 3)
        session.markSaved(documentKey: "A:1", submittedText: "Original", editRevision: submittedRevision)
        #expect(session.isDirty)

        let editor = NSTextView()
        session.attach(editor, documentKey: "A:1", initialText: "Original")
        #expect(editor.string == "# Edited\n\nParagraph")
        #expect(session.isDirty)
        #expect(session.revision == submittedRevision + 1)
        session.prepare(documentKey: "B:1", text: "Other file")
        #expect(!session.applyReplacement("delayed edit", documentKey: "A:1"))
        #expect(editor.string == "Other file")
        #expect(!session.isDirty)
    }

    @Test func attachedReplacementWithoutADelegateUpdatesTheSessionOnce() {
        let session = FileEditorSession()
        let editor = ReplacementTextView(frame: .zero, textContainer: nil)
        session.attach(editor, documentKey: "A:1", initialText: "First\nSecond\nThird")
        editor.setSelectedRange(NSRange(location: 17, length: 1))
        let revision = session.revision

        #expect(session.applyReplacement("Short", documentKey: "A:1"))
        #expect(editor.string == "Short")
        #expect(session.currentText() == "Short")
        #expect(session.lineCount == 1)
        #expect(session.revision == revision + 1)
        #expect(session.isDirty)
        #expect(NSMaxRange(editor.selectedRange()) <= (editor.string as NSString).length)
    }

    @Test func sourceDelegateAccountsForRichReplacementAndNativeUndoRedoExactlyOnce() {
        let session = FileEditorSession()
        let editor = ReplacementTextView(frame: .zero, textContainer: nil)
        let initial = "# Original 🐈\nBody"
        let replacement = "# Updated 💡\n\n**Bold**"
        let representable = SyntaxHighlightedEditor(
            session: session, documentKey: "A:1", text: initial, filename: "README.md")
        let coordinator = representable.makeCoordinator()
        coordinator.textView = editor
        editor.delegate = coordinator
        session.attach(editor, documentKey: "A:1", initialText: initial)
        let revision = session.revision

        #expect(session.applyReplacement(replacement, documentKey: "A:1"))
        let sourceGeneration = session.sourceEditGeneration
        #expect(session.currentText() == replacement)
        #expect(session.lineCount == 3)
        #expect(session.revision == revision + 1)
        #expect(editor.testUndoManager.canUndo)
        let headingColor = editor.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        #expect(headingColor == .systemPurple)

        editor.testUndoManager.undo()
        #expect(session.currentText() == initial)
        #expect(session.lineCount == 2)
        #expect(session.revision == revision + 2)
        #expect(editor.testUndoManager.canRedo)
        #expect(session.sourceEditGeneration == sourceGeneration + 1)

        editor.testUndoManager.redo()
        #expect(session.currentText() == replacement)
        #expect(session.lineCount == 3)
        #expect(session.revision == revision + 3)
        #expect(session.isDirty)
        #expect(session.sourceEditGeneration == sourceGeneration + 2)
        withExtendedLifetime(coordinator) {}
    }

    @Test func aRejectedNativeEditDoesNotChangeTextOrDirtyState() {
        let session = FileEditorSession()
        let editor = ReplacementTextView(frame: .zero, textContainer: nil)
        let delegate = RejectReplacementDelegate()
        editor.delegate = delegate
        session.attach(editor, documentKey: "A:1", initialText: "Keep this")
        editor.testUndoManager.removeAllActions()
        let revision = session.revision

        #expect(!session.applyReplacement("Rejected", documentKey: "A:1"))
        #expect(session.currentText() == "Keep this")
        #expect(session.revision == revision)
        #expect(!session.isDirty)
        #expect(!editor.testUndoManager.canUndo)
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
private final class ReplacementTextView: NSTextView {
    let testUndoManager = UndoManager()
    private let retainedStorage: NSTextStorage
    override var undoManager: UndoManager? { testUndoManager }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        let storage = container?.layoutManager?.textStorage ?? NSTextStorage()
        let layoutManager = container?.layoutManager ?? NSLayoutManager()
        if layoutManager.textStorage == nil { storage.addLayoutManager(layoutManager) }
        let textContainer =
            container ?? NSTextContainer(size: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        if textContainer.layoutManager == nil { layoutManager.addTextContainer(textContainer) }
        retainedStorage = storage
        super.init(frame: frameRect, textContainer: textContainer)
        isRichText = false
        allowsUndo = true
    }

    required init?(coder: NSCoder) { nil }
}

@MainActor
private final class RejectReplacementDelegate: NSObject, NSTextViewDelegate {
    func textView(_: NSTextView, shouldChangeTextIn _: NSRange, replacementString _: String?) -> Bool { false }
}
