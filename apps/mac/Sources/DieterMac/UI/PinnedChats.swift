import AppKit
import DieterAPI
import SwiftUI
import UniformTypeIdentifiers

struct PinnedChatRow: View {
    let card: Dieter_V1_Card
    let moveDraggedChat: (String) -> Void
    @State private var dropTargeted = false

    var body: some View {
        ChatRow(card: card, showsPinnedDragHandle: true)
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(dropTargeted ? DieterTheme.shell : .clear, lineWidth: 1.5)
                    .padding(.horizontal, 1)
                    .allowsHitTesting(false)
            }
            .dropDestination(for: String.self) { values, _ in
                guard let value = values.first,
                    let payload = PinnedChatDragPayload(value),
                    payload.chatID != card.id
                else { return false }
                moveDraggedChat(payload.chatID)
                return true
            } isTargeted: {
                dropTargeted = $0
            }
            .animation(.easeOut(duration: 0.12), value: dropTargeted)
            .accessibilityHint("Drag to reorder pinned chats")
    }
}

struct PinnedChatDragPreview: View {
    let card: Dieter_V1_Card

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "pin.fill").foregroundStyle(DieterTheme.shell)
            Text(card.title.isEmpty ? "Untitled chat" : card.title)
                .font(.system(size: 12, weight: .semibold)).lineLimit(1)
        }
        .padding(.horizontal, 12).frame(width: 220, height: 40, alignment: .leading)
        .background(DieterTheme.elevated, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(DieterTheme.shell.opacity(0.4))
        )
        .shadow(color: Color.black.opacity(0.4), radius: 14, y: 7)
    }
}

struct PinnedChatDragPayload: Equatable {
    private static let prefix = "dieter:pinned-chat:"
    let chatID: String

    init(chatID: String) {
        self.chatID = chatID
    }

    init?(_ encoded: String) {
        guard encoded.hasPrefix(Self.prefix) else { return nil }
        let chatID = String(encoded.dropFirst(Self.prefix.count))
        guard !chatID.isEmpty else { return nil }
        self.chatID = chatID
    }

    var encoded: String { Self.prefix + chatID }
}
