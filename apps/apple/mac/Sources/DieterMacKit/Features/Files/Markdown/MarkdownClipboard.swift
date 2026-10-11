import AppKit

/// Semantic HTML comes from the bundled renderer's allowlisted clipboard serializer.
/// Keep Markdown and rich text as separate actions so a paste never guesses the format.
struct MarkdownClipboardPayload {
    let markdown: String
    let html: String
    let text: String

    init?(body: [String: Any]) {
        guard let markdown = body["markdown"] as? String,
            let html = body["html"] as? String, let text = body["text"] as? String
        else { return nil }
        self.markdown = markdown
        self.html = html
        self.text = text
    }

    @MainActor
    func write(to pasteboard: NSPasteboard, richText: Bool) {
        let item = NSPasteboardItem()
        item.setString(richText ? text : markdown, forType: .string)
        if richText { item.setString(html, forType: .html) }
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }
}
