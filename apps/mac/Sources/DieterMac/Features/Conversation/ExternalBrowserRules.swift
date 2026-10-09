import DieterShared
import Foundation

/// Local, user-authored routing rules for the embedded workspace browser,
/// stored on this device; the shared core matches and normalizes them.
enum ExternalBrowserRules {
    static let storageKey = "DieterExternalBrowserURLs"

    static func entries(in defaults: UserDefaults = DieterAppearance.applicationDefaults()) -> [String] {
        defaults.stringArray(forKey: storageKey) ?? []
    }

    /// The user's rules, plus pages the shared core sends to the system
    /// browser because they need the user's own session (Claude Design), which
    /// a private workspace browser tab never has.
    static func matches(_ destination: URL, entries: [String]) -> Bool {
        SharedRules.shared.externalBrowserRuleMatches(url: destination.absoluteString, rules: entries)
            || systemBrowserNotice(destination) != nil
    }

    /// Whether `destination` opens in a workspace tab signed in to claude.ai:
    /// a Claude artifact or design that the user's rules leave in Dieter.
    static func usesClaudeSession(_ destination: URL, entries: [String]) -> Bool {
        SharedRules.shared.isClaudeDesign(url: destination.absoluteString)
            && !SharedRules.shared.externalBrowserRuleMatches(url: destination.absoluteString, rules: entries)
    }

    /// Where a browser tab in `session` hands `destination` to the system
    /// browser. A claude.ai tab stays on claude.ai pages the user's rules leave
    /// in Dieter, so its signed-in session never reaches another site.
    static func opensExternally(_ destination: URL, session: ConversationBrowserSession, entries: [String]) -> Bool {
        switch session {
        case .ephemeral: matches(destination, entries: entries)
        case .claude:
            !SharedRules.shared.isClaudeAccountPage(url: destination.absoluteString)
                || SharedRules.shared.externalBrowserRuleMatches(url: destination.absoluteString, rules: entries)
        }
    }

    /// Why `destination` always opens in the system browser; nil when the
    /// workspace browser may show it.
    static func systemBrowserNotice(_ destination: URL) -> String? {
        let notice = SharedRules.shared.systemBrowserNotice(url: destination.absoluteString)
        return notice.isEmpty ? nil : notice
    }

    /// The rule to store for `input`; nil when the shared core rejects it.
    static func normalized(_ input: String) -> String? {
        let rule = SharedRules.shared.normalizeExternalBrowserRule(input: input)
        return rule.isEmpty ? nil : rule
    }
}
