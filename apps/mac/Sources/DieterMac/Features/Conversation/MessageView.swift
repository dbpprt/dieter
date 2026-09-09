import DieterAPI
import SwiftUI
import UniformTypeIdentifiers

struct MessageView: View {
    @Environment(ConversationContext.self) private var context
    let message: Dieter_V1_UiMessage

    private var deliveryState: MessageDeliveryState {
        MessageDeliveryState(
            pending: context.isPendingMessage(message.id),
            accepted: context.isAcceptedOutboxItem(message.id),
            failed: context.isFailedOutboxItem(message.id),
            queued: context.conversation?.conversation.queue.contains { $0.id == message.id } == true
        )
    }

    var body: some View {
        if message.role == "user" {
            HStack {
                Spacer(minLength: 70)
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(message.parts.enumerated()), id: \.offset) { _, part in
                        MessagePartView(messageID: message.id, part: part, inUserBubble: true)
                    }
                }
                .padding(.leading, 13).padding(.trailing, 18).padding(.vertical, 10)
                .background(
                    DieterTheme.userMessageBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(DieterTheme.strongBorder)
                }
                .frame(maxWidth: 620, alignment: .trailing)
            }
            .overlay(alignment: .bottomTrailing) {
                MessageDeliveryReceipt(state: deliveryState)
                    .padding(.trailing, 4)
                    .padding(.bottom, 4)
            }
            .contextMenu {
                if deliveryState == .failed {
                    Button("Retry queued message") { Task { await context.retryOutboxItem(message.id) } }
                    Button("Discard queued message", role: .destructive) {
                        Task { await context.discardOutboxItem(message.id) }
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(
                    Array(
                        ConversationMessagePartGroup.group(message.parts, showReasoning: context.showReasoning)
                            .enumerated()), id: \.offset
                ) { _, group in
                    if group.isToolCallGroup {
                        ToolCallGroupView(
                            items: group.parts.map {
                                ConversationToolCall(messageID: message.id, part: $0)
                            })
                    } else if let part = group.parts.first {
                        MessagePartView(messageID: message.id, part: part, inUserBubble: false)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct QueuedMessageView: View {
    @Environment(ConversationContext.self) private var context
    let message: Dieter_V1_QueuedMessage
    let canInterrupt: Bool
    @State private var interrupting = false

    private var parts: [Dieter_V1_MessagePart] {
        if !message.parts.isEmpty { return message.parts }
        guard !message.text.isEmpty else { return [] }
        var part = Dieter_V1_MessagePart()
        part.type = "text"
        part.text = message.text
        return [part]
    }

    var body: some View {
        HStack {
            Spacer(minLength: 70)
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Image(systemName: "clock.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(DieterTheme.amber)
                    Text("Queued · sends after this turn")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(DieterTheme.subtle)
                        .lineLimit(1)
                    Spacer(minLength: 12)
                    if canInterrupt {
                        Button {
                            interrupting = true
                            Task { @MainActor in
                                if let card = context.selectedCard ?? context.selectedDetail?.card {
                                    await context.cancel(card)
                                }
                                interrupting = false
                            }
                        } label: {
                            HStack(spacing: 5) {
                                if interrupting {
                                    ProgressView().controlSize(.mini)
                                } else {
                                    Image(systemName: "paperplane.fill")
                                        .font(.system(size: 9, weight: .semibold))
                                }
                                Text(interrupting ? "Sending…" : "Send now")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            .foregroundStyle(DieterTheme.userMessageForeground)
                            .padding(.horizontal, 9)
                            .frame(height: 25)
                            .background(DieterTheme.surface, in: Capsule())
                            .overlay(Capsule().stroke(DieterTheme.strongBorder))
                        }
                        .buttonStyle(.plain)
                        .disabled(interrupting)
                        .help("Interrupt the current turn and send this message now")
                        .accessibilityLabel("Interrupt current turn and send this message now")
                        .accessibilityIdentifier("conversation.queued-message.interrupt.\(message.id)")
                    }
                }
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    MessagePartView(messageID: message.id, part: part, inUserBubble: true)
                }
            }
            .padding(.leading, 13).padding(.trailing, 18).padding(.vertical, 10)
            .background(DieterTheme.userMessageBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(DieterTheme.strongBorder)
            }
            .frame(maxWidth: 620, alignment: .trailing)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("conversation.queued-message.\(message.id)")
    }
}

enum MessageDeliveryState: Equatable {
    case local
    case accepted
    case queued
    case synced
    case failed

    init(pending: Bool, accepted: Bool, failed: Bool, queued: Bool = false) {
        if failed {
            self = .failed
        } else if queued {
            self = .queued
        } else if !pending {
            self = .synced
        } else if accepted {
            self = .accepted
        } else {
            self = .local
        }
    }
}

struct MessageDeliveryReceipt: View {
    let state: MessageDeliveryState

    var body: some View {
        Group {
            switch state {
            case .local:
                Image(systemName: "clock")
            case .accepted:
                Image(systemName: "checkmark")
            case .queued:
                Image(systemName: "clock.badge.checkmark")
            case .synced:
                ZStack {
                    Image(systemName: "checkmark")
                        .offset(x: -2)
                    Image(systemName: "checkmark")
                        .offset(x: 2)
                }
                .frame(width: 14, height: 10)
            case .failed:
                Image(systemName: "exclamationmark.circle.fill")
            }
        }
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(
            state == .failed ? DieterTheme.coral : (state == .queued ? DieterTheme.amber : DieterTheme.tertiary)
        )
        .accessibilityLabel(accessibilityLabel)
        .help(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        switch state {
        case .local: "Waiting to send"
        case .accepted: "Accepted by daemon"
        case .queued: "Queued for the next turn"
        case .synced: "Synced"
        case .failed: "Send failed; use the context menu to retry or discard"
        }
    }
}
