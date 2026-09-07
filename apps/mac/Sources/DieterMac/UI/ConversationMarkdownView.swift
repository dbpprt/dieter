import SwiftUI

struct ConversationMarkdownView: View {
    let source: String
    let inUserBubble: Bool

    var body: some View {
        SelectableMessageText(
            source: source,
            color: inUserBubble ? DieterTheme.userMessageForeground : DieterTheme.text
        )
    }
}
