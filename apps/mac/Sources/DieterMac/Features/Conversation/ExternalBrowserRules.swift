import DieterShared
import Foundation

/// Local, user-authored routing rules for the embedded workspace browser,
/// stored on this device; the shared core matches and normalizes them.
enum ExternalBrowserRules {
    static let storageKey = "DieterExternalBrowserURLs"

    static func entries(in defaults: UserDefaults = DieterAppearance.applicationDefaults()) -> [String] {
        defaults.stringArray(forKey: storageKey) ?? []
    }

    static func matches(_ destination: URL, entries: [String]) -> Bool {
        SharedRules.shared.externalBrowserRuleMatches(url: destination.absoluteString, rules: entries)
    }

    /// The rule to store for `input`; nil when the shared core rejects it.
    static func normalized(_ input: String) -> String? {
        let rule = SharedRules.shared.normalizeExternalBrowserRule(input: input)
        return rule.isEmpty ? nil : rule
    }
}
