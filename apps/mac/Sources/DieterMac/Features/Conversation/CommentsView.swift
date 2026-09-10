import DieterAPI
import SwiftUI
import UniformTypeIdentifiers

struct CommentsView: View {
    @Environment(ConversationContext.self) private var context
    var composerBackground: Color = DieterTheme.sidebar
    var body: some View {
        @Bindable var context = context
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if (context.selectedDetail?.comments ?? []).isEmpty {
                        ContentUnavailableView(
                            "No Dieter comments yet", systemImage: "text.bubble",
                            description: Text(
                                "Comments are non-triggering annotations and never resume the harness session.")
                        )
                        .padding(.vertical, 45)
                    }
                    ForEach(context.selectedDetail?.comments ?? [], id: \.id) { comment in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(
                                    comment.author.name.isEmpty ? comment.author.kind.capitalized : comment.author.name
                                ).font(.caption.weight(.semibold))
                                Spacer(); Text(comment.createdAt).font(.caption2).foregroundStyle(DieterTheme.tertiary)
                            }
                            Text(comment.body).font(.system(size: 13)).textSelection(.enabled).lineSpacing(3)
                        }
                        .padding(12).background(DieterTheme.surface, in: RoundedRectangle(cornerRadius: 9))
                    }
                }.padding(18)
            }
            Divider().overlay(DieterTheme.border)
            HStack(spacing: 9) {
                TextField("Add a non-triggering comment…", text: $context.commentText).textFieldStyle(.plain)
                    .padding(.horizontal, 11).frame(height: 36).background(
                        DieterTheme.input, in: RoundedRectangle(cornerRadius: 8)
                    )
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(DieterTheme.border))
                Button("Comment") { Task { await context.addComment() } }.buttonStyle(DieterPrimaryButtonStyle())
                    .disabled(context.commentText.isEmpty)
            }.padding(12).background(composerBackground)
        }
    }
}
