import Foundation

enum ConversationDefaultMode: String, CaseIterable, Identifiable {
    case tabs
    case workspace

    static let storageKey = "DieterDefaultConversationMode"

    var id: String { rawValue }

    static func load(from defaults: UserDefaults) -> Self {
        Self(rawValue: defaults.string(forKey: storageKey) ?? "") ?? .tabs
    }

    func save(to defaults: UserDefaults) {
        defaults.set(rawValue, forKey: Self.storageKey)
    }
}
