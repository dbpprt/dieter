import DieterAPI
import SwiftUI

struct InboxView: View {
    var active = true
    @Environment(DieterStore.self) private var store

    var body: some View {
        ChatPaneSplit(layout: .inbox) {
            InboxFeed { card in
                guard (store.selectedCardID ?? store.selectedChatID) != card.id else { return }
                Task { await store.openConversation(cardID: card.id, chat: card.scope == "chat", fromInbox: true) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("inbox.browser-pane")
            .smokeTarget("inbox.browser-pane")
        } detail: {
            if active { InboxDetailPane() }
        }
        .defaultAppStorage(store.environment.defaults)
    }
}

private struct InboxDetailPane: View {
    @Environment(DieterStore.self) private var store

    var body: some View {
        if (store.selectedCardID ?? store.selectedChatID) != nil {
            ConversationView(compact: true, surfaceStyle: .inherited)
                .environment(store.conversationContext)
        } else {
            VStack(spacing: 14) {
                Image(systemName: "tray")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(DieterTheme.shell)
                    .frame(width: 70, height: 70)
                    .background(DieterTheme.shell.opacity(0.08), in: RoundedRectangle(cornerRadius: 20))
                Text("Your work, in focus")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(DieterTheme.text)
                Text(
                    "Select a card or chat to pick up the conversation.\nYour messages, files and changes are all here."
                )
                .font(.system(size: 13))
                .foregroundStyle(DieterTheme.subtle)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("inbox.empty-detail")
            .smokeTarget("inbox.empty-detail")
        }
    }
}
