import AppKit
import MarkdownEngine
import SwiftUI

/// A message's Markdown body in the native engine, read-only: it fits its
/// content (the reader's scroll view scrolls the page), wide tables scroll
/// on their own. Supported diagram fences use the same offline renderer as Files.
struct MailMessageBody: View {
    let markdown: String
    /// Keeps the engine's per-document state (table scroll offsets) per message.
    let documentID: String
    /// Every link the body opens; returns whether it handled the link.
    let openLink: @MainActor (URL) -> Bool

    @State private var rendering = MailMarkdownSession()
    @State private var graphicsStatus = "Rendering"
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        NativeTextViewWrapper(
            text: .constant(markdown),
            configuration: rendering.configuration,
            fontName: NSFont.systemFont(ofSize: MailMarkdown.fontSize).fontName,
            fontSize: MailMarkdown.fontSize,
            documentId: documentID,
            isEditable: false,
            onURLClick: openLink
        )
        .accessibilityIdentifier("mail.reader.body")
        .onAppear { updateDiagrams() }
        .onChange(of: markdown) { updateDiagrams() }
        .onChange(of: colorScheme) { updateDiagrams() }
        .onDisappear { rendering.diagrams.dispose() }
        .onReceive(NotificationCenter.default.publisher(for: rendering.diagrams.renderingDidChangeNotification!)) { _ in
            graphicsStatus =
                "\(rendering.diagrams.cachedCount) rendered, \(rendering.diagrams.failedCount) source fallbacks"
        }
        .e2eTarget("mail.reader.graphics", text: graphicsStatus)
    }

    private func updateDiagrams() {
        rendering.diagrams.synchronizeSource(markdown)
        rendering.diagrams.updateAppearance(NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)!)
    }
}

/// Stable services for one message; notification-driven layout never creates another renderer.
@MainActor
private final class MailMarkdownSession {
    let diagrams = NativeMarkdownDiagramRenderer(sourceOnFailure: true)
    let configuration: MarkdownEditorConfiguration

    init() { configuration = MailMarkdown.configuration(diagrams: diagrams) }
}

@MainActor
enum MailMarkdown {
    static let fontSize: CGFloat = 14
    /// The readable column's maximum width, insets included.
    static let maximumWidth: CGFloat = 760

    /// Read-only Files styling, with a renderer owned by this message.
    static func configuration(diagrams: NativeMarkdownDiagramRenderer) -> MarkdownEditorConfiguration {
        var configuration = MarkdownEditorConfiguration.default
        configuration.textInsets = TextInsets(horizontal: 24, vertical: 14)
        configuration.extensions = [StrikethroughExtension()]
        configuration.services = MarkdownEditorServices(
            syntaxHighlighter: DiagramFenceHighlighter(), renderedCodeBlocks: diagrams)
        configuration.heightBehavior = .fitsContent
        return configuration
    }
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
