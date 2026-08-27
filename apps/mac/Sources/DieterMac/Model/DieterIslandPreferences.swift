import Foundation

enum DieterIslandPreferences {
    static let enabledKey = "DieterIslandEnabled"
    static let defaultEnabled = true

    static func isEnabled(in defaults: UserDefaults = DieterAppearance.applicationDefaults()) -> Bool {
        guard defaults.object(forKey: enabledKey) != nil else { return defaultEnabled }
        return defaults.bool(forKey: enabledKey)
    }

    static func setEnabled(
        _ enabled: Bool,
        in defaults: UserDefaults = DieterAppearance.applicationDefaults()
    ) {
        defaults.set(enabled, forKey: enabledKey)
    }
}
