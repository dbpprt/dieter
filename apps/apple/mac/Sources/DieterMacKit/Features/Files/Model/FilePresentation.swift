import DieterClientAPI
import DieterCore
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
}
