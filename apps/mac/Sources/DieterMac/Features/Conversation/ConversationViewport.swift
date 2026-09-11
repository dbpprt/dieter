import DieterAPI
import SwiftUI
import UniformTypeIdentifiers

enum ConversationQueuePresentation {
    struct EditableDraft {
        let text: String
        let attachments: [Dieter_V1_MessagePart]
    }

    static func deliveredMessages(
        _ messages: [Dieter_V1_UiMessage],
        whileQueued queue: [Dieter_V1_QueuedMessage]
    ) -> [Dieter_V1_UiMessage] {
        let queuedIDs = Set(queue.lazy.map(\.id).filter { !$0.isEmpty })
        return messages.filter { !queuedIDs.contains($0.id) }
    }

    static func canSteer(
        messageID: String,
        queue: [Dieter_V1_QueuedMessage],
        agentIsWorking: Bool
    ) -> Bool {
        agentIsWorking && !messageID.isEmpty && queue.first?.id == messageID
    }

    static func editableDraft(for message: Dieter_V1_QueuedMessage) -> EditableDraft {
        let textParts = message.parts.filter { $0.type == "text" }.map(\.text)
        let text = textParts.isEmpty ? message.text : textParts.joined()
        return EditableDraft(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            attachments: message.parts.filter { $0.type != "text" }
        )
    }
}
struct ConversationAgentWorkingIndicator: View {
    let label: String
    let startedAt: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shimmer = false

    var body: some View {
        HStack(spacing: 8) {
            DieterActivityIndicator(size: 12).accessibilityHidden(true)
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(DieterTheme.subtle)
                .overlay {
                    if !reduceMotion {
                        GeometryReader { geometry in
                            LinearGradient(
                                colors: [.clear, DieterTheme.text, .clear], startPoint: .leading, endPoint: .trailing
                            )
                            .frame(width: geometry.size.width)
                            .offset(x: shimmer ? geometry.size.width : -geometry.size.width)
                        }
                        .mask(Text(label).font(.caption.weight(.medium)))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    }
                }
                .lineLimit(1)
                .truncationMode(.tail)
            if let startedAt {
                Text(startedAt, style: .timer)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(DieterTheme.subtle)
                    .accessibilityLabel("Elapsed time")
                    .fixedSize()
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 34)
        .background(DieterTheme.surface.opacity(0.85), in: Capsule())
        .overlay(Capsule().stroke(DieterTheme.primary.opacity(0.18)))
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("conversation.agent-working")
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 2).repeatForever(autoreverses: false)) { shimmer = true }
        }
    }
}

enum ConversationScrollBehavior {
    static let bottomID = "conversation.bottom"
    private static let latestTolerance: CGFloat = 2

    static func isAtLatest(
        visibleMaxY: CGFloat,
        contentHeight: CGFloat,
        renderedThroughLatest: Bool = true
    ) -> Bool {
        renderedThroughLatest && visibleMaxY >= contentHeight - latestTolerance
    }

    static func followsLatest(_ viewportMode: ConversationViewportMode) -> Bool {
        switch viewportMode {
        case .awaitingInitial, .followingLatest:
            true
        case .detached:
            false
        }
    }

    static func showsJumpToLatest(viewportMode: ConversationViewportMode) -> Bool {
        viewportMode == .detached
    }

    static func afterUserScroll(isAtLatest: Bool) -> ConversationViewportMode {
        isAtLatest ? .followingLatest : .detached
    }

    static func isUserDriven(_ phase: ScrollPhase) -> Bool {
        phase.isScrolling && phase != .animating
    }

    static func anchorItem(containing messageID: String?, in items: [ConversationTimelineItem]) -> String? {
        guard let messageID, !messageID.isEmpty else { return nil }
        return items.first { item in item.messages.contains { $0.id == messageID } }?.id
    }
}

enum ConversationViewportMode: Equatable {
    case awaitingInitial(conversationID: String)
    case followingLatest
    case detached
}

struct ConversationViewportObservation: Equatable {
    let conversationID: String
    let isAtLatest: Bool
    let followsLatest: Bool
    let initialPositionComplete: Bool
}

struct ConversationTailScrollKey: Equatable {
    let conversationID: String
    let request: Int
}

struct EmptyConversationView: View {
    let standalone: Bool
    let prompt: String
    let attachments: [Dieter_V1_MessagePart]
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left").font(.system(size: 24)).foregroundStyle(DieterTheme.shell)
            Text("Ready when you are").font(.headline)
            Text(
                standalone
                    ? "Start a focused conversation in this project."
                    : "Send this card's brief to start its local harness session."
            )
            .font(.caption).foregroundStyle(DieterTheme.tertiary).multilineTextAlignment(.center)
            if !prompt.isEmpty || !attachments.isEmpty {
                VStack(alignment: .leading, spacing: 9) {
                    if !prompt.isEmpty { Text(prompt).font(.callout) }
                    if !attachments.isEmpty {
                        HStack(spacing: 8) {
                            ForEach(Array(attachments.enumerated()), id: \.offset) { _, part in
                                AttachmentPreviewTile(part: part)
                            }
                        }
                    }
                }
                .padding(12).frame(maxWidth: 520, alignment: .leading)
                .background(DieterTheme.elevated, in: RoundedRectangle(cornerRadius: 10))
            }
        }.frame(maxWidth: .infinity).padding(.vertical, 55)
    }
}
