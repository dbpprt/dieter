import DieterClientAPI
import SwiftUI

/// An agent channel message that joined the running turn, where it joined:
/// who wrote it, in which channel, and what it said, with a way to open the
/// channel. It is never folded into an activity disclosure.
struct PeerNoticeChip: View, Equatable {
    @Environment(ConversationContext.self) private var context
    let notice: ClientTimelinePeerNotice

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.notice == rhs.notice }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            ChannelAvatar(author: notice.author, size: 22)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "number").font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(DieterTheme.action)
                    Text(notice.title).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                    if !notice.kindLabel.isEmpty { ChannelKindBadge(label: notice.kindLabel, kind: notice.kind) }
                    if notice.createdAtMillis > 0 {
                        Text(ChannelStyle.time(notice.createdAtMillis)).font(.system(size: 10))
                            .foregroundStyle(DieterTheme.tertiary)
                    }
                }
                Text(notice.body)
                    .font(.system(size: 12.5))
                    .foregroundStyle(DieterTheme.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if !notice.files.isEmpty {
                    DieterFlowLayout(horizontalSpacing: 5, verticalSpacing: 5) {
                        ForEach(notice.files, id: \.self) { ChannelFileChip(path: $0) }
                    }
                }
                if !notice.projectID.isEmpty {
                    Button {
                        context.openChannel(projectID: notice.projectID)
                    } label: {
                        HStack(spacing: 3) {
                            Text(notice.openLabel)
                            Image(systemName: "chevron.right").font(.system(size: 8.5, weight: .bold))
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(DieterTheme.action)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("conversation.peer-notice.open.\(notice.messageID)")
                    .e2eTarget("conversation.peer-notice.open.\(notice.messageID)")
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11).padding(.vertical, 9)
        .frame(maxWidth: 620, alignment: .leading)
        .background(DieterTheme.action.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(DieterTheme.action.opacity(0.25))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(notice.title): \(notice.body)")
        .accessibilityIdentifier("conversation.peer-notice.\(notice.messageID)")
        .e2eTarget("conversation.peer-notice.\(notice.messageID)", text: notice.body)
    }
}
