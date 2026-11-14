import Foundation

enum DieterIslandPreferences {
    static let enabledKey = "DieterIslandEnabled"
    static let displayKey = "DieterIslandDisplayUUID"
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

    static func displayID(in defaults: UserDefaults = DieterAppearance.applicationDefaults()) -> String? {
        guard let value = defaults.string(forKey: displayKey), !value.isEmpty else { return nil }
        return value
    }

    /// A disconnected preference is retained so reconnecting restores the chosen display.
    static func setDisplayID(
        _ id: String?, in defaults: UserDefaults = DieterAppearance.applicationDefaults()
    ) {
        if let id, !id.isEmpty {
            defaults.set(id, forKey: displayKey)
        } else {
            defaults.removeObject(forKey: displayKey)
        }
    }
}
