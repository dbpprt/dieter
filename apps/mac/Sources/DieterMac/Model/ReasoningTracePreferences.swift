import Foundation

enum ReasoningTracePreferences {
    static let storageKey = "DieterShowReasoningTraces"

    static func load(from defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: storageKey)
    }

    static func save(_ showReasoning: Bool, to defaults: UserDefaults = .standard) {
        defaults.set(showReasoning, forKey: storageKey)
    }
}
