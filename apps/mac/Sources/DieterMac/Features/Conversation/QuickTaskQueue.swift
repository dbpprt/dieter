import AppKit
import DieterAPI
import DieterClient
import DieterCore
import SwiftUI

enum ComposerHistoryDirection {
    case older
    case newer
}

enum ComposerQueueRecall {
    static func newestMessage(
        text: String,
        attachments: [Dieter_V1_MessagePart],
        queue: [Dieter_V1_QueuedMessage]
    ) -> Dieter_V1_QueuedMessage? {
        guard text.isEmpty, attachments.isEmpty else { return nil }
        return queue.last
    }
}

struct ComposerHistoryNavigation {
    private(set) var selectedIndex: Int?
    private(set) var selectedText: String?
    private var preservedDraft = ""

    var isBrowsing: Bool { selectedIndex != nil }

    static func acceptsArrow(modifiers: EventModifiers) -> Bool {
        // AppKit marks ordinary arrow keys as function/numeric-pad events.
        // Only user shortcuts should prevent recall or history navigation.
        modifiers.intersection([.shift, .control, .option, .command]).isEmpty
    }

    static func entries(
        messages: [Dieter_V1_UiMessage],
        queuedMessages: [Dieter_V1_QueuedMessage]
    ) -> [String] {
        let queuedIDs = Set(queuedMessages.lazy.map(\.id).filter { !$0.isEmpty })
        return messages.compactMap { message in
            guard ["user", "human"].contains(message.role.lowercased()),
                !queuedIDs.contains(message.id)
            else { return nil }
            let text = message.parts
                .filter { $0.type == "text" }
                .map(\.text)
                .joined()
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
        }
    }

    static func isAtBoundary(
        _ direction: ComposerHistoryDirection,
        text: String,
        selection: NSRange?
    ) -> Bool {
        guard let selection, selection.location != NSNotFound else {
            return !text.contains("\n")
        }
        let value = text as NSString
        let location: Int
        switch direction {
        case .older:
            location = min(max(0, selection.location), value.length)
            return !value.substring(to: location).contains("\n")
        case .newer:
            location = min(max(0, selection.location + selection.length), value.length)
            return !value.substring(from: location).contains("\n")
        }
    }

    mutating func navigate(
        _ direction: ComposerHistoryDirection,
        entries: [String],
        currentText: String
    ) -> String? {
        guard !entries.isEmpty else { return nil }
        switch direction {
        case .older:
            if let selectedIndex {
                self.selectedIndex = max(0, min(selectedIndex, entries.count - 1) - 1)
            } else {
                preservedDraft = currentText
                selectedIndex = entries.count - 1
            }
            selectedText = entries[selectedIndex!]
            return selectedText
        case .newer:
            guard let selectedIndex else { return nil }
            if selectedIndex < entries.count - 1 {
                self.selectedIndex = selectedIndex + 1
                selectedText = entries[selectedIndex + 1]
                return selectedText
            }
            let draft = preservedDraft
            reset()
            return draft
        }
    }

    mutating func observeTextChange(_ text: String) {
        if isBrowsing, text != selectedText { reset() }
    }

    mutating func reset() {
        selectedIndex = nil
        selectedText = nil
        preservedDraft = ""
    }
}

struct ConversationStartCardBanner: View {
    @Environment(ConversationContext.self) private var context
    let card: Dieter_V1_Card
    let starting: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Ready to run").font(.system(size: 12, weight: .semibold))
                Text(starting ? "Starting the saved task…" : "Run the saved task and move this card to Running.")
                    .font(.caption).foregroundStyle(DieterTheme.tertiary)
            }
            Spacer()
            Button {
                Task { await context.start(card) }
            } label: {
                HStack(spacing: 6) {
                    if starting {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "play.fill").font(.system(size: 9, weight: .bold))
                    }
                    Text(starting ? "Starting…" : "Run task")
                }
            }
            .buttonStyle(DieterPrimaryButtonStyle())
            .disabled(starting)
            .accessibilityIdentifier("conversation-run-card")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(DieterTheme.shellDeep.opacity(0.08))
        .overlay(alignment: .top) { Divider().overlay(DieterTheme.border) }
    }
}

struct QueuedMessageTray: View {
    let messages: [Dieter_V1_QueuedMessage]
    let agentIsWorking: Bool
    let onEdit: (Dieter_V1_QueuedMessage) async -> Void
    let onRemove: (Dieter_V1_QueuedMessage) async -> Void
    let onSteer: () async -> Void

    private var trayHeight: CGFloat {
        min(CGFloat(messages.count) * 64, 190)
    }

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 6) {
                ForEach(messages, id: \.id) { message in
                    QueuedComposerMessage(
                        message: message,
                        canSteer: ConversationQueuePresentation.canSteer(
                            messageID: message.id,
                            queue: messages,
                            agentIsWorking: agentIsWorking
                        ),
                        onEdit: { await onEdit(message) },
                        onRemove: { await onRemove(message) },
                        onSteer: onSteer
                    )
                }
            }
        }
        .scrollIndicators(.hidden)
        .frame(height: trayHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Queued messages")
        .accessibilityIdentifier("conversation.queue")
    }
}

struct QueuedComposerMessage: View {
    enum Action { case edit, remove, steer }

    let message: Dieter_V1_QueuedMessage
    let canSteer: Bool
    let onEdit: () async -> Void
    let onRemove: () async -> Void
    let onSteer: () async -> Void
    @State private var action: Action?

    private var draft: ConversationQueuePresentation.EditableDraft {
        ConversationQueuePresentation.editableDraft(for: message)
    }

    private var summary: String {
        if !draft.text.isEmpty { return draft.text }
        return draft.attachments.count == 1 ? "1 attachment" : "\(draft.attachments.count) attachments"
    }

    private var attachmentCount: Int {
        draft.attachments.count
    }

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(DieterTheme.tertiary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(summary)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(DieterTheme.text)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if attachmentCount > 0 && !draft.text.isEmpty {
                    Label("\(attachmentCount) attachment\(attachmentCount == 1 ? "" : "s")", systemImage: "paperclip")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(DieterTheme.tertiary)
                }
            }

            if canSteer {
                Button {
                    perform(.steer, onSteer)
                } label: {
                    HStack(spacing: 5) {
                        if action == .steer {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "arrow.turn.down.right")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        Text(action == .steer ? "Steering…" : "Steer")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DieterTheme.subtle)
                    .padding(.horizontal, 7)
                    .frame(height: 28)
                }
                .buttonStyle(.plain)
                .disabled(action != nil)
                .help("Stop the current turn and run this message next")
                .accessibilityIdentifier("conversation.queued-message.steer.\(message.id)")
            }

            Button(role: .destructive) {
                perform(.remove, onRemove)
            } label: {
                Group {
                    if action == .remove {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "trash")
                            .font(.system(size: 13, weight: .medium))
                    }
                }
                .foregroundStyle(DieterTheme.tertiary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(action != nil)
            .help("Remove queued message")
            .accessibilityLabel("Remove queued message")
            .accessibilityIdentifier("conversation.queued-message.remove.\(message.id)")

            Menu {
                Button("Edit queued message", systemImage: "pencil") {
                    perform(.edit, onEdit)
                }
                Button("Remove queued message", systemImage: "trash", role: .destructive) {
                    perform(.remove, onRemove)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DieterTheme.tertiary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(action != nil)
            .help("Queued message actions")
            .accessibilityIdentifier("conversation.queued-message.menu.\(message.id)")
        }
        .padding(.leading, 13)
        .padding(.trailing, 8)
        .padding(.vertical, 9)
        .frame(minHeight: 58)
        .background(DieterTheme.elevated.opacity(0.96), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(DieterTheme.border.opacity(0.9))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("conversation.queued-message.\(message.id)")
    }

    private func perform(_ next: Action, _ operation: @escaping () async -> Void) {
        guard action == nil else { return }
        action = next
        Task { @MainActor in
            await operation()
            action = nil
        }
    }
}
