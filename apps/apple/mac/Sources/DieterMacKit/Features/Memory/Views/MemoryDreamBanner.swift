import DieterClientAPI
import SwiftUI

/// What a dream conversation's banner can do with its dream.
enum MemoryDreamAction: Sendable, Equatable {
    /// Applies the staged changes.
    case apply
    /// Discards the staged changes.
    case discard
    /// Restores the memories an applied dream changed.
    case undo
}

/// A dream conversation's dream: what it did and changed, laid out by the
/// core, with the actions its status allows (Apply and Discard while it
/// awaits review, Undo once applied).
struct MemoryDreamBanner: View {
    let dream: ClientMemoryDreamState
    let perform: (MemoryDreamAction) async -> Void
    @State private var working = false

    private var failed: Bool { !dream.error.isEmpty }
    private var undo: Bool { !dream.canApply && dream.canUndo }
    private var tint: Color {
        failed ? DieterTheme.coral : dream.canApply ? DieterTheme.amber : DieterTheme.tertiary
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: failed ? "exclamationmark.triangle" : "moon")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(dream.title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(DieterTheme.text)
                    .e2eTarget("conversation.memory-dream.title", text: dream.title)
                if !dream.countsLabel.isEmpty {
                    Text(dream.countsLabel).font(.caption).foregroundStyle(DieterTheme.subtle)
                }
                if failed {
                    Text(dream.error).font(.caption).foregroundStyle(DieterTheme.coral)
                        .textSelection(.enabled)
                }
                if !dream.detail.isEmpty {
                    Text(dream.detail).font(.caption).foregroundStyle(DieterTheme.tertiary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if dream.canDiscard {
                Button("Discard") { run(.discard) }
                    .buttonStyle(DieterBarButtonStyle(size: 26))
                    .accessibilityIdentifier("conversation.memory-dream.discard")
                    .e2eTarget("conversation.memory-dream.discard")
            }
            if dream.canApply {
                Button("Apply") { run(.apply) }
                    .buttonStyle(DieterBarButtonStyle(prominent: true, size: 26))
                    .accessibilityIdentifier("conversation.memory-dream.apply")
                    .e2eTarget("conversation.memory-dream.apply")
            } else if undo {
                Button("Undo") { run(.undo) }
                    .buttonStyle(DieterBarButtonStyle(size: 26))
                    .accessibilityIdentifier("conversation.memory-dream.undo")
                    .e2eTarget("conversation.memory-dream.undo")
            }
        }
        .disabled(working)
        .padding(14)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(tint.opacity(0.4), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("conversation.memory-dream")
    }

    /// Runs one action at a time; the banner shows its result from the core.
    private func run(_ action: MemoryDreamAction) {
        guard !working else { return }
        working = true
        Task {
            await perform(action)
            working = false
        }
    }
}
