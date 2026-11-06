import DieterAPI
import Foundation

enum ConversationPresentedContent {
    /// A presentation path is data, not URL syntax. Encode names such as
    /// `notes #1.md` before passing them through the regular link resolver.
    static func url(for value: Dieter_V1_ContentPresentation) -> URL? {
        guard value.line >= 0, value.path.isEmpty != value.url.isEmpty else { return nil }
        if !value.url.isEmpty {
            guard let url = URL(string: value.url),
                ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                url.host?.isEmpty == false
            else { return nil }
            return url
        }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: ":?#%")
        guard let encoded = value.path.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        var components = URLComponents()
        if value.path.hasPrefix("/") {
            components.scheme = "file"
            components.percentEncodedPath = encoded
        } else {
            components.percentEncodedPath = "./" + encoded
        }
        if value.line > 0 { components.fragment = "L\(value.line)" }
        return components.url
    }
}
