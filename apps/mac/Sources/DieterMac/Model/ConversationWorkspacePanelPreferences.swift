import Foundation

enum ConversationWorkspacePanelPreferences {
    static let storageKey = "DieterConversationWorkspacePanelEnabled"
    static let defaultEnabled = false

    static func isEnabled(in defaults: UserDefaults = DieterAppearance.applicationDefaults()) -> Bool {
        guard defaults.object(forKey: storageKey) != nil else { return defaultEnabled }
        return defaults.bool(forKey: storageKey)
    }

    static func setEnabled(
        _ enabled: Bool,
        in defaults: UserDefaults = DieterAppearance.applicationDefaults()
    ) {
        defaults.set(enabled, forKey: storageKey)
    }
}
