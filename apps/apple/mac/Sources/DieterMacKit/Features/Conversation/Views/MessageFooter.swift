import AppKit
import DieterClientAPI
import DieterCore
import SwiftUI

/// A row's time and copy action: the core says when its last message was
/// written and whether it has prose; copying asks the core for that prose.
struct MessageFooterContent {
    let timestamp: Date?
    let copyable: Bool
    private let messages: ClientTimelineMessages

    init(row: ClientTimelineItem, messages: ClientTimelineMessages) {
        timestamp = Date(epochMillis: row.createdAtMillis)
        copyable = row.copyable
        self.messages = messages
    }

    var timestampLabel: String {
        timestamp?.formatted(date: .omitted, time: .shortened) ?? "Time unavailable"
    }

    var timestampDescription: String {
        timestamp?.formatted(date: .complete, time: .standard) ?? "Message time unavailable"
    }

    /// The row's prose as written, joined by blank lines.
    var markdown: String {
        guard copyable else { return "" }
        return SharedRules.shared.doCopyText(messages: messages.rulesData)
    }

    @MainActor @discardableResult
    func copy(to pasteboard: NSPasteboard = .general) -> Bool {
        let markdown = markdown
        guard !markdown.isEmpty else { return false }
        pasteboard.clearContents()
        return pasteboard.setString(markdown, forType: .string)
    }
}

/// A reserved footer keeps the timeline still while its hover actions appear.
struct MessageFooter: View {
    let content: MessageFooterContent
    let messageID: String
    let isLatest: Bool
    let isHovered: Bool
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @FocusState private var copyFocused: Bool

    private var showsActions: Bool { isHovered || copyFocused || voiceOverEnabled }

    var body: some View {
        HStack(spacing: 6) {
            Text(content.timestampLabel)
                .font(.caption2)
                .foregroundStyle(DieterTheme.tertiary)
                .monospacedDigit()
                .lineLimit(1)
                .textSelection(.disabled)
                .quickHelp(content.timestampDescription)
                .opacity(isLatest || showsActions ? 1 : 0)
                .accessibilityLabel(content.timestampDescription)
                .accessibilityHidden(!isLatest && !showsActions)
                .accessibilityIdentifier("conversation.message.timestamp.\(messageID)")
                .e2eTarget("conversation.message.timestamp.\(messageID)")

            Button {
                content.copy()
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 11))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .focused($copyFocused)
            .foregroundStyle(DieterTheme.tertiary)
            .quickHelp("Copy")
            .opacity(showsActions ? 1 : 0)
            .allowsHitTesting(showsActions)
            .disabled(!content.copyable)
            .accessibilityLabel("Copy message")
            .accessibilityHint("Copies the original message text and Markdown")
            .accessibilityIdentifier("conversation.message.copy.\(messageID)")
            .e2eTarget("conversation.message.copy.\(messageID)")
        }
        .frame(height: 24)
    }
}
