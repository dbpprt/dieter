import AppKit
import DieterAPI
import SwiftUI

struct MessageFooterContent: Equatable {
    let timestamp: Date?
    let markdown: String

    init(messages: [Dieter_V1_UiMessage]) {
        if let metadata = messages.last?.metadataJson,
            let values = try? JSONSerialization.jsonObject(with: metadata) as? [String: Any],
            let createdAt = values["createdAt"] as? String
        {
            timestamp = DieterTimestamp.date(from: createdAt)
        } else {
            timestamp = nil
        }
        // Keep the original Markdown, including whitespace and code fences.
        // Attachments and tool previews are separate content, not message prose.
        markdown = messages.flatMap(\.parts).filter { part in
            !ConversationMessagePartGroup.isToolCall(part)
                && !["reasoning", "thinking", "step-start", "file", "attachment", "image"].contains(
                    part.type.lowercased())
                && !part.text.isEmpty
        }.map(\.text).joined(separator: "\n\n")
    }

    var timestampLabel: String {
        timestamp?.formatted(date: .omitted, time: .shortened) ?? "Time unavailable"
    }

    var timestampDescription: String {
        timestamp?.formatted(date: .complete, time: .standard) ?? "Message time unavailable"
    }

    @MainActor @discardableResult
    func copy(to pasteboard: NSPasteboard = .general) -> Bool {
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
                .smokeTarget("conversation.message.timestamp.\(messageID)")

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
            .disabled(content.markdown.isEmpty)
            .accessibilityLabel("Copy message")
            .accessibilityHint("Copies the original message text and Markdown")
            .accessibilityIdentifier("conversation.message.copy.\(messageID)")
            .smokeTarget("conversation.message.copy.\(messageID)")
        }
        .frame(height: 24)
        .background {
            #if DIETER_UI_SMOKE
                if NativeUISmokeTargets.enabled {
                    MessageFooterSmokeProbe(
                        messageID: messageID, timestampVisible: isLatest || showsActions, actionsVisible: showsActions)
                }
            #endif
        }
    }
}

#if DIETER_UI_SMOKE
    /// Read-only observation of the mounted footer. The smoke driver must
    /// deliver native pointer events; this probe cannot change hover state.
    struct MessageFooterSmokeProbe: NSViewRepresentable {
        let messageID: String
        let timestampVisible: Bool
        let actionsVisible: Bool

        final class Anchor: NSView {
            var messageID = ""
            var timestampVisible = false
            var actionsVisible = false
            override func hitTest(_ point: NSPoint) -> NSView? { nil }
        }

        func makeNSView(context: Context) -> Anchor { Anchor() }
        func updateNSView(_ view: Anchor, context: Context) {
            view.messageID = messageID
            view.timestampVisible = timestampVisible
            view.actionsVisible = actionsVisible
        }
    }
#endif
