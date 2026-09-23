import Foundation

/// Local, user-authored routing rules for the embedded workspace browser.
/// A bare host matches only that host; `*.host` also matches its subdomains.
/// A full HTTP(S) URL matches its host and a path-segment-bounded prefix.
enum ExternalBrowserRules {
    static let storageKey = "DieterExternalBrowserURLs"

    static func entries(in defaults: UserDefaults = DieterAppearance.applicationDefaults()) -> [String] {
        defaults.stringArray(forKey: storageKey) ?? []
    }

    static func matches(_ destination: URL, entries: [String]) -> Bool {
        guard let scheme = destination.scheme?.lowercased(), ["http", "https"].contains(scheme),
            let host = destination.host?.lowercased()
        else { return false }
        return entries.contains { entry in
            let rule = entry.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let url = URL(string: rule), let ruleScheme = url.scheme, let ruleHost = url.host {
                guard ruleScheme == scheme, ruleHost == host, url.port == destination.port else { return false }
                let path = url.path.isEmpty ? "/" : url.path
                return path == "/" || destination.path == path || destination.path.hasPrefix(path + "/")
            }
            if rule.hasPrefix("*.") {
                let suffix = String(rule.dropFirst(2))
                return host == suffix || host.hasSuffix("." + suffix)
            }
            return host == rule
        }
    }

    static func normalized(_ input: String) -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty, value.count <= 512 else { return nil }
        if value.contains("://") {
            guard let url = URLComponents(string: value), ["http", "https"].contains(url.scheme ?? ""),
                let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
                url.query == nil, url.fragment == nil
            else { return nil }
            return url.url?.absoluteString
        }
        let host = value.hasPrefix("*.") ? String(value.dropFirst(2)) : value
        guard host.contains("."), !host.hasPrefix("."), !host.hasSuffix("."),
            host.unicodeScalars.allSatisfy({
                CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-.").contains($0)
            })
        else { return nil }
        return value
    }
}
