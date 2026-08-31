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

enum PinnedChatOrdering {
    static func ordered(
        _ chats: [Dieter_V1_Card],
        preferredOrder: [String]
    ) -> [Dieter_V1_Card] {
        guard chats.count > 1, !preferredOrder.isEmpty else { return chats }

        let chatsByID = Dictionary(uniqueKeysWithValues: chats.map { ($0.id, $0) })
        var seen: Set<String> = []
        let preferred = preferredOrder.compactMap { chatID -> Dieter_V1_Card? in
            guard seen.insert(chatID).inserted else { return nil }
            return chatsByID[chatID]
        }
        let remaining = chats
            .filter { !seen.contains($0.id) }
            .sorted {
                if $0.position != $1.position { return $0.position < $1.position }
                return $0.id < $1.id
            }
        return preferred + remaining
    }

    static func moving(_ chatID: String, to targetChatID: String, in chatIDs: [String]) -> [String] {
        guard let sourceIndex = chatIDs.firstIndex(of: chatID),
              let targetIndex = chatIDs.firstIndex(of: targetChatID),
              sourceIndex != targetIndex else { return chatIDs }

        var reordered = chatIDs
        reordered.remove(at: sourceIndex)
        reordered.insert(chatID, at: targetIndex)
        return reordered
    }
}
