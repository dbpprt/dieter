import DieterAPI
import SwiftUI

/// The same native disclosure is used between messages and inside a mixed
/// assistant message. Its content is constructed only while expanded.
struct ConversationActivityDisclosure<Content: View>: View {
    let summary: ConversationActivitySummary
    let identifier: String
    var footer: MessageFooterContent? = nil
    var footerMessageID = ""
    var isLatest = false
    let content: () -> Content
    @State private var expanded = false
    @State private var hovered = false

    init(
        summary: ConversationActivitySummary, identifier: String,
        footer: MessageFooterContent? = nil, footerMessageID: String = "", isLatest: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.summary = summary
        self.identifier = identifier
        self.footer = footer
        self.footerMessageID = footerMessageID
        self.isLatest = isLatest
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            DisclosureGroup(isExpanded: $expanded) {
                if expanded {
                    content()
                        .padding(.top, 6)
                        .padding(.bottom, 3)
                        .smokeTarget("conversation.activity.\(identifier).content")
                }
            } label: {
                Text(summary.title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(DieterTheme.subtle)
                    .lineLimit(2)
                    .textSelection(.disabled)
                    .smokeTarget("conversation.activity.\(identifier).label")
            }
            .disclosureGroupStyle(ConversationActivityDisclosureStyle(identifier: identifier))
            .tint(DieterTheme.tertiary)
            .accessibilityIdentifier("conversation.activity.\(identifier)")
            .accessibilityLabel(summary.title)
            .smokeTarget("conversation.activity.\(identifier)")

            if let footer, !expanded {
                MessageFooter(
                    content: footer, messageID: footerMessageID,
                    isLatest: isLatest, isHovered: hovered)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
    }
}

/// One native button owns the complete header, avoiding the platform disclosure's
/// separate arrow hit area and the transcript's text-selection gesture.
private struct ConversationActivityDisclosureStyle: DisclosureGroupStyle {
    let identifier: String

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) { configuration.isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                    configuration.label
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                .contentShape(Rectangle())
                .textSelection(.disabled)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("conversation.activity.\(identifier).toggle")
            .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
            if configuration.isExpanded {
                configuration.content
                    .padding(.leading, 15)
            }
        }
    }
}

struct ConversationActivityPartsView: View {
    let steps: [ConversationActivityStep]
    var expandedActivity = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(ConversationActivityPartGroup.group(steps)) { group in
                if group.isActivity {
                    if expandedActivity {
                        ConversationActivityStepsView(steps: group.steps)
                    } else {
                        ConversationActivityDisclosure(
                            summary: ConversationActivitySummary(steps: group.steps), identifier: group.id
                        ) {
                            ConversationActivityStepsView(steps: group.steps)
                        }
                    }
                } else if let step = group.steps.first {
                    if ConversationMessagePartGroup.isToolCall(step.part) {
                        ToolCallView(messageID: step.messageID, part: step.part)
                    } else if ConversationActivityGrouping.needsAttention(step.part) {
                        VStack(alignment: .leading, spacing: 6) {
                            if !step.part.text.isEmpty {
                                ConversationMarkdownView(source: step.part.text, inUserBubble: false)
                            }
                            if !step.part.errorText.isEmpty, step.part.errorText != step.part.text {
                                Text(step.part.errorText).font(.caption).foregroundStyle(DieterTheme.coral)
                            }
                            if step.part.text.isEmpty && step.part.errorText.isEmpty {
                                Text(
                                    step.part.state.isEmpty
                                        ? "Needs attention" : step.part.state.replacingOccurrences(of: "-", with: " ")
                                )
                                .font(.caption).foregroundStyle(DieterTheme.amber)
                            }
                        }
                    } else {
                        MessagePartView(messageID: step.messageID, part: step.part, inUserBubble: false)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ConversationActivityStepsView: View {
    let steps: [ConversationActivityStep]

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(steps) { step in
                if ConversationActivityGrouping.isReasoning(step.part) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Reasoning").font(.caption2.weight(.medium)).foregroundStyle(DieterTheme.tertiary)
                        Text(step.part.text).font(.caption).foregroundStyle(DieterTheme.subtle).lineSpacing(3)
                    }
                } else {
                    ToolCallView(messageID: step.messageID, part: step.part)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ConversationTimelineDisplayGroupView: View {
    let group: ConversationTimelineDisplayGroup
    let showReasoning: Bool
    let isLatest: Bool

    var body: some View {
        if group.isActivity {
            let messages = group.rows.flatMap(\.item.messages)
            let steps = ConversationActivityStep.steps(messages: messages, showReasoning: showReasoning)
            ConversationActivityDisclosure(
                summary: ConversationActivitySummary(steps: steps), identifier: group.id,
                footer: MessageFooterContent(messages: messages),
                footerMessageID: messages.last?.id ?? group.id, isLatest: isLatest
            ) {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(group.rows) { row in
                        ConversationTimelineRow(
                            item: row.item, details: row.details,
                            isLatest: isLatest && row.id == group.rows.last?.id, expandedActivity: true)
                    }
                }
            }
            .background(alignment: .topLeading) {
                // Pagination restores existing timeline-item IDs. Keep their
                // anchors at the disclosure header even while content is hidden.
                VStack(spacing: 0) {
                    ForEach(Array(group.rows.dropFirst())) { row in
                        Color.clear.frame(height: 0).id(row.id)
                    }
                }
                .accessibilityHidden(true)
            }
        } else {
            ForEach(group.rows) { row in
                ConversationTimelineRow(item: row.item, details: row.details, isLatest: isLatest)
            }
        }
    }
}
