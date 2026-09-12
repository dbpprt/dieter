import AppKit
import SwiftUI

/// Return true when a conversation presents the destination itself. Returning
/// false lets AppKit retain its normal link-opening behavior.
typealias ConversationLinkHandler = @MainActor (URL) -> Bool
typealias ConversationLinkExternalResolver = @MainActor (URL) async -> ConversationLinkExternalTarget

private struct ConversationLinkHandlerKey: EnvironmentKey {
    static let defaultValue: ConversationLinkHandler? = nil
}

private struct ConversationLinkExternalResolverKey: EnvironmentKey {
    static let defaultValue: ConversationLinkExternalResolver? = nil
}

extension EnvironmentValues {
    var conversationLinkHandler: ConversationLinkHandler? {
        get { self[ConversationLinkHandlerKey.self] }
        set { self[ConversationLinkHandlerKey.self] = newValue }
    }
    var conversationLinkExternalResolver: ConversationLinkExternalResolver? {
        get { self[ConversationLinkExternalResolverKey.self] }
        set { self[ConversationLinkExternalResolverKey.self] = newValue }
    }
}

/// Native link delegation leaves mouse dragging, selection, copy, and context
/// menus in NSTextView. Command-click keeps the usual external opening path.
@MainActor final class ConversationTextLinkDelegate: NSObject, NSTextViewDelegate {
    var handler: ConversationLinkHandler?
    var externalResolver: ConversationLinkExternalResolver?
    var openExternal: @MainActor (URL, URL?) -> Void = ConversationLinkExternalTarget.open
    var revealExternal: @MainActor (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
    private var linkMenu: ConversationLinkMenuSession?

    func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
        contextMenu(menu, textView: view, at: charIndex)
    }

    func contextMenu(_ original: NSMenu, textView: NSTextView, at charIndex: Int) -> NSMenu {
        guard let resolver = externalResolver, let storage = textView.textStorage,
            charIndex >= 0, charIndex < storage.length,
            let link = storage.attribute(.link, at: charIndex, effectiveRange: nil),
            let url = Self.url(link)
        else { return original }
        linkMenu?.cancel()
        let session = ConversationLinkMenuSession(
            url: url, textView: textView, openInDieter: handler, resolver: resolver,
            openExternal: openExternal, reveal: revealExternal)
        linkMenu = session
        return session.menu
    }

    func waitForExternalMenu() async { await linkMenu?.loadingTask?.value }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        activate(link, modifiers: NSApp.currentEvent?.modifierFlags ?? [])
    }

    func activate(_ link: Any, modifiers: NSEvent.ModifierFlags = []) -> Bool {
        guard !modifiers.contains(.command), let handler else { return false }
        guard let url = Self.url(link) else { return false }
        // In particular, do not resolve relative file links against this Mac's
        // process directory; the conversation knows its machine and worktree.
        return handler(url)
    }

    private static func url(_ link: Any) -> URL? {
        if let value = link as? URL {
            return value
        } else if let value = link as? String {
            return URL(string: value)
        }
        return nil
    }
}

/// One native selection surface for the complete message, including paragraph
/// breaks. SwiftUI's Text selection on macOS stops at each paragraph.
struct SelectableMessageText: NSViewRepresentable {
    let source: String
    let color: Color
    @Environment(\.conversationLinkHandler) private var linkHandler
    @Environment(\.conversationLinkExternalResolver) private var externalResolver

    func makeNSView(context: Context) -> MessageTextView {
        MessageTextView()
    }

    func updateNSView(_ view: MessageTextView, context: Context) {
        view.linkDelegate.handler = linkHandler
        view.linkDelegate.externalResolver = externalResolver
        view.update(source: source, color: NSColor(color))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MessageTextView, context: Context) -> CGSize? {
        nsView.fittingSize(width: proposal.width)
    }
}

final class MessageTextView: NSTextView {
    let linkDelegate = ConversationTextLinkDelegate()
    private var renderedSource: String?
    private var renderedColor: NSColor?
    private let measurementStorage = NSTextStorage()
    private let measurementLayout = NSLayoutManager()
    private let measurementContainer = NSTextContainer(containerSize: .zero)

    init() {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(containerSize: .zero)
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        delegate = linkDelegate
        measurementStorage.addLayoutManager(measurementLayout)
        measurementLayout.addTextContainer(measurementContainer)
        measurementContainer.lineFragmentPadding = 0
        isEditable = false
        isSelectable = true
        isRichText = true
        drawsBackground = false
        textContainerInset = .zero
        textContainer?.lineFragmentPadding = 0
        textContainer?.widthTracksTextView = true
        isHorizontallyResizable = false
        // SwiftUI owns the frame. TextKit must not resize the live view while
        // SwiftUI measures another proposal or applies a streaming update.
        isVerticallyResizable = false
        clipsToBounds = true
        textContainer?.heightTracksTextView = false
        textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        minSize = .zero
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setAccessibilityLabel("Message")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(source: String, color: NSColor) {
        guard source != renderedSource || color != renderedColor else { return }
        let selection = selectedRange()
        let previousText = string
        let content = Self.attributedText(source: source, color: color)
        textStorage?.setAttributedString(content)
        measurementStorage.setAttributedString(content)
        // Streaming and theme updates must not clear an in-progress selection.
        if content.string == previousText || content.string.hasPrefix(previousText) {
            setSelectedRange(NSIntersectionRange(selection, NSRange(location: 0, length: content.length)))
        } else {
            setSelectedRange(NSRange(location: 0, length: 0))
        }
        renderedSource = source
        renderedColor = color
        invalidateIntrinsicContentSize()
    }

    func fittingSize(width proposedWidth: CGFloat?) -> CGSize {
        let width = max(1, proposedWidth.flatMap { $0.isFinite ? $0 : nil } ?? 620)
        // A proposal may be rejected. Never change the displayed container's
        // width, glyph layout or frame just to answer a sizing question.
        measurementContainer.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        measurementLayout.ensureLayout(for: measurementContainer)
        let used = measurementLayout.usedRect(for: measurementContainer)
        return NSSize(width: min(width, ceil(used.width)), height: ceil(used.height))
    }

    static func attributedText(source: String, color: NSColor) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let blocks = ConversationRenderCache.blocks(source)
        for (index, block) in blocks.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: "\n\n"))
            }
            switch block {
            case .paragraph(let text):
                result.append(inlineText(source: text, color: color))
            case .heading(let level, let text):
                result.append(
                    inlineText(
                        source: text, color: color,
                        size: level == 1 ? 17 : 15, bold: true))
            case .bullet(let text):
                result.append(inlineText(source: "• " + text, color: color))
            case .code(let text):
                result.append(
                    NSAttributedString(
                        string: text,
                        attributes: [
                            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                            .foregroundColor: color,
                            .backgroundColor: NSColor(DieterTheme.raised),
                        ]))
            case .table(let table):
                append(table: table, to: result, color: color)
            }
        }
        return result
    }

    private static func append(
        table: ConversationMarkdownTable,
        to result: NSMutableAttributedString, color: NSColor
    ) {
        let nativeTable = NSTextTable()
        nativeTable.numberOfColumns = table.headers.count
        nativeTable.layoutAlgorithm = .fixedLayoutAlgorithm
        nativeTable.collapsesBorders = true
        nativeTable.setValue(100, type: .percentageValueType, for: .width)
        for (row, cells) in ([table.headers] + table.rows).enumerated() {
            for column in table.headers.indices {
                let cell = NSTextTableBlock(
                    table: nativeTable, startingRow: row, rowSpan: 1,
                    startingColumn: column, columnSpan: 1)
                cell.setValue(100 / CGFloat(table.headers.count), type: .percentageValueType, for: .width)
                cell.setWidth(7, type: .absoluteValueType, for: .padding)
                cell.setWidth(1, type: .absoluteValueType, for: .border)
                cell.setBorderColor(NSColor(DieterTheme.border))
                cell.backgroundColor = NSColor(row == 0 ? DieterTheme.raised : DieterTheme.surface)
                let style = NSMutableParagraphStyle()
                style.textBlocks = [cell]
                switch table.alignments[column] {
                case .leading: style.alignment = .left
                case .center: style.alignment = .center
                case .trailing: style.alignment = .right
                }
                let content = NSMutableAttributedString(
                    attributedString: inlineText(
                        source: column < cells.count ? cells[column] : "", color: color, size: 12, bold: row == 0))
                content.append(NSAttributedString(string: "\n"))
                content.addAttribute(
                    .paragraphStyle, value: style,
                    range: NSRange(location: 0, length: content.length))
                result.append(content)
            }
        }
    }

    private static func inlineText(
        source: String, color: NSColor,
        size: CGFloat = 13, bold: Bool = false
    ) -> NSAttributedString {
        let markdown = ConversationRenderCache.markdown(source)
        let result = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        for run in markdown.runs {
            let intent = run.inlinePresentationIntent ?? []
            var font =
                intent.contains(.code)
                ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
                : NSFont.systemFont(ofSize: size)
            if bold || intent.contains(.stronglyEmphasized) {
                font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            }
            if intent.contains(.emphasized) {
                font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: color, .paragraphStyle: paragraph,
            ]
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link { attributes[.link] = link }
            result.append(NSAttributedString(string: String(markdown[run.range].characters), attributes: attributes))
        }
        ConversationDetectedLinks.apply(to: result)
        return result
    }
}
