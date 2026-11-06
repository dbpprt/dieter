import AppKit
import DieterCore
import Foundation
import Observation
import DieterPlatform

/// Owns the live AppKit editor buffer. Observable UI state stays small while
/// the full document string crosses into the store only at open/save
/// boundaries.
@MainActor
@Observable
final class FileEditorSession {
    private(set) var documentKey = ""
    private(set) var isDirty = false
    private(set) var lineCount = 1
    /// Native rich layout is whole-document; source mode preserves large drafts.
    private(set) var usesLargeDocumentMode = false
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
        updatePresentationBudget(length: (initialText as NSString).length, openedText: initialText)
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
        updatePresentationBudget(length: (text as NSString).length, openedText: text)
        revision &+= 1
        sourceEditGeneration &+= 1
    }

    func didEdit(lineDelta: Int) {
        if !isDirty { isDirty = true }
        if lineDelta != 0 { lineCount = max(1, lineCount + lineDelta) }
        updatePresentationBudget(length: textView?.textStorage?.length ?? (detachedText as NSString).length)
        revision &+= 1
        if replacementDepth == 0 { sourceEditGeneration &+= 1 }
    }

    private func updatePresentationBudget(length: Int, openedText: String? = nil) {
        // Stay in source mode after shrinking a draft: replacing the editor
        // while typing would throw away its selection and undo history.
        var large = length > FileSyntaxHighlightPlan.limit || lineCount > 4_000
        if !large, let openedText {
            var lineLength = 0
            for unit in openedText.utf16 {
                lineLength = unit == 10 || unit == 13 ? 0 : lineLength + 1
                if lineLength > FileSyntaxHighlightPlan.lineLimit { large = true; break }
            }
        }
        usesLargeDocumentMode = large || (openedText == nil && usesLargeDocumentMode)
    }

    func currentText() -> String {
        textView?.string ?? detachedText
    }

    /// Applies an edit from another editor surface to this document's live
    /// source buffer. A delayed callback for a different file is harmless.
    @discardableResult
    func applyReplacement(_ text: String, documentKey: String) -> Bool {
        guard !documentKey.isEmpty, self.documentKey == documentKey,
            // Only the span that differs is replaced, so the source buffer's
            // layout, undo record, and highlighting cover the edit, not the document.
            let change = FileSourceChange(from: currentText(), to: text)
        else { return false }
        replacementDepth += 1
        defer { replacementDepth -= 1 }
        guard let textView else {
            detachedText = text
            didEdit(lineDelta: change.lineDelta)
            return true
        }
        guard let storage = textView.textStorage else { return false }
        let selection = textView.selectedRanges.map(\.rangeValue)
        textView.breakUndoCoalescing()
        defer { textView.breakUndoCoalescing() }
        guard textView.shouldChangeText(in: change.range, replacementString: change.replacement),
            self.documentKey == documentKey, self.textView === textView
        else { return false }
        let previousRevision = revision
        storage.replaceCharacters(in: change.range, with: change.replacement)
        // This delivers the normal delegate notification, including incremental
        // highlighting and the session's line/revision accounting. AppKit also
        // records the replacement for native source Undo/Redo.
        textView.didChangeText()
        guard self.documentKey == documentKey, self.textView === textView else { return true }
        if revision == previousRevision {
            // A detached test/auxiliary NSTextView may have no session delegate.
            didEdit(lineDelta: change.lineDelta)
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

    /// Lines as the shared core counts them.
    nonisolated static func countLines(in text: String) -> Int {
        Int(SharedRules.shared.fileLineCount(text: text))
    }
}

extension FileEditorSession: FileEditorBuffer {}

/// The span an edit replaced in a document, in UTF-16 units as NSString
/// counts them: what lies between the text both versions start and end with.
struct FileSourceChange: Equatable {
    let range: NSRange
    let replacement: String
    /// Lines the edit added (or removed), as the core counts lines: by line feeds.
    let lineDelta: Int

    /// The edit from `previous` to `next`; nil when they are the same text.
    init?(from previous: String, to next: String) {
        let old = Self.units(of: previous)
        let new = Self.units(of: next)
        guard old != new else { return nil }
        let shared = min(old.count, new.count)
        var prefix = 0
        while prefix < shared, old[prefix] == new[prefix] { prefix += 1 }
        // A boundary never splits a surrogate pair, so both sides stay valid text.
        if prefix > 0, UTF16.isLeadSurrogate(old[prefix - 1]) { prefix -= 1 }
        var suffix = 0
        while suffix < shared - prefix, old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
        if suffix > 0, UTF16.isTrailSurrogate(old[old.count - suffix]) { suffix -= 1 }
        let removed = old[prefix..<(old.count - suffix)]
        let inserted = new[prefix..<(new.count - suffix)]
        range = NSRange(location: prefix, length: removed.count)
        replacement = String(decoding: inserted, as: UTF16.self)
        lineDelta = inserted.lazy.filter { $0 == 0x0A }.count - removed.lazy.filter { $0 == 0x0A }.count
    }

    /// The text's UTF-16 units, copied in bulk: a text view's buffer bridges
    /// as UTF-16, which comparing or indexing it as a String would decode.
    private static func units(of text: String) -> [unichar] {
        let string = text as NSString
        let length = string.length
        var units = [unichar](repeating: 0, count: length)
        string.getCharacters(&units, range: NSRange(location: 0, length: length))
        return units
    }
}

/// A files surface whose editor buffer is the Mac's AppKit text view.
typealias FilesModel = FilesSurfaceModel<FileEditorSession>
