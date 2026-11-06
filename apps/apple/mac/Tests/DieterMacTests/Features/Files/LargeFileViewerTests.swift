import AppKit
import SwiftUI
import Testing
@testable import DieterMacKit

@MainActor
struct LargeFileViewerTests {
    @Test(arguments: [false, true])
    func multiMegabyteMarkdownOpensAsOneEditableSourceBuffer(minified: Bool) async throws {
        let paragraph = "# Heading 🐈\n\nA **bold** paragraph with [a link](https://example.com).\n\n"
        let source = minified ? String(repeating: "x", count: 2_600_000) : String(repeating: paragraph, count: 36_000)
        #expect(source.utf8.count > 2_500_000)
        let session = FileEditorSession()
        let started = ContinuousClock.now
        session.prepare(documentKey: "large", text: source)
        let host = NSHostingView(
            rootView: MarkdownFileEditor(
                session: session, documentKey: "large", text: source, filename: "large.md"))
        host.sizingOptions = []
        let window = NSWindow(
            contentRect: .init(x: -3000, y: -3000, width: 900, height: 650),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        for _ in 0..<100 {
            if !textViews(in: host).isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let editors = textViews(in: host)
        let editor = try #require(editors.first)
        #expect(editors.count == 1, "Large documents must never instantiate the rich engine beside Source")
        #expect(editor is SyntaxEditorTextView)
        #expect(editor.isEditable)
        #expect(editor.string == source)
        #expect(!session.isDirty)
        print("Large file open (\(source.utf8.count) bytes): \(started.duration(to: .now))")

        window.makeFirstResponder(editor)
        let originalLength = (source as NSString).length
        let editStarted = ContinuousClock.now
        editor.insertText("\nTail 💡", replacementRange: .init(location: originalLength, length: 0))
        editor.breakUndoCoalescing()
        #expect(session.currentText() == source + "\nTail 💡")
        #expect(session.isDirty)
        #expect(editor.undoManager?.canUndo == true)
        editor.undoManager?.undo()
        #expect(session.currentText() == source)
        editor.undoManager?.redo()
        #expect(session.currentText() == source + "\nTail 💡")
        print("Large file edit/undo/redo: \(editStarted.duration(to: .now))")
        // Highlighting and relayout must not replace the draft or selection.
        let selection = editor.selectedRange()
        window.setContentSize(.init(width: 500, height: 650))
        host.layoutSubtreeIfNeeded()
        #expect(editor.selectedRange() == selection)
        #expect(session.currentText().hasSuffix("Tail 💡"))
    }

    @Test func sourceModeBudgetHandlesDenseFilesAndStaysStableWhileEditing() {
        let session = FileEditorSession()
        session.prepare(documentKey: "dense", text: String(repeating: "\n", count: 4_001))
        #expect(session.usesLargeDocumentMode)
        #expect(session.applyReplacement("small draft", documentKey: "dense"))
        #expect(session.usesLargeDocumentMode, "Shrinking a draft must preserve the source editor's undo stack")
        session.prepare(documentKey: "normal", text: "# Small Markdown")
        #expect(!session.usesLargeDocumentMode)
        let boundary = String(repeating: String(repeating: "a", count: 99) + "\n", count: 2_000)
        session.prepare(documentKey: "boundary", text: boundary)
        #expect(!session.usesLargeDocumentMode)
        #expect(session.applyReplacement(boundary + "a", documentKey: "boundary"))
        #expect(session.usesLargeDocumentMode)
        session.prepare(documentKey: "long-line", text: String(repeating: "*", count: 10_000))
        #expect(session.usesLargeDocumentMode)
    }

    @Test func minifiedAndOversizeHighlightInputsRemainPlain() {
        for text in [String(repeating: "*", count: 200_000), String(repeating: "x\n", count: 150_000)] {
            let range = NSRange(location: 0, length: (text as NSString).length)
            let started = ContinuousClock.now
            let plan = FileSyntaxHighlightPlan.lex(text, path: "generated.md", in: range)
            #expect(plan.spans.isEmpty)
            #expect(plan.range == range)
            print("Pathological highlight bypass (\(range.length) UTF-16 units): \(started.duration(to: .now))")
        }
    }

    private func textViews(in view: NSView) -> [NSTextView] {
        (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap { textViews(in: $0) }
    }
}
