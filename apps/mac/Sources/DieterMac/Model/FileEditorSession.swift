import AppKit
import Foundation
import Observation

/// Owns the live AppKit editor buffer. Observable UI state stays small while
/// the full document string crosses into the store only at open/save
/// boundaries.
@MainActor
@Observable
final class FileEditorSession {
    private(set) var documentKey = ""
    private(set) var isDirty = false
    private(set) var lineCount = 1
    private(set) var revision = 0
    /// Native rich-text undo records ranges in its own buffer. A source edit
    /// invalidates those ranges; mirrored rich edits do not.
    private(set) var sourceEditGeneration = 0
    @ObservationIgnored private weak var textView: NSTextView?
    @ObservationIgnored private var detachedText = ""
    @ObservationIgnored private var replacementDepth = 0

    func attach(_ textView: NSTextView, documentKey: String, initialText: String) {
        let current = currentText()
        let sameDocument = self.documentKey == documentKey
        self.textView = textView
        textView.string = sameDocument ? current : initialText
        guard !sameDocument else { return }
        self.documentKey = documentKey
        detachedText = initialText
        isDirty = false
        lineCount = Self.countLines(in: initialText)
        revision &+= 1
        sourceEditGeneration &+= 1
    }

    func prepare(documentKey: String, text: String) {
        guard self.documentKey != documentKey || (!isDirty && currentText() != text) else { return }
        self.documentKey = documentKey
        detachedText = text
        if textView?.string != text { textView?.string = text }
        isDirty = false
        lineCount = Self.countLines(in: text)
        revision &+= 1
        sourceEditGeneration &+= 1
    }

    func didEdit(lineDelta: Int) {
        isDirty = true
        lineCount = max(1, lineCount + lineDelta)
        revision &+= 1
        if replacementDepth == 0 { sourceEditGeneration &+= 1 }
    }

    func currentText() -> String {
        textView?.string ?? detachedText
    }

    /// Applies an edit from another editor surface to this document's live
    /// source buffer. A delayed callback for a different file is harmless.
    @discardableResult
    func applyReplacement(_ text: String, documentKey: String) -> Bool {
        guard !documentKey.isEmpty, self.documentKey == documentKey else { return false }
        let previous = currentText()
        guard text != previous else { return false }
        replacementDepth += 1
        defer { replacementDepth -= 1 }
        let lineDelta = Self.countLines(in: text) - Self.countLines(in: previous)
        guard let textView else {
            detachedText = text
            didEdit(lineDelta: lineDelta)
            return true
        }
        guard let storage = textView.textStorage else { return false }
        let range = NSRange(location: 0, length: (previous as NSString).length)
        let selection = textView.selectedRanges.map(\.rangeValue)
        textView.breakUndoCoalescing()
        defer { textView.breakUndoCoalescing() }
        guard textView.shouldChangeText(in: range, replacementString: text),
            self.documentKey == documentKey, self.textView === textView
        else { return false }
        let previousRevision = revision
        storage.replaceCharacters(in: range, with: text)
        // This delivers the normal delegate notification, including incremental
        // highlighting and the session's line/revision accounting. AppKit also
        // records the replacement for native source Undo/Redo.
        textView.didChangeText()
        guard self.documentKey == documentKey, self.textView === textView else { return true }
        if revision == previousRevision {
            // A detached test/auxiliary NSTextView may have no session delegate.
            didEdit(lineDelta: lineDelta)
        }
        textView.selectedRanges = selection.map { range in
            let start = min(range.location, storage.length)
            return NSValue(range: NSRange(location: start, length: min(range.length, storage.length - start)))
        }
        return true
    }

    func detach(_ view: NSTextView) {
        guard textView === view else { return }
        detachedText = view.string
        textView = nil
    }

    func markSaved(documentKey: String, submittedText: String, editRevision: Int) {
        guard self.documentKey == documentKey else { return }
        // Acknowledgement advances the server revision in FilesModel. It never
        // replaces the live buffer or marks a successor edit as clean.
        guard revision == editRevision, currentText() == submittedText else { return }
        detachedText = submittedText
        isDirty = false
    }

    nonisolated static func countLines(in text: String) -> Int {
        guard !text.isEmpty else { return 1 }
        return text.utf8.reduce(into: 1) { count, byte in
            if byte == 0x0A { count += 1 }
        }
    }
}
