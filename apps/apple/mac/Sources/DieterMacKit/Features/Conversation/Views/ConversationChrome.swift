import DieterCore
import SwiftUI
import UniformTypeIdentifiers

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
        .e2eTarget("board.conversation-close")
    }
}

struct ConversationActionsMenu: View {
    @Environment(ConversationContext.self) private var context
    let standalone: Bool

    var body: some View {
        if let card = context.shownCard {
            Menu {
                Button("Fork as new chat", systemImage: "arrow.triangle.branch") {
                    Task { await context.fork(card) }
                }
                if context.model.chrome.canHalt {
                    Button("Halt agent", role: .destructive) { Task { await context.cancel(card) } }
                }
                // The agent's reviewer and memory apply from its next turn; a
                // dream always has memory, so it shows no switch.
                let memory = context.memory.flatMap { $0.shown ? $0 : nil }
                if context.codeReview != nil || memory != nil { Divider() }
                if let review = context.codeReview {
                    Toggle(
                        isOn: Binding(
                            get: { review.enabled },
                            set: { on in Task { await context.setCodeReview(enabled: on) } })
                    ) {
                        Label("Code review", systemImage: "eye")
                    }
                    .disabled(!review.canToggle)
                    .accessibilityIdentifier("code-review-switch")
                }
                if let memory {
                    Toggle(
                        isOn: Binding(
                            get: { memory.enabled },
                            set: { on in Task { await context.setMemory(enabled: on) } })
                    ) {
                        Label("Agent memory", systemImage: "clock.arrow.circlepath")
                    }
                    .disabled(!memory.canToggle)
                    .accessibilityIdentifier("memory-switch")
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
