import AppKit
import SwiftUI

struct ConversationMarkdownView: View {
    let source: String
    let inUserBubble: Bool
    @State private var showingFullText = false

    var body: some View {
        let preview = ConversationRenderCache.preview(source)
        VStack(alignment: .leading, spacing: 7) {
            SelectableMessageText(
                source: preview, color: inUserBubble ? DieterTheme.userMessageForeground : DieterTheme.text)
            if preview != source {
                Button("Open full text…") { showingFullText = true }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("conversation.full-text").smokeTarget("conversation.full-text")
            }
        }
        // Always report the full wrapped height back to the conversation
        // stack as the split-view width changes.
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $showingFullText) {
            FullConversationText(source: source)
        }
    }
}

/// AppKit lays out long plain text incrementally. Opening the full source is an
/// explicit action and does not inflate every message in the eager timeline.
private struct FullConversationText: View {
    let source: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Full message").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.accessibilityIdentifier("conversation.full-text.done")
                    .smokeTarget(
                        "conversation.full-text.done")
            }.padding(14)
            FullConversationTextEditor(source: source)
        }.frame(minWidth: 650, minHeight: 500)
    }
}

private struct FullConversationTextEditor: NSViewRepresentable {
    let source: String
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        if let text = scroll.documentView as? NSTextView {
            text.isEditable = false
            text.isSelectable = true
            text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            text.string = source
        }
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {}
}
