import DieterAPI
import DieterShared
import SwiftUI
import UniformTypeIdentifiers

struct ProjectDirectoryChangesRedirect: View {
    @Environment(ConversationContext.self) private var context

    var body: some View {
        ContentUnavailableView {
            Label("Changes belong to the project", systemImage: "folder.badge.gearshape")
        } description: {
            Text(
                "This conversation uses the shared project directory. Its local changes are shown once for the checkout, independent of any card."
            )
        } actions: {
            Button("Open Project Changes") {
                let projectID =
                    (context.selectedCard ?? context.selectedDetail?.card)?.projectID ?? context.selectedProjectID
                Task { await context.openProjectChanges(projectID) }
            }
            .buttonStyle(DieterBarButtonStyle(prominent: true))
            .accessibilityIdentifier("changes.open-project").smokeTarget("changes.open-project")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ConversationCloseButton: View {
    @Environment(ConversationContext.self) private var context

    var body: some View {
        Button {
            context.closeConversation()
        } label: {
            Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
        }
        .buttonStyle(DieterBarButtonStyle(shape: .circle, size: ConversationPanelHeaderMetrics.circleSize))
        .accessibilityLabel("Close conversation")
        .quickHelp("Close")
        .accessibilityIdentifier("board.conversation-close")
        .smokeTarget("board.conversation-close")
    }
}

struct ConversationActionsMenu: View {
    @Environment(ConversationContext.self) private var context
    let standalone: Bool
    private var card: Dieter_V1_Card? { context.selectedCard ?? context.selectedDetail?.card }

    var body: some View {
        if let card {
            Menu {
                Button("Fork as new chat", systemImage: "arrow.triangle.branch") {
                    Task { await context.fork(card) }
                }
                if context.model.state.canHalt {
                    Button("Halt agent", role: .destructive) { Task { await context.cancel(card) } }
                }
                Divider()
                Button("Archive \(standalone ? "chat" : "card")", role: .destructive) {
                    Task { await context.archive(card, archived: true) }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DieterTheme.text)
                    .frame(
                        width: ConversationPanelHeaderMetrics.circleSize,
                        height: ConversationPanelHeaderMetrics.circleSize
                    )
                    .contentShape(Circle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .dieterCircleChrome()
            .accessibilityLabel("Conversation actions")
            .accessibilityIdentifier("conversation.actions")
            .quickHelp("More")
        }
    }
}

enum ConversationWorkspaceChromeMetrics {
    static let symbolSize: CGFloat = 12
    static let actionSize: CGFloat = 24
    static let titlebarHeight: CGFloat = 40
    static let tabHeight: CGFloat = 26
}

struct ConversationWorkspaceSymbol: View {
    let systemName: String
    var selected = false
    var frameSize: CGFloat = 16

    var body: some View {
        Image(systemName: systemName)
            .symbolVariant(selected ? .fill : .none)
            .symbolRenderingMode(.monochrome)
            .font(.system(size: ConversationWorkspaceChromeMetrics.symbolSize, weight: .medium))
            .foregroundStyle(selected ? DieterTheme.text : DieterTheme.subtle)
            .frame(width: frameSize, height: frameSize)
    }
}
