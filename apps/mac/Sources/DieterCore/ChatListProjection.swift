import DieterAPI
import Foundation

package struct ChatListProjection: Equatable, Sendable {
    package let visible: [Dieter_V1_Card]
    package let pinned: [Dieter_V1_Card]
    package let byProject: [String: [Dieter_V1_Card]]

    package static func resolve(
        chats: [Dieter_V1_Card],
        showArchived: Bool,
        search: String,
        pinnedOrder: [String]
    ) -> ChatListProjection {
        let visible =
            chats
            .filter { chat in
                chat.scope == "chat" && chat.boardID.isEmpty && chat.archived == showArchived
                    && (search.isEmpty || chat.title.localizedCaseInsensitiveContains(search)
                        || chat.summary.localizedCaseInsensitiveContains(search))
            }
            .sorted {
                let left = $0.lastActivityAt.isEmpty ? $0.updatedAt : $0.lastActivityAt
                let right = $1.lastActivityAt.isEmpty ? $1.updatedAt : $1.lastActivityAt
                return left == right ? $0.id < $1.id : left > right
            }
        let pinned =
            showArchived
            ? []
            : PinnedChatOrdering.ordered(
                visible.filter(\.pinned),
                preferredOrder: pinnedOrder
            )
        let projectChats = showArchived ? visible : visible.filter { !$0.pinned }
        return ChatListProjection(
            visible: visible,
            pinned: pinned,
            byProject: Dictionary(grouping: projectChats, by: \.projectID)
        )
    }
}
