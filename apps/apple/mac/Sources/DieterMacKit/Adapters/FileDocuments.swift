import DieterAPI
import DieterClientAPI
import DieterCore
import Foundation

// The files surface's document (dieter.v1 FileDocument, from ClientFilesSlice)
// as the Mac renders and exports it.

extension FilePresentation {
    /// How a document renders: PDF, image, unsupported binary, Markdown, or text.
    static func renderer(_ document: Dieter_V1_FileDocument) -> ClientFileRenderer {
        let value = SharedRules.shared.fileRenderer(
            path: document.name, mimeType: document.mimeType, binary: document.binary)
        return ClientFileRenderer(rawValue: Int(value)) ?? .unsupported
    }
}

extension Dieter_V1_FileDocument {
    /// The document's bytes: its data, or its text as UTF-8.
    var bytes: Data { binary ? data : Data(content.utf8) }
}

extension FileExternalActions {
    @MainActor
    static func exportBytes(document: Dieter_V1_FileDocument, session: FileEditorSession, documentKey: String) -> Data {
        if !document.binary, session.documentKey == documentKey { return Data(session.currentText().utf8) }
        return document.bytes
    }

    @MainActor
    static func markdownExportDocument(
        document: Dieter_V1_FileDocument, session: FileEditorSession, documentKey: String
    ) -> MarkdownFileExport.Document? {
        guard FilePresentation.renderer(document) == .markdown,
            !documentKey.isEmpty, session.documentKey == documentKey
        else { return nil }
        return MarkdownFileExport.Document(name: document.name, source: session.currentText())
    }
}
