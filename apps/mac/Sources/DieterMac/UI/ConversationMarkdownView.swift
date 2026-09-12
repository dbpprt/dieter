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
    @Environment(\.conversationLinkHandler) private var linkHandler
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
                .environment(
                    \.conversationLinkHandler,
                    { url in
                        guard linkHandler?(url) == true else { return false }
                        dismiss()
                        return true
                    })
        }.frame(minWidth: 650, minHeight: 500)
    }
}

struct FullConversationTextEditor: NSViewRepresentable {
    let source: String
    @Environment(\.conversationLinkHandler) private var linkHandler
    @Environment(\.conversationLinkExternalResolver) private var externalResolver

    func makeCoordinator() -> ConversationTextLinkDelegate {
        ConversationTextLinkDelegate()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        if let text = scroll.documentView as? NSTextView {
            text.isEditable = false
            text.isSelectable = true
            text.delegate = context.coordinator
        }
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.handler = linkHandler
        context.coordinator.externalResolver = externalResolver
        guard let text = scroll.documentView as? NSTextView, text.string != source else { return }
        text.textStorage?.setAttributedString(Self.attributedSource(source))
    }

    /// Keep the full source copyable verbatim while making its link labels
    /// actionable. Foundation maps Markdown source positions to UTF-16 ranges,
    /// including relative destinations, multiline labels, and Unicode text.
    static func attributedSource(_ source: String) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: source,
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: NSColor.labelColor,
            ])
        guard
            let markdown = try? AttributedString(
                markdown: source, options: .init(appliesSourcePositionAttributes: true))
        else { return result }
        for run in markdown.runs {
            guard let link = run.link, let position = run.markdownSourcePosition,
                let range = NSRange(position, in: source), range.length > 0
            else { continue }
            result.addAttribute(.link, value: link, range: range)
        }
        return result
    }
}
