import DieterClientAPI
import SwiftUI

/// "Review changes": the code reviewer reviews the conversation's changes
/// now, one review at a time; the review shows in the transcript. Absent
/// outside a conversation and until the conversation's card is known.
struct ReviewChangesButton: View {
    @Environment(ConversationContext.self) private var context: ConversationContext?
    var iconOnly = false
    var size: CGFloat = 30

    var body: some View {
        if let context, let review = context.codeReview {
            let title = review.running ? "Reviewing changes…" : "Review changes"
            Button {
                Task { await context.startCodeReview() }
            } label: {
                if iconOnly {
                    Label(title, systemImage: "eye").labelStyle(.iconOnly)
                } else {
                    Label(title, systemImage: "eye").lineLimit(1).fixedSize()
                }
            }
            .buttonStyle(DieterBarButtonStyle(shape: iconOnly ? .circle : .capsule, size: size))
            .disabled(!review.canStart)
            .help(
                review.running
                    ? "The code reviewer is reviewing these changes" : "Ask the code reviewer to review these changes"
            )
            .accessibilityLabel(title)
            .accessibilityIdentifier("review-changes")
            .e2eTarget("review-changes")
        }
    }
}
