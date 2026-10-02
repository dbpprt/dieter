import DieterAPI
import DieterShared
import Foundation

/// A link opened in the conversation's content pane. File paths are relative
/// to the conversation workspace, never to this client's working directory.
enum ConversationContentLink: Equatable, Sendable {
    case file(path: String, line: Int?)
    case web(URL)

    /// `relativeTo` is the current document's workspace-relative (or absolute)
    /// file path. The shared core resolves remote paths lexically; the owning
    /// daemon still performs its authoritative containment and symlink checks.
    static func resolve(
        _ url: URL,
        workspaceRoot: String,
        relativeTo documentPath: String? = nil
    ) throws -> Self {
        let resolution = ClientContentLinkResolution(
            rules: SharedRules.shared.resolveContentLink(
                url: url.relativeString, workspaceRoot: workspaceRoot, relativeTo: documentPath ?? ""))
        switch resolution.result {
        case .file(let file): return .file(path: file.path, line: file.line > 0 ? Int(file.line) : nil)
        case .webURL: return .web(url)
        case .failure(let failure): throw ResolutionError(message: failure.message)
        case nil: throw ResolutionError(message: "This link does not identify a workspace file.")
        }
    }

    /// Whether `url` is a web link, valid or missing its host, as the core
    /// classifies links outside any workspace.
    static func isWeb(_ url: URL) -> Bool {
        let resolution = ClientContentLinkResolution(
            rules: SharedRules.shared.resolveContentLink(url: url.relativeString, workspaceRoot: "", relativeTo: ""))
        switch resolution.result {
        case .webURL: return true
        case .failure(let failure): return failure.kind == .invalidWebURL
        default: return false
        }
    }

    /// Why a link cannot open, in the core's words.
    struct ResolutionError: LocalizedError, Equatable {
        let message: String
        var errorDescription: String? { message }
    }
}
