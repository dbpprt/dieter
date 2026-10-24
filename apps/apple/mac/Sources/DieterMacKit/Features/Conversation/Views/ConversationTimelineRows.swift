import AppKit
import DieterClientAPI
import DieterCore
import SwiftUI

/// One transcript row as the shared core groups it: a user message, an
/// assistant message with its step groups, plans, and delegated agents, or a
/// run of routine work behind one disclosure. It renders only `row` and its
/// resolved `content`, so it skips rendering while another message streams.
struct ConversationTimelineItemView: View, Equatable {
    let row: ClientTimelineItem
    let content: ConversationRowContent
    let isLatest: Bool
    @State private var isHovered = false

    init(row: ClientTimelineItem, content: ConversationRowContent, isLatest: Bool = false) {
        self.row = row
        self.content = content
        self.isLatest = isLatest
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.isLatest == rhs.isLatest && lhs.row == rhs.row && lhs.content == rhs.content
    }

    private var footerMessageID: String { row.messageIds.last ?? row.id }

    var body: some View {
        let footer = MessageFooterContent(row: row, messages: content.messages.timelineMessages(row))
        if row.activity {
            ConversationActivityDisclosure(
                summary: row.summary, identifier: row.id, footer: footer, footerMessageID: footerMessageID,
                isLatest: isLatest
            ) {
                TimelineActivityStepsView(steps: row.groups.flatMap(\.steps), content: content)
            }
        } else {
            VStack(alignment: .leading, spacing: 3) {
                VStack(alignment: .leading, spacing: 15) {
                    if row.user {
                        UserMessageBubble(row: row, messages: content.messages)
                    } else {
                        TimelineStepGroupsView(row: row, content: content)
                    }
                    ForEach(content.plans, id: \.id) {
                        TaskPlanView(plan: $0).equatable()
                    }
                }
                MessageFooter(
                    content: footer, messageID: footerMessageID, isLatest: isLatest, isHovered: isHovered
                )
                .frame(maxWidth: .infinity, alignment: row.user ? .trailing : .leading)
            }
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .accessibilityElement(children: .contain)
            .accessibilityActions {
                if row.copyable {
                    Button("Copy message") { footer.copy() }
                }
            }
            // A row can gain structured details (for example, a task plan) after
            // its message has already been laid out. Preserve the available width
            // while forcing SwiftUI to publish the row's complete updated height,
            // so neither the message nor its details can paint into the next row.
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .e2eTarget("conversation.message.row.\(footerMessageID)", text: footer.markdown)
        }
    }
}

/// An assistant message's step groups: routine work behind disclosures, the
/// rest inline. Long messages open at their last groups; earlier ones reveal
/// on request, and incoming tokens never move that boundary.
struct TimelineStepGroupsView: View {
    let row: ClientTimelineItem
    let content: ConversationRowContent
    @State private var firstVisibleID: String?

    var body: some View {
        let groups = row.groups
        let start = Int(
            SharedRules.shared.timelineVisibleStart(groupIds: groups.map(\.id), fromId: firstVisibleID ?? ""))
        VStack(alignment: .leading, spacing: 10) {
            if start > 0 {
                Button("Show earlier in this message") {
                    let initial = Int(SharedRules.shared.timelineInitialGroups())
                    firstVisibleID = groups[max(0, start - initial)].id
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(DieterTheme.action)
                .accessibilityIdentifier("conversation.message.earlier.\(row.messageIds.first ?? "")")
            }
            ForEach(groups.dropFirst(start), id: \.id) { group in
                if group.activity {
                    ConversationActivityDisclosure(summary: group.summary, identifier: group.id) {
                        TimelineActivityStepsView(steps: group.steps, content: content)
                    }
                } else {
                    ForEach(group.steps, id: \.id) { step in
                        TimelineStepView(
                            step: step, part: content.messages.part(for: step), subagents: content.subagents,
                            inUserBubble: false
                        )
                        .equatable()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: groups.indices.contains(start) ? groups[start].id : nil, initial: true) { _, id in
            // Pin the boundary after mounting. Incoming tokens must not remove
            // prose the reader has already seen or reset disclosure state.
            if firstVisibleID != id { firstVisibleID = id }
        }
    }
}

/// Routine steps shown inside an expanded activity disclosure.
struct TimelineActivityStepsView: View {
    let steps: [ClientTimelineStep]
    let content: ConversationRowContent

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(steps, id: \.id) { step in
                let part = content.messages.part(for: step)
                if step.kind == .reasoning, let part {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Reasoning").font(.caption2.weight(.medium)).foregroundStyle(DieterTheme.tertiary)
                        Text(part.text).font(.caption).foregroundStyle(DieterTheme.subtle).lineSpacing(3)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6)
                } else {
                    TimelineStepView(step: step, part: part, subagents: content.subagents, inUserBubble: false)
                        .equatable()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A user message: its visible steps in a bubble, with its delivery.
struct UserMessageBubble: View {
    @Environment(ConversationContext.self) private var context
    let row: ClientTimelineItem
    let messages: ConversationMessages

    private var messageID: String { row.messageIds.first ?? "" }

    var body: some View {
        HStack {
            Spacer(minLength: 70)
            VStack(alignment: .leading, spacing: 7) {
                if !row.originLabel.isEmpty {
                    // A turn an agent channel message started, not the user.
                    Label(row.originLabel, systemImage: "number")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(DieterTheme.action)
                        .accessibilityIdentifier("conversation.message.origin.\(messageID)")
                }
                ForEach(row.groups.flatMap(\.steps), id: \.id) { step in
                    TimelineStepView(step: step, part: messages.part(for: step), inUserBubble: true)
                        .equatable()
                }
                if row.delivery == .failed {
                    HStack(spacing: 8) {
                        Label("Send failed", systemImage: "exclamationmark.circle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(DieterTheme.coral)
                        Spacer(minLength: 8)
                        Button("Retry") { Task { await context.retryOutboxItem(messageID) } }
                            .buttonStyle(DieterBarButtonStyle(size: 24))
                        Button("Remove", role: .destructive) {
                            Task { await context.discardOutboxItem(messageID) }
                        }
                        .buttonStyle(DieterBarButtonStyle(destructive: true, size: 24))
                        .accessibilityIdentifier("conversation.failed-message.remove.\(messageID)")
                    }
                }
            }
            .padding(.leading, 14).padding(.trailing, 18).padding(.vertical, 9)
            .background(
                DieterTheme.userMessageBackground,
                in: RoundedRectangle(cornerRadius: DieterMetrics.bubbleRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: DieterMetrics.bubbleRadius, style: .continuous)
                    .strokeBorder(DieterTheme.tileRim)
            }
            .frame(maxWidth: 620, alignment: .trailing)
        }
        .opacity(row.unconfirmed && row.delivery != .failed ? 0.52 : 1)
        .overlay(alignment: .bottomTrailing) {
            if row.delivery != .failed, row.delivery != .unspecified {
                MessageDeliveryReceipt(delivery: row.delivery, label: row.deliveryLabel)
                    .padding(.trailing, 4)
                    .padding(.bottom, 4)
            }
        }
        .contextMenu {
            if row.delivery == .failed {
                Button("Retry queued message") { Task { await context.retryOutboxItem(messageID) } }
                Button("Remove failed message", role: .destructive) {
                    Task { await context.discardOutboxItem(messageID) }
                }
            }
        }
    }
}

/// A user message's delivery, as the core reports it.
struct MessageDeliveryReceipt: View {
    let delivery: ClientMessageDelivery
    /// What the receipt says, as the core words it.
    let label: String

    var body: some View {
        Group {
            switch delivery {
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
            default:
                Image(systemName: "clock")
            }
        }
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(
            delivery == .failed
                ? DieterTheme.coral : (delivery == .queued ? DieterTheme.amber : DieterTheme.tertiary)
        )
        .accessibilityLabel(label)
        .help(label)
    }
}
