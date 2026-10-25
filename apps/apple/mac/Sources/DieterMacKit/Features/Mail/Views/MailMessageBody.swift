import AppKit
import MarkdownEngine
import SwiftUI

/// A message's Markdown body in the native engine, read-only: it fits its
/// content (the reader's scroll view scrolls the page), wide tables scroll
/// on their own, and no block ever reveals its source. Diagram fences show
/// as code: mail is a report, not a workspace document.
struct MailMessageBody: View {
    let markdown: String
    /// Keeps the engine's per-document state (table scroll offsets) per message.
    let documentID: String
    /// Every link the body opens; returns whether it handled the link.
    let openLink: @MainActor (URL) -> Bool

    var body: some View {
        NativeTextViewWrapper(
            text: .constant(markdown),
            configuration: MailMarkdown.configuration,
            fontName: NSFont.systemFont(ofSize: MailMarkdown.fontSize).fontName,
            fontSize: MailMarkdown.fontSize,
            documentId: documentID,
            isEditable: false,
            onURLClick: openLink
        )
        .accessibilityIdentifier("mail.reader.body")
    }
}

@MainActor
enum MailMarkdown {
    static let fontSize: CGFloat = 14
    /// The readable column's maximum width, insets included.
    static let maximumWidth: CGFloat = 760

    /// Built once: the Files editor's styling without its diagram renderer
    /// and formatting commands, laid out to fit its content.
    static let configuration: MarkdownEditorConfiguration = {
        var configuration = MarkdownEditorConfiguration.default
        configuration.textInsets = TextInsets(horizontal: 24, vertical: 14)
        configuration.extensions = [StrikethroughExtension()]
        configuration.services = MarkdownEditorServices(syntaxHighlighter: DiagramFenceHighlighter())
        configuration.heightBehavior = .fitsContent
        return configuration
    }()
}

/// Where a link in a message leads. Web and mail links open outside Dieter;
/// relative and `file:` links resolve inside the sender's checkout through
/// the core's rules; anything else (and any workspace link of a message
/// without a checkout) does nothing.
enum MailLink: Equatable {
    case external(URL)
    case workspaceFile(path: String, line: Int?)
    case ignored

    static func classify(_ url: URL, workspaceRoot: String?) -> MailLink {
        switch url.scheme?.lowercased() {
        case "mailto":
            return .external(url)
        case "http", "https":
            return ConversationContentLink.isWeb(url) && url.host?.isEmpty == false ? .external(url) : .ignored
        default:
            guard let workspaceRoot, !workspaceRoot.isEmpty,
                let link = try? ConversationContentLink.resolve(url, workspaceRoot: workspaceRoot)
            else { return .ignored }
            switch link {
            case .file(let path, let line): return .workspaceFile(path: path, line: line)
            case .web(let url): return .external(url)
            }
        }
    }
}
