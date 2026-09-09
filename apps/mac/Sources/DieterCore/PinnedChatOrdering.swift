import DieterAPI
import Foundation

package enum PinnedChatOrdering {
    package static func ordered(
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
        let remaining =
            chats
            .filter { !seen.contains($0.id) }
            .sorted {
                if $0.position != $1.position { return $0.position < $1.position }
                return $0.id < $1.id
            }
        return preferred + remaining
    }

    package static func moving(_ chatID: String, to targetChatID: String, in chatIDs: [String]) -> [String] {
        guard let sourceIndex = chatIDs.firstIndex(of: chatID),
            let targetIndex = chatIDs.firstIndex(of: targetChatID),
            sourceIndex != targetIndex
        else { return chatIDs }

        var reordered = chatIDs
        reordered.remove(at: sourceIndex)
        reordered.insert(chatID, at: targetIndex)
        return reordered
    }
}
