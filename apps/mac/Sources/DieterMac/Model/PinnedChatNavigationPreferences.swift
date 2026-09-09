import DieterAPI
import Foundation

/// Keeps pinned chats in a user-controlled location instead of allowing new
/// activity timestamps to reshuffle the pinned section.
struct PinnedChatNavigationPreferences: Equatable {
    static let orderKey = "DieterPinnedChatOrder"

    private(set) var chatOrder: [String]

    init(chatOrder: [String] = []) {
        self.chatOrder = Self.unique(chatOrder)
    }

    static func load(from defaults: UserDefaults = .standard) -> Self {
        Self(chatOrder: defaults.stringArray(forKey: orderKey) ?? [])
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(chatOrder, forKey: Self.orderKey)
    }

    @discardableResult
    mutating func initializeIfNeeded(with chatIDs: [String]) -> Bool {
        guard chatOrder.isEmpty else { return false }
        let initialOrder = Self.unique(chatIDs)
        guard !initialOrder.isEmpty else { return false }
        chatOrder = initialOrder
        return true
    }

    @discardableResult
    mutating func move(
        _ chatID: String,
        to targetChatID: String,
        among pinnedChats: [Dieter_V1_Card]
    ) -> Bool {
        let currentOrder = PinnedChatOrdering.ordered(pinnedChats, preferredOrder: chatOrder).map(\.id)
        let nextOrder = PinnedChatOrdering.moving(chatID, to: targetChatID, in: currentOrder)
        guard nextOrder != currentOrder else { return false }
        chatOrder = nextOrder
        return true
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
