import AppKit
import SwiftUI

/// One native selection surface for the complete message, including paragraph
/// breaks. SwiftUI's Text selection on macOS stops at each paragraph.
struct SelectableMessageText: NSViewRepresentable {
    let source: String
    let color: Color

    func makeNSView(context: Context) -> MessageTextView {
        MessageTextView()
    }

    func updateNSView(_ view: MessageTextView, context: Context) {
        view.update(source: source, color: NSColor(color))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MessageTextView, context: Context) -> CGSize? {
        nsView.fittingSize(width: proposal.width)
    }
}

final class MessageTextView: NSTextView {
    private var renderedSource: String?
    private var renderedColor: NSColor?

    init() {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(containerSize: .zero)
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        isEditable = false
        isSelectable = true
        isRichText = true
        drawsBackground = false
        textContainerInset = .zero
        textContainer?.lineFragmentPadding = 0
        textContainer?.widthTracksTextView = true
        isHorizontallyResizable = false
        isVerticallyResizable = true
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
        guard let textContainer, let layoutManager else { return .zero }
        let width = max(1, proposedWidth.flatMap { $0.isFinite ? $0 : nil } ?? 620)
        // SwiftUI asks for a size before assigning our frame. Measure against
        // its proposed width rather than the previous (initially zero) frame.
        textContainer.widthTracksTextView = false
        defer { textContainer.widthTracksTextView = true }
        textContainer.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
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
                result.append(inlineText(source: text, color: color,
                                         size: level == 1 ? 17 : 15, bold: true))
            case .bullet(let text):
                result.append(inlineText(source: "• " + text, color: color))
            case .code(let text):
                result.append(NSAttributedString(string: text, attributes: [
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

    private static func append(table: ConversationMarkdownTable,
                               to result: NSMutableAttributedString, color: NSColor) {
        let nativeTable = NSTextTable()
        nativeTable.numberOfColumns = table.headers.count
        nativeTable.layoutAlgorithm = .fixedLayoutAlgorithm
        nativeTable.collapsesBorders = true
        nativeTable.setValue(100, type: .percentageValueType, for: .width)
        for (row, cells) in ([table.headers] + table.rows).enumerated() {
            for column in table.headers.indices {
                let cell = NSTextTableBlock(table: nativeTable, startingRow: row, rowSpan: 1,
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
                let content = NSMutableAttributedString(attributedString: inlineText(
                    source: column < cells.count ? cells[column] : "", color: color, size: 12, bold: row == 0))
                content.append(NSAttributedString(string: "\n"))
                content.addAttribute(.paragraphStyle, value: style,
                                     range: NSRange(location: 0, length: content.length))
                result.append(content)
            }
        }
    }

    private static func inlineText(source: String, color: NSColor,
                                   size: CGFloat = 13, bold: Bool = false) -> NSAttributedString {
        let markdown = ConversationRenderCache.markdown(source)
        let result = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        for run in markdown.runs {
            let intent = run.inlinePresentationIntent ?? []
            var font = intent.contains(.code)
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
        return result
    }
}
