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
        view.update(source: source, swiftUIColor: color)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MessageTextView, context: Context) -> CGSize? {
        nsView.fittingSize(width: proposal.width)
    }
}

final class MessageTextView: NSTextView {
    let linkDelegate = ConversationTextLinkDelegate()
    private var renderedSource: String?
    private var renderedColor: NSColor?
    private var configuredColor: Color?
    /// The rendered blocks, in order, as both storages hold them joined by
    /// blank lines. An update replaces only the blocks from the first one that
    /// changed, so a streaming reply relays out only its tail.
    private var renderedBlocks: [NSAttributedString] = []
    private(set) var resolvedColorCount = 0
    private(set) var appliedUpdateCount = 0
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

    func update(source: String, swiftUIColor color: Color) {
        guard source != renderedSource || color != configuredColor else { return }
        let resolved: NSColor
        if color == configuredColor, let renderedColor {
            resolved = renderedColor
        } else {
            resolved = MessageTextBlockCache.resolved(color)
            resolvedColorCount += 1
        }
        configuredColor = color
        apply(source: source, color: resolved)
    }

    /// Native callers and focused AppKit tests can bypass SwiftUI color
    /// resolution while retaining the same idempotent text update behavior.
    func update(source: String, color: NSColor) {
        guard source != renderedSource || color != renderedColor else { return }
        configuredColor = nil
        apply(source: source, color: color)
    }

    private func apply(source: String, color: NSColor) {
        let selection = selectedRange()
        let previousText = string
        let blocks = Self.attributedBlocks(source: source, color: color)
        let storages = [textStorage, measurementStorage].compactMap { $0 }
        // Blocks render independently and unchanged ones are the same cached
        // values, so the storages keep every block before the first change.
        var kept = 0
        let renderedLength = Self.joinedLength(renderedBlocks)
        if color == renderedColor, storages.allSatisfy({ $0.length == renderedLength }) {
            while kept < min(renderedBlocks.count, blocks.count),
                renderedBlocks[kept] === blocks[kept] || renderedBlocks[kept].isEqual(to: blocks[kept])
            {
                kept += 1
            }
        }
        let start = Self.joinedLength(renderedBlocks[..<kept])
        let tail = Self.joined(blocks[kept...], afterBlocks: kept > 0)
        for storage in storages where storage.length > start || tail.length > 0 {
            storage.replaceCharacters(in: NSRange(location: start, length: storage.length - start), with: tail)
        }
        renderedBlocks = blocks
        // Streaming and theme updates must not clear an in-progress selection.
        let text = string
        if text == previousText || text.hasPrefix(previousText) {
            setSelectedRange(NSIntersectionRange(selection, NSRange(location: 0, length: (text as NSString).length)))
        } else {
            setSelectedRange(NSRange(location: 0, length: 0))
        }
        renderedSource = source
        renderedColor = color
        appliedUpdateCount += 1
        // NSViewRepresentable.sizeThatFits owns this view's SwiftUI size.
        // Invalidating AppKit's intrinsic size from updateNSView can re-enter
        // NSHostingView layout while SwiftUI is still rendering the update;
        // AppKit then skips that layout pass and the transcript appears to
        // stall until a later frame. SwiftUI remeasures sizeThatFits whenever
        // this representable's source or environment changes.
    }

    func fittingSize(width proposedWidth: CGFloat?) -> CGSize {
        let width = max(1, proposedWidth.flatMap { $0.isFinite ? $0 : nil } ?? 620)
        // A proposal may be rejected. Never change the displayed container's
        // width, glyph layout or frame just to answer a sizing question.
        let size = NSSize(width: width, height: .greatestFiniteMagnitude)
        // Resizing the container invalidates its whole layout; repeated
        // proposals at the same width reuse it.
        if measurementContainer.containerSize != size { measurementContainer.containerSize = size }
        measurementLayout.ensureLayout(for: measurementContainer)
        let used = measurementLayout.usedRect(for: measurementContainer)
        return NSSize(width: min(width, ceil(used.width)), height: ceil(used.height))
    }

    static func attributedText(source: String, color: NSColor) -> NSAttributedString {
        joined(attributedBlocks(source: source, color: color)[...], afterBlocks: false)
    }

    /// Each Markdown block of `source`, rendered on its own.
    static func attributedBlocks(source: String, color: NSColor) -> [NSAttributedString] {
        ConversationRenderCache.blocks(source).map { block in
            MessageTextBlockCache.rendered(block, color: color, theme: themeColors(block)) {
                render(block, color: color)
            }
        }
    }

    /// The theme colors a block is rendered with besides its text color.
    private static func themeColors(_ block: ConversationMarkdownBlock) -> [Color] {
        switch block {
        case .paragraph, .heading, .bullet: []
        case .code: [DieterTheme.inset]
        case .table: [DieterTheme.border, DieterTheme.tile, DieterTheme.tileHover]
        }
    }

    /// `blocks` separated by blank lines; after earlier blocks, one leads.
    private static func joined(_ blocks: ArraySlice<NSAttributedString>, afterBlocks: Bool) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (index, block) in blocks.enumerated() {
            if index > 0 || afterBlocks {
                result.append(NSAttributedString(string: "\n\n"))
            }
            result.append(block)
        }
        return result
    }

    private static func joinedLength<C: Collection<NSAttributedString>>(_ blocks: C) -> Int {
        blocks.reduce(0) { $0 + $1.length } + 2 * max(0, blocks.count - 1)
    }

    private static func render(_ block: ConversationMarkdownBlock, color: NSColor) -> NSAttributedString {
        switch block {
        case .paragraph(let text):
            return inlineText(source: text, color: color)
        case .heading(let level, let text):
            return inlineText(
                source: text, color: color,
                size: level == 1 ? 17 : 15, bold: true)
        case .bullet(let text):
            return inlineText(source: "• " + text, color: color)
        case .code(let text):
            return NSAttributedString(
                string: text,
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                    .foregroundColor: color,
                    .backgroundColor: NSColor(DieterTheme.inset),
                ])
        case .table(let table):
            let result = NSMutableAttributedString()
            append(table: table, to: result, color: color)
            return result
        }
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
                cell.backgroundColor = NSColor(row == 0 ? DieterTheme.tileHover : DieterTheme.tile)
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

/// Rendered Markdown blocks by their content and colors. Rendering a block
/// detects its links through the shared core and converts its fonts, so while
/// a reply streams only the block that changed is rendered again, and its
/// unchanged blocks stay the identical values the text view keeps in place.
/// Messages share them, so reopening a recent conversation renders little.
@MainActor private enum MessageTextBlockCache {
    private struct Key: Hashable {
        let block: ConversationMarkdownBlock
        let color: NSColor
        let theme: [Color]
    }

    private static let generationLimit = 1_024
    // Two generations bound the cache: a full one becomes the older, and a
    // block still in use moves back into the newer one when it is read.
    private static var current: [Key: NSAttributedString] = [:]
    private static var previous: [Key: NSAttributedString] = [:]
    private static var colors: [Color: NSColor] = [:]

    static func rendered(
        _ block: ConversationMarkdownBlock, color: NSColor, theme: [Color], render: () -> NSAttributedString
    ) -> NSAttributedString {
        let key = Key(block: block, color: color, theme: theme)
        if let value = current[key] { return value }
        let value = previous[key] ?? render()
        if current.count >= generationLimit {
            previous = current
            current = [:]
        }
        current[key] = value
        return value
    }

    /// One AppKit color per theme color, so every message's blocks share keys.
    static func resolved(_ color: Color) -> NSColor {
        if let resolved = colors[color] { return resolved }
        let resolved = NSColor(color)
        if colors.count >= 64 { colors = [:] }
        colors[color] = resolved
        return resolved
    }
}
