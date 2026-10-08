import DieterAPI
import SwiftUI

/// The same native disclosure is used between messages and inside a mixed
/// assistant message. Its content is constructed only while expanded.
struct ConversationActivityDisclosure<Content: View>: View {
    /// The core's summary of the routine work, e.g. "Reasoning · 1 edit".
    let summary: String
    let identifier: String
    var footer: MessageFooterContent? = nil
    var footerMessageID = ""
    var isLatest = false
    let content: () -> Content
    @State private var expanded = false
    @State private var hovered = false

    init(
        summary: String, identifier: String,
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
                Text(summary)
                    .font(.system(size: 12))
                    .foregroundStyle(DieterTheme.tertiary)
                    .lineLimit(2)
                    .textSelection(.disabled)
                    .smokeTarget("conversation.activity.\(identifier).label")
            }
            .disclosureGroupStyle(ConversationActivityDisclosureStyle(identifier: identifier))
            .tint(DieterTheme.tertiary)
            .accessibilityIdentifier("conversation.activity.\(identifier)")
            .accessibilityLabel(summary)
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

private struct ConversationToolsGroupedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Tool rows sit inside an activity's recessed list and draw no surface of their own.
    var conversationToolsGrouped: Bool {
        get { self[ConversationToolsGroupedKey.self] }
        set { self[ConversationToolsGroupedKey.self] = newValue }
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
                HStack(spacing: 7) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(DieterTheme.tertiary)
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
                // Routine work reads as one recessed list, not a stack of cards.
                configuration.content
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .dieterInset(radius: 10)
                    .environment(\.conversationToolsGrouped, true)
                    .padding(.leading, 14)
            }
        }
    }
}
