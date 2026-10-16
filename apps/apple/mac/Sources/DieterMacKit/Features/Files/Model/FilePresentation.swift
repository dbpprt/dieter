import DieterClientAPI
import DieterCore
import Foundation

/// SF Symbols and renderers for files as the shared core describes them.
enum FilePresentation {
    private struct SymbolKey: Hashable, Sendable {
        let name: String
        let directory: Bool
    }

    private static let symbols = SharedRuleMemo<SymbolKey, String>()

    /// The listing symbol of the core's icon kind for `name`. Lists ask for
    /// every row as they render; the core's answer for a name never changes.
    static func symbol(name: String, directory: Bool = false) -> String {
        symbols.value(SymbolKey(name: name, directory: directory)) {
            let kind = ClientFileIconKind(
                rawValue: Int(SharedRules.shared.fileIconKind(name: name, directory: directory)))
            switch kind {
            case .directory: return "folder.fill"
            case .image: return "photo"
            case .markdown: return "doc.richtext"
            case .code: return "chevron.left.forwardslash.chevron.right"
            default: return "doc.text"
            }
        }
    }
}
