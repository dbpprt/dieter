import Foundation

/// A link opened in the conversation's content pane. File paths are relative
/// to the conversation workspace, never to this client's working directory.
enum ConversationContentLink: Equatable, Sendable {
    case file(path: String, line: Int?)
    case web(URL)

    /// `relativeTo` is the current document's workspace-relative (or absolute)
    /// file path. Remote paths are resolved lexically here; the owning daemon
    /// still performs its authoritative containment and symlink checks.
    static func resolve(
        _ url: URL,
        workspaceRoot: String,
        relativeTo documentPath: String? = nil
    ) throws -> Self {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw ResolutionError.invalidLink
        }
        let scheme = components.scheme?.lowercased()
        if scheme == "http" || scheme == "https" {
            guard let host = components.host, !host.isEmpty else {
                throw ResolutionError.invalidWebURL
            }
            return .web(url)
        }

        var encodedPath = components.percentEncodedPath
        switch scheme {
        case nil:
            guard components.host == nil else { throw ResolutionError.unsupportedFileHost }
        case "file":
            guard components.host == nil || components.host == "" || components.host?.lowercased() == "localhost" else {
                throw ResolutionError.unsupportedFileHost
            }
            guard encodedPath.hasPrefix("/") else { throw ResolutionError.invalidLink }
        default:
            // Foundation treats a bare `README.md:12` as a URL scheme. Accept
            // that file/line notation without accepting arbitrary schemes.
            let rawPath = url.relativeString.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0]
            guard components.scheme?.contains(".") == true,
                !rawPath.contains("://"), lineSuffix(in: String(rawPath)) != nil
            else { throw ResolutionError.unsupportedScheme(components.scheme ?? "") }
            encodedPath = String(rawPath)
        }

        let suffix = lineSuffix(in: encodedPath)
        if let suffix { encodedPath = String(encodedPath[..<suffix.range.lowerBound]) }
        guard let path = encodedPath.removingPercentEncoding else { throw ResolutionError.invalidLink }
        let line = try fragmentLine(components.fragment) ?? suffix.map { try positiveLine($0.line) }
        if let column = suffix?.column { _ = try positiveLine(column) }

        let root = try workspaceComponents(workspaceRoot)
        let document = try documentPath.map { try resolvePath($0, root: root, base: root) }
        // A fragment-only link refers to the current document, when there is one.
        let resolved: [String]
        if path.isEmpty, components.fragment != nil, let document {
            resolved = document
        } else {
            let base = document.map { Array($0.dropLast()) } ?? root
            resolved = try resolvePath(path, root: root, base: base)
        }
        guard resolved.count > root.count else { throw ResolutionError.invalidLink }
        return .file(path: resolved.dropFirst(root.count).joined(separator: "/"), line: line)
    }

    enum ResolutionError: LocalizedError, Equatable {
        case invalidLink
        case invalidWebURL
        case invalidWorkspace
        case outsideWorkspace
        case unsupportedFileHost
        case unsupportedScheme(String)
        case invalidLine

        var errorDescription: String? {
            switch self {
            case .invalidLink: "This link does not identify a workspace file."
            case .invalidWebURL: "This web link is missing a hostname."
            case .invalidWorkspace: "The conversation's workspace path is unavailable."
            case .outsideWorkspace: "This file is outside the conversation's workspace."
            case .unsupportedFileHost: "This file link points to a different machine."
            case .unsupportedScheme(let scheme): "Links using \(scheme): cannot be opened in this pane."
            case .invalidLine: "This file link has an invalid line or column number."
            }
        }
    }

    private static func workspaceComponents(_ path: String) throws -> [String] {
        guard path.hasPrefix("/"), validPath(path) else { throw ResolutionError.invalidWorkspace }
        var result: [String] = []
        for component in path.split(separator: "/") {
            if component == "." { continue }
            if component == ".." {
                guard !result.isEmpty else { throw ResolutionError.invalidWorkspace }
                result.removeLast()
            } else {
                result.append(String(component))
            }
        }
        return result
    }

    private static func resolvePath(_ path: String, root: [String], base: [String]) throws -> [String] {
        guard !path.isEmpty, validPath(path) else { throw ResolutionError.invalidLink }
        if path.hasPrefix("/") {
            let result = try workspaceComponents(path)
            guard result.starts(with: root) else { throw ResolutionError.outsideWorkspace }
            return result
        }
        var result = base
        for component in path.split(separator: "/") {
            if component == "." { continue }
            if component == ".." {
                guard result.count > root.count else { throw ResolutionError.outsideWorkspace }
                result.removeLast()
            } else {
                result.append(String(component))
            }
        }
        return result
    }

    private static func validPath(_ path: String) -> Bool {
        !path.contains("\\") && !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private struct LineSuffix {
        let range: Range<String.Index>
        let line: String
        let column: String?
    }

    private static func lineSuffix(in path: String) -> LineSuffix? {
        guard let range = path.range(of: #":[0-9]+(?::[0-9]+)?$"#, options: .regularExpression) else { return nil }
        let numbers = path[range].dropFirst().split(separator: ":")
        return LineSuffix(range: range, line: String(numbers[0]), column: numbers.count > 1 ? String(numbers[1]) : nil)
    }

    private static func fragmentLine(_ fragment: String?) throws -> Int? {
        guard let fragment, fragment.range(of: #"^L[0-9]+(?:-L?[0-9]+)?$"#, options: .regularExpression) != nil else {
            return nil
        }
        let values = fragment.dropFirst().split(separator: "-", maxSplits: 1)
        let line = try positiveLine(String(values[0]))
        if values.count > 1 {
            let end = try positiveLine(String(values[1].drop(while: { $0 == "L" })))
            guard end >= line else { throw ResolutionError.invalidLine }
        }
        return line
    }

    private static func positiveLine(_ value: String) throws -> Int {
        guard let line = Int(value), line > 0 else { throw ResolutionError.invalidLine }
        return line
    }
}
