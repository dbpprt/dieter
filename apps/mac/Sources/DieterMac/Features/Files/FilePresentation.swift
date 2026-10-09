import DieterAPI
import DieterShared
import Foundation

/// SF Symbols and renderers for files as the shared core describes them.
enum FilePresentation {
    /// The listing symbol of the core's icon kind for `name`.
    static func symbol(name: String, directory: Bool = false) -> String {
        let kind = ClientFileIconKind(rawValue: Int(SharedRules.shared.fileIconKind(name: name, directory: directory)))
        switch kind {
        case .directory: return "folder.fill"
        case .image: return "photo"
        case .markdown: return "doc.richtext"
        case .code: return "chevron.left.forwardslash.chevron.right"
        default: return "doc.text"
        }
    }

    /// How a document renders: PDF, image, unsupported binary, Markdown, HTML, or text.
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
