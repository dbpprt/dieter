import Foundation

/// Identifies raster-image links emitted in a conversation without resolving
/// them against the client machine. The daemon remains responsible for
/// workspace containment and symlink validation when the file is read.
public enum RemoteWorkspaceImage {
    private static let extensions = Set([
        "apng", "avif", "bmp", "gif", "heic", "heif", "ico", "jpeg", "jpg", "png", "tif", "tiff", "webp",
    ])

    public static func isImageURL(_ url: URL) -> Bool {
        extensions.contains((url.path as NSString).pathExtension.lowercased())
    }

    public static func isWorkspaceImageURL(_ url: URL) -> Bool {
        isImageURL(url) && (url.scheme == nil || url.scheme?.lowercased() == "file")
    }

    /// Returns a normalized workspace-relative path suitable for `ReadFile`.
    /// Absolute paths need the workspace root and are handled by the Mac pane's
    /// full link resolver instead.
    public static func relativePath(from url: URL) -> String? {
        guard let encodedPath = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath,
            url.scheme == nil, url.host == nil, !encodedPath.hasPrefix("/"),
            let decoded = encodedPath.removingPercentEncoding,
            !decoded.isEmpty, !decoded.contains("\\"),
            !decoded.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return nil }
        var components: [String] = []
        for component in decoded.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            guard component != ".." else { return nil }
            components.append(String(component))
        }
        guard !components.isEmpty else { return nil }
        let path = components.joined(separator: "/")
        return extensions.contains((path as NSString).pathExtension.lowercased()) ? path : nil
    }

    /// Resolves an absolute remote link using the root returned by
    /// `GetWorkspace`, then returns the path expected by `ReadFile`.
    public static func relativePath(from url: URL, workspaceRoot: String) -> String? {
        if let relative = relativePath(from: url) { return relative }
        guard isWorkspaceImageURL(url), url.host == nil || url.host == "" || url.host?.lowercased() == "localhost",
            let encodedPath = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath,
            let decoded = encodedPath.removingPercentEncoding,
            decoded.hasPrefix("/"), let root = normalizedAbsoluteComponents(workspaceRoot),
            let candidate = normalizedAbsoluteComponents(decoded), candidate.starts(with: root),
            candidate.count > root.count
        else { return nil }
        return candidate.dropFirst(root.count).joined(separator: "/")
    }

    private static func normalizedAbsoluteComponents(_ path: String) -> [String]? {
        guard path.hasPrefix("/"), !path.contains("\\"),
            !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { return nil }
        var components: [String] = []
        for component in path.split(separator: "/") {
            if component == "." { continue }
            if component == ".." {
                guard !components.isEmpty else { return nil }
                components.removeLast()
            } else {
                components.append(String(component))
            }
        }
        return components.isEmpty ? nil : components
    }
}
