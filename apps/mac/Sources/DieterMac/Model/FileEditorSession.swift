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
    @ObservationIgnored private weak var textView: NSTextView?
    @ObservationIgnored private var detachedText = ""

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
    }

    func prepare(documentKey: String, text: String) {
        guard self.documentKey != documentKey || (!isDirty && currentText() != text) else { return }
        self.documentKey = documentKey
        detachedText = text
        if textView?.string != text { textView?.string = text }
        isDirty = false
        lineCount = Self.countLines(in: text)
        revision &+= 1
    }

    func didEdit(lineDelta: Int) {
        isDirty = true
        lineCount = max(1, lineCount + lineDelta)
        revision &+= 1
    }

    func currentText() -> String {
        textView?.string ?? detachedText
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
