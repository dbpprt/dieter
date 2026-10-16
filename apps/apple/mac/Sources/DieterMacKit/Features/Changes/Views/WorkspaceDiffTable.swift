import AppKit
import SwiftUI

// MARK: - Rows

/// A row of the diff table: the core's rows flattened, with each unified
/// line's comments and an expanded fold's lines as rows of their own.
enum WorkspaceDiffItem: Equatable {
    case line(WorkspaceDiffLine)
    case comment(WorkspaceDiffComment)
    case pair(WorkspaceSplitPair)
    case file(id: Int, path: String)
    /// The unchanged lines the core left out before a hunk.
    case separator(hunkID: Int, count: Int)
    case hunk(id: Int, text: String, additions: Int, deletions: Int)
    case fold(id: Int, count: Int, expanded: Bool)
    /// Loading the rest of the diff, or why it stops.
    case footer

    /// A row's identity within one diff; its height is kept by it.
    enum Key: Hashable {
        case line(Int)
        case comment(String)
        case pair(Int)
        case file(Int)
        case separator(Int)
        case hunk(Int)
        case fold(Int)
        case footer
    }

    var key: Key {
        switch self {
        case .line(let line): .line(line.id)
        case .comment(let comment): .comment(comment.id)
        case .pair(let pair): .pair(pair.id)
        case .file(let id, _): .file(id)
        case .separator(let id, _): .separator(id)
        case .hunk(let id, _, _, _): .hunk(id)
        case .fold(let id, _, _): .fold(id)
        case .footer: .footer
        }
    }

    var reuseIdentifier: NSUserInterfaceItemIdentifier {
        switch self {
        case .line: Self.lineCell
        case .comment: Self.commentCell
        case .pair: Self.pairCell
        case .file, .hunk: Self.headerCell
        case .separator, .fold: Self.labelCell
        case .footer: Self.footerCell
        }
    }

    private static let lineCell = NSUserInterfaceItemIdentifier("diff.line")
    private static let commentCell = NSUserInterfaceItemIdentifier("diff.comment")
    private static let pairCell = NSUserInterfaceItemIdentifier("diff.pair")
    private static let headerCell = NSUserInterfaceItemIdentifier("diff.header")
    private static let labelCell = NSUserInterfaceItemIdentifier("diff.label")
    private static let footerCell = NSUserInterfaceItemIdentifier("diff.footer")

    /// `layout`'s rows in order, with the folds in `expandedFolds` open.
    static func items(_ layout: WorkspaceDiffLayout, expandedFolds: Set<Int>) -> [Self] {
        var items: [Self] = []
        items.reserveCapacity(layout.rows.count + 1)
        func append(_ line: WorkspaceDiffLine) {
            items.append(.line(line))
            for comment in line.comments { items.append(.comment(comment)) }
        }
        for row in layout.rows {
            switch row {
            case .line(let line): append(line)
            case .pair(let pair): items.append(.pair(pair))
            case .file(let id, let path): items.append(.file(id: id, path: path))
            case .hunk(let id, let text, let skipped, let additions, let deletions):
                if skipped > 0 { items.append(.separator(hunkID: id, count: skipped)) }
                items.append(.hunk(id: id, text: text, additions: additions, deletions: deletions))
            case .fold(let id, let count, let lines, let pairs):
                let expanded = expandedFolds.contains(id)
                items.append(.fold(id: id, count: count, expanded: expanded))
                guard expanded else { continue }
                if layout.split {
                    for pair in pairs { items.append(.pair(pair)) }
                } else {
                    lines.forEach(append)
                }
            }
        }
        if layout.more || !layout.note.isEmpty { items.append(.footer) }
        return items
    }

    /// A unified line's text: the whole row where its marker column holds the
    /// comment button or it is a header, else the row without its marker.
    static func text(_ line: WorkspaceDiffLine) -> String {
        let kind = line.line.kind
        return code(
            line.commentable || kind == .header || kind == .hunk ? line.line.text : String(line.line.text.dropFirst()))
    }

    /// One side of a split row, without its marker; nil where the side has no line.
    static func text(_ line: UnifiedDiffLine?) -> String? {
        line.map { code(String($0.text.dropFirst())) }
    }

    /// Diff text as rows show it: tabs as four spaces, a line's carriage
    /// return dropped, never empty, so a blank line keeps its height.
    static func code(_ text: String) -> String {
        let text = text.hasSuffix("\r") ? String(text.dropLast()) : text
        let code = text.contains("\t") ? text.replacingOccurrences(of: "\t", with: "    ") : text
        return code.isEmpty ? " " : code
    }
}

/// What every row of one diff shows besides itself.
struct WorkspaceDiffRowContext {
    var palette: WorkspaceDiffPalette
    var reviewSection: String?
    var more = false
    var loadingMore = false
    var note = ""
}

// MARK: - Text

/// The diff's fonts and fixed sizes.
@MainActor enum WorkspaceDiffStyle {
    static let code = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let hunk = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
    static let path = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
    static let counts = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
    static let label = NSFont.systemFont(ofSize: 10, weight: .medium)
    static let badge = NSFont.systemFont(ofSize: 9, weight: .semibold)
    static let comment = NSFont.systemFont(ofSize: 11)
    static let byline = NSFont.systemFont(ofSize: 9)
    static let note = NSFont.systemFont(ofSize: 11)
    /// A one-line code row; wrapped text grows it.
    static let row: CGFloat = 23
    static let gutter: CGFloat = 42
    /// The unified marker (or comment button) column.
    static let marker: CGFloat = 22
    /// A split side's marker column.
    static let pairMarker: CGFloat = 20
    static let commentInset: CGFloat = 97
    static let commentIcon: CGFloat = 14
}

/// Measures wrapped text exactly as `WorkspaceDiffTextView` lays it out.
/// Printable ASCII in a monospaced font, which code lines are, wraps by
/// columns at the last space that fits; the text view shows those lines as
/// they were counted, so a diff of thousands of lines measures by arithmetic.
/// Other text wraps by TextKit 1, measured on a stack set up like the view's.
@MainActor final class WorkspaceDiffTextMeasure {
    static let shared = WorkspaceDiffTextMeasure()

    /// Separates the lines of column-wrapped text; copying leaves it out.
    nonisolated static let softBreak = "\u{2028}"

    private let storage = NSTextStorage()
    private let layoutManager = NSLayoutManager()
    private let container = NSTextContainer(size: .zero)
    private var advances: [NSFont: CGFloat] = [:]
    private var lineHeights: [NSFont: [Int: CGFloat]] = [:]

    private init() {
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
    }

    /// The height of `text` wrapped to `width`.
    func height(_ text: String, font: NSFont, width: CGFloat) -> CGFloat {
        if let columns = columns(text, font: font, width: width) {
            return height(lines: Self.breaks(Array(text.utf8), columns: columns).count + 1, font: font)
        }
        return ceil(usedRect(text, font: font, width: max(1, width)).height)
    }

    /// One line's height in `font`.
    func lineHeight(_ font: NSFont) -> CGFloat { height(lines: 1, font: font) }

    /// How many characters a line of `text` holds at `width`, when it wraps
    /// by columns; nil when TextKit wraps it.
    func columns(_ text: String, font: NSFont, width: CGFloat) -> Int? {
        guard font.isFixedPitch, text.utf8.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return nil }
        return max(1, Int((max(1, width) - 1) / advance(font)))
    }

    /// Where each line of column-wrapped `bytes` after the first starts:
    /// after the last space that fits, with any spaces that follow it, which
    /// hang past the margin; mid-word where no space fits.
    nonisolated static func breaks(_ bytes: [UInt8], columns: Int) -> [Int] {
        var breaks: [Int] = []
        var start = 0
        while bytes.count - start > columns {
            let limit = start + columns
            var next = limit
            var index = limit
            while index > start {
                if bytes[index] == 0x20 {
                    next = index + 1
                    break
                }
                index -= 1
            }
            while next < bytes.count, bytes[next] == 0x20 { next += 1 }
            guard next < bytes.count else { break }
            breaks.append(next)
            start = next
        }
        return breaks
    }

    /// `text` with a soft break where each column-wrapped line starts.
    nonisolated static func softWrapped(_ text: String, columns: Int) -> String {
        let bytes = Array(text.utf8)
        let breaks = breaks(bytes, columns: columns)
        guard !breaks.isEmpty else { return text }
        var result = String()
        result.reserveCapacity(bytes.count + 3 * breaks.count)
        var start = 0
        for next in breaks {
            result += String(decoding: bytes[start..<next], as: UTF8.self)
            result += softBreak
            start = next
        }
        result += String(decoding: bytes[start...], as: UTF8.self)
        return result
    }

    /// The height TextKit gives `lines` lines of `font`.
    private func height(lines: Int, font: NSFont) -> CGFloat {
        if let height = lineHeights[font]?[lines] { return height }
        let sample = Array(repeating: "M", count: lines).joined(separator: Self.softBreak)
        let height = ceil(usedRect(sample, font: font, width: .greatestFiniteMagnitude).height)
        lineHeights[font, default: [:]][lines] = height
        return height
    }

    private func advance(_ font: NSFont) -> CGFloat {
        if let advance = advances[font] { return advance }
        let sample = String(repeating: "M", count: 64)
        let advance = usedRect(sample, font: font, width: .greatestFiniteMagnitude).width / 64
        advances[font] = advance
        return advance
    }

    private func usedRect(_ text: String, font: NSFont, width: CGFloat) -> CGRect {
        container.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        storage.setAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        layoutManager.ensureLayout(for: container)
        return layoutManager.usedRect(for: container)
    }
}

/// Selectable wrapped text, laid out the way the measure counted it: by
/// columns with soft breaks, or by TextKit 1 at its width. Copying leaves the
/// soft breaks out, so a copied line is the line as it is in the file.
final class WorkspaceDiffTextView: NSTextView {
    private var source: (text: String, font: NSFont, color: NSColor)?
    /// The width and columns the text was last laid out for.
    private var wrapped: (width: CGFloat, columns: Int?)?

    init() {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        isEditable = false
        isSelectable = true
        isRichText = false
        drawsBackground = false
        textContainerInset = .zero
        isVerticallyResizable = false
        isHorizontallyResizable = false
        allowsUndo = false
        focusRingType = .none
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    func show(_ text: String, font: NSFont, color: NSColor) {
        if let source, source.text == text, source.font == font, source.color == color { return }
        source = (text, font, color)
        wrapped = nil
    }

    /// Lays the text out for `width`, as the measure did.
    func wrap(to width: CGFloat) {
        guard let source else { return }
        let columns = WorkspaceDiffTextMeasure.shared.columns(source.text, font: source.font, width: width)
        if let wrapped, wrapped.columns == columns {
            // Column-wrapped lines stay; TextKit wraps at the new width.
            if columns == nil, wrapped.width != width {
                textContainer?.size = NSSize(width: width, height: .greatestFiniteMagnitude)
                self.wrapped = (width, nil)
            }
            return
        }
        wrapped = (width, columns)
        let text: String
        if let columns {
            text = WorkspaceDiffTextMeasure.softWrapped(source.text, columns: columns)
            textContainer?.size = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        } else {
            text = source.text
            textContainer?.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        }
        textStorage?.setAttributedString(
            NSAttributedString(string: text, attributes: [.font: source.font, .foregroundColor: source.color]))
        setSelectedRange(NSRange(location: 0, length: 0))
    }

    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        let text = string as NSString
        let selected = selectedRanges.map { text.substring(with: $0.rangeValue) }.joined(separator: "\n")
        pboard.declareTypes([.string], owner: nil)
        return pboard.setString(
            selected.replacingOccurrences(of: WorkspaceDiffTextMeasure.softBreak, with: ""), forType: .string)
    }
}

// MARK: - Geometry

/// Where a row's parts go at one width; its height is the table's row height.
struct WorkspaceDiffGeometry {
    var width: CGFloat
    var height: CGFloat
    /// The first text line's top, where gutters, markers, and badges align.
    var top: CGFloat
    var lineHeight: CGFloat
    var primary: CGRect = .zero
    var secondary: CGRect = .zero
    /// Split rows: the divider's x.
    var divider: CGFloat = 0
    /// Hunk rows: the counts and the review badge.
    var counts: CGRect = .zero
    var badge: CGRect = .zero
}

extension WorkspaceDiffItem {
    /// This row laid out at `width`.
    @MainActor func geometry(width: CGFloat, context: WorkspaceDiffRowContext) -> WorkspaceDiffGeometry {
        let measure = WorkspaceDiffTextMeasure.shared
        typealias Style = WorkspaceDiffStyle
        switch self {
        case .line(let line):
            let lineHeight = measure.lineHeight(Style.code)
            let top = floor((Style.row - lineHeight) / 2)
            let x = 2 * Style.gutter + Style.marker + 5
            let textWidth = max(20, width - x - 12)
            let height = measure.height(Self.text(line), font: Style.code, width: textWidth)
            return WorkspaceDiffGeometry(
                width: width, height: max(Style.row, height + 2 * top), top: top, lineHeight: lineHeight,
                primary: CGRect(x: x, y: top, width: textWidth, height: height))
        case .pair(let pair):
            let lineHeight = measure.lineHeight(Style.code)
            let top = floor((Style.row - lineHeight) / 2)
            let left = floor((width - 1) / 2)
            let x = Style.gutter + Style.pairMarker + 6
            let leftWidth = max(20, left - x - 8)
            let rightWidth = max(20, width - 1 - left - x - 8)
            let leftHeight = Self.text(pair.old).map { measure.height($0, font: Style.code, width: leftWidth) } ?? 0
            let rightHeight = Self.text(pair.new).map { measure.height($0, font: Style.code, width: rightWidth) } ?? 0
            return WorkspaceDiffGeometry(
                width: width, height: max(Style.row, max(leftHeight, rightHeight) + 2 * top), top: top,
                lineHeight: lineHeight, primary: CGRect(x: x, y: top, width: leftWidth, height: leftHeight),
                secondary: CGRect(x: left + 1 + x, y: top, width: rightWidth, height: rightHeight), divider: left)
        case .comment(let comment):
            let x = Style.commentInset + Style.commentIcon + 8
            let textWidth = max(20, width - x - 9)
            let body = measure.height(comment.body, font: Style.comment, width: textWidth)
            let byline = measure.height(comment.byline, font: Style.byline, width: textWidth)
            return WorkspaceDiffGeometry(
                width: width, height: 9 + body + 3 + byline + 9, top: 9,
                lineHeight: measure.lineHeight(Style.comment),
                primary: CGRect(x: x, y: 9, width: textWidth, height: body),
                secondary: CGRect(x: x, y: 9 + body + 3, width: textWidth, height: byline))
        case .file(_, let path):
            let lineHeight = measure.lineHeight(Style.path)
            let top = floor((30 - lineHeight) / 2)
            let x: CGFloat = 12 + 11 + 7
            let textWidth = max(20, width - x - 12)
            let height = measure.height(path, font: Style.path, width: textWidth)
            return WorkspaceDiffGeometry(
                width: width, height: max(30, height + 2 * top), top: top, lineHeight: lineHeight,
                primary: CGRect(x: x, y: top, width: textWidth, height: height))
        case .hunk(_, let text, let additions, let deletions):
            let lineHeight = measure.lineHeight(Style.hunk)
            let top = floor((32 - lineHeight) / 2)
            var trailing = width - 14
            var geometry = WorkspaceDiffGeometry(width: width, height: 32, top: top, lineHeight: lineHeight)
            if let section = context.reviewSection {
                let size = WorkspaceDiffCell.badgeText(section, context.palette).size()
                let badge = CGSize(width: ceil(size.width) + 12, height: ceil(size.height) + 6)
                geometry.badge = CGRect(
                    x: trailing - badge.width, y: top + floor((lineHeight - badge.height) / 2), width: badge.width,
                    height: badge.height)
                trailing = geometry.badge.minX - 10
            }
            if additions > 0 || deletions > 0 {
                let size = WorkspaceDiffCell.countsText(additions, deletions, context.palette).size()
                let countsHeight = ceil(size.height)
                geometry.counts = CGRect(
                    x: trailing - ceil(size.width), y: top + floor((lineHeight - countsHeight) / 2),
                    width: ceil(size.width), height: countsHeight)
                trailing = geometry.counts.minX - 10
            }
            let textWidth = max(20, trailing - 14)
            let height = measure.height(text, font: Style.hunk, width: textWidth)
            geometry.primary = CGRect(x: 14, y: top, width: textWidth, height: height)
            geometry.height = max(32, height + 2 * top)
            return geometry
        case .separator:
            return WorkspaceDiffGeometry(width: width, height: 22, top: 0, lineHeight: 22)
        case .fold:
            return WorkspaceDiffGeometry(width: width, height: 24, top: 0, lineHeight: 24)
        case .footer:
            let height =
                context.more ? 54 : 24 + measure.height(context.note, font: Style.note, width: max(20, width - 24))
            return WorkspaceDiffGeometry(width: width, height: height, top: 12, lineHeight: height)
        }
    }
}

// MARK: - Cell

/// One row of the diff. It paints its backgrounds, gutters, markers, and
/// labels, and shows its wrapped text in text views it reuses.
final class WorkspaceDiffCell: NSView {
    override var isFlipped: Bool { true }

    private(set) var item: WorkspaceDiffItem?
    private var context = WorkspaceDiffRowContext(palette: .current)
    private var geometry: WorkspaceDiffGeometry?
    /// The row laid out at a width, as the table measured it.
    var resolveGeometry: (WorkspaceDiffItem, CGFloat) -> WorkspaceDiffGeometry = { item, width in
        item.geometry(width: width, context: WorkspaceDiffRowContext(palette: .current))
    }
    var addComment: (UnifiedDiffLine) -> Void = { _ in }
    var toggleFold: (Int) -> Void = { _ in }
    var loadMore: () -> Void = {}

    private var primaryView: WorkspaceDiffTextView?
    private var secondaryView: WorkspaceDiffTextView?
    private var commentButton: NSButton?
    private var footer: NSHostingView<WorkspaceDiffEnd>?
    private var hoverArea: NSTrackingArea?
    private var hovering = false

    func configure(_ item: WorkspaceDiffItem, context: WorkspaceDiffRowContext) {
        // A reused cell shows another row; the pointer was over the old one.
        if item.key != self.item?.key { hovering = false }
        self.item = item
        self.context = context
        geometry = nil
        let palette = context.palette
        typealias Style = WorkspaceDiffStyle
        switch item {
        case .line(let line):
            show(primary: (Self.text(line), Style.code, Self.foreground(line.line.kind, palette)), secondary: nil)
        case .pair(let pair):
            show(
                primary: Self.text(pair.old).map { ($0, Style.code, Self.foreground(pair.old?.kind, palette)) },
                secondary: Self.text(pair.new).map { ($0, Style.code, Self.foreground(pair.new?.kind, palette)) })
        case .comment(let comment):
            show(
                primary: (comment.body, Style.comment, palette.text),
                secondary: (comment.byline, Style.byline, palette.tertiary))
        case .file(_, let path):
            show(primary: (path, Style.path, palette.text), secondary: nil)
        case .hunk(_, let text, _, _):
            show(primary: (text, Style.hunk, palette.subtle), secondary: nil)
        case .separator, .fold, .footer:
            show(primary: nil, secondary: nil)
        }
        configureCommentButton()
        configureFooter()
        if case .fold(_, _, let expanded) = item {
            toolTip = expanded ? "Collapse this unchanged region" : "Expand this unchanged region"
        } else {
            toolTip = nil
        }
        #if DIETER_E2E
            if NativeTestSupport.isE2E {
                if case .hunk(let id, _, _, _) = item {
                    E2ETargets.register(self, identifier: "workspace-diff.hunk.\(id)", text: nil)
                } else {
                    E2ETargets.unregister(self)
                }
            }
        #endif
        needsLayout = true
        needsDisplay = true
    }

    private static func text(_ line: WorkspaceDiffLine) -> String { WorkspaceDiffItem.text(line) }
    private static func text(_ line: UnifiedDiffLine?) -> String? { WorkspaceDiffItem.text(line) }

    private func show(
        primary: (String, NSFont, NSColor)?, secondary: (String, NSFont, NSColor)?
    ) {
        if let primary {
            let view = primaryView ?? addTextView(&primaryView)
            view.show(primary.0, font: primary.1, color: primary.2)
            view.isHidden = false
        } else {
            primaryView?.isHidden = true
        }
        if let secondary {
            let view = secondaryView ?? addTextView(&secondaryView)
            view.show(secondary.0, font: secondary.1, color: secondary.2)
            view.isHidden = false
        } else {
            secondaryView?.isHidden = true
        }
    }

    private func addTextView(_ slot: inout WorkspaceDiffTextView?) -> WorkspaceDiffTextView {
        let view = WorkspaceDiffTextView()
        addSubview(view)
        slot = view
        return view
    }

    private func configureCommentButton() {
        guard case .line(let line) = item, line.commentable else {
            commentButton?.isHidden = true
            return
        }
        let button = commentButton ?? makeCommentButton()
        button.contentTintColor = context.palette.shell
        button.isHidden = !(hovering || !line.comments.isEmpty)
    }

    private func makeCommentButton() -> NSButton {
        let image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add comment")?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .bold))
        let button = NSButton(image: image ?? NSImage(), target: self, action: #selector(commentPressed))
        button.isBordered = false
        button.setButtonType(.momentaryChange)
        addSubview(button)
        commentButton = button
        return button
    }

    @objc private func commentPressed() {
        if case .line(let line) = item { addComment(line.line) }
    }

    private func configureFooter() {
        guard case .footer = item else {
            footer?.isHidden = true
            return
        }
        let content = WorkspaceDiffEnd(
            more: context.more, loading: context.loadingMore, note: context.note,
            loadMore: { [weak self] in
                self?.loadMore()
            })
        if let footer {
            footer.rootView = content
            footer.isHidden = false
        } else {
            let host = NSHostingView(rootView: content)
            host.sizingOptions = []
            addSubview(host)
            footer = host
        }
    }

    override func layout() {
        super.layout()
        guard let item else { return }
        if geometry?.width != bounds.width { geometry = resolveGeometry(item, bounds.width) }
        guard let geometry else { return }
        primaryView?.frame = geometry.primary
        primaryView?.wrap(to: geometry.primary.width)
        secondaryView?.frame = geometry.secondary
        secondaryView?.wrap(to: geometry.secondary.width)
        commentButton?.frame = CGRect(
            x: 2 * WorkspaceDiffStyle.gutter, y: geometry.top + floor((geometry.lineHeight - 20) / 2),
            width: WorkspaceDiffStyle.marker, height: 20)
        footer?.frame = bounds
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        configureCommentButton()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        configureCommentButton()
    }

    override func mouseDown(with event: NSEvent) {
        if case .fold(let id, _, _) = item {
            toggleFold(id)
        } else {
            super.mouseDown(with: event)
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let item else { return }
        let geometry = geometry ?? resolveGeometry(item, bounds.width)
        let palette = context.palette
        typealias Style = WorkspaceDiffStyle
        switch item {
        case .line(let line):
            Self.fill(bounds, Self.lineFill(line.line.kind, palette))
            Self.fill(CGRect(x: 0, y: 0, width: 2 * Style.gutter, height: bounds.height), palette.gutterFill)
            drawNumber(line.line.oldLine, right: Style.gutter - 7, geometry: geometry)
            drawNumber(line.line.newLine, right: 2 * Style.gutter - 7, geometry: geometry)
            if !line.commentable {
                drawMarker(
                    line.line.kind, x: 2 * Style.gutter, width: Style.marker, geometry: geometry,
                    color: Self.foreground(line.line.kind, palette))
            }
        case .pair(let pair):
            let left = geometry.divider
            drawSide(pair.old, number: pair.old?.oldLine, x: 0, width: left, geometry: geometry)
            drawSide(
                pair.new, number: pair.new?.newLine, x: left + 1, width: bounds.width - left - 1, geometry: geometry)
            Self.fill(CGRect(x: left, y: 0, width: 1, height: bounds.height), palette.border)
        case .comment:
            Self.fill(bounds, palette.commentFill)
            if let icon = Self.symbol("text.bubble.fill", size: 12, weight: .regular, color: palette.shell) {
                drawSymbol(icon, x: Style.commentInset, centeredOn: geometry.top + geometry.lineHeight / 2)
            }
        case .file:
            Self.fill(bounds, palette.headerFill)
            if let icon = Self.symbol("doc.text", size: 9, weight: .semibold, color: palette.subtle) {
                drawSymbol(icon, x: 12, centeredOn: geometry.top + geometry.lineHeight / 2)
            }
        case .hunk(_, _, let additions, let deletions):
            Self.fill(bounds, palette.headerFill)
            if additions > 0 || deletions > 0 {
                Self.countsText(additions, deletions, palette).draw(at: geometry.counts.origin)
            }
            if let section = context.reviewSection {
                let staged = section == "staged"
                NSBezierPath(roundedRect: geometry.badge, xRadius: 3, yRadius: 3).fill(
                    with: staged ? palette.stagedBadgeFill : palette.badgeFill)
                let text = Self.badgeText(section, palette)
                let size = text.size()
                text.draw(
                    at: CGPoint(
                        x: geometry.badge.midX - size.width / 2, y: geometry.badge.midY - size.height / 2))
                if staged { Self.fill(CGRect(x: 0, y: 0, width: 2, height: bounds.height), palette.reviewAccent) }
            }
            Self.fill(CGRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1), palette.hairline)
        case .separator(_, let count):
            drawLabel(symbol: "ellipsis", text: "\(count) unchanged lines", color: palette.tertiary)
        case .fold(_, let count, let expanded):
            Self.fill(bounds, palette.foldFill)
            drawLabel(
                symbol: expanded ? "chevron.up" : "chevron.down",
                text: expanded ? "Hide \(count) unchanged lines" : "\(count) unchanged lines", color: palette.subtle)
        case .footer:
            break
        }
    }

    private func drawSide(
        _ line: UnifiedDiffLine?, number: Int?, x: CGFloat, width: CGFloat, geometry: WorkspaceDiffGeometry
    ) {
        let palette = context.palette
        let fill: NSColor =
            switch line?.kind {
            case .addition: palette.additionFill
            case .deletion: palette.deletionFill
            case .context: .clear
            default: palette.missingFill
            }
        Self.fill(CGRect(x: x, y: 0, width: width, height: bounds.height), fill)
        Self.fill(
            CGRect(x: x, y: 0, width: WorkspaceDiffStyle.gutter, height: bounds.height), palette.gutterFill)
        drawNumber(number, right: x + WorkspaceDiffStyle.gutter - 7, geometry: geometry)
        drawMarker(
            line?.kind, x: x + WorkspaceDiffStyle.gutter, width: WorkspaceDiffStyle.pairMarker, geometry: geometry,
            color: Self.foreground(line?.kind, palette))
    }

    private func drawNumber(_ number: Int?, right: CGFloat, geometry: WorkspaceDiffGeometry) {
        guard let number else { return }
        let text = NSAttributedString(
            string: String(number),
            attributes: [.font: WorkspaceDiffStyle.code, .foregroundColor: context.palette.tertiary])
        text.draw(at: CGPoint(x: right - ceil(text.size().width), y: geometry.top))
    }

    private func drawMarker(
        _ kind: UnifiedDiffLine.Kind?, x: CGFloat, width: CGFloat, geometry: WorkspaceDiffGeometry, color: NSColor
    ) {
        let marker =
            switch kind {
            case .addition: "+"
            case .deletion: "−"
            default: ""
            }
        guard !marker.isEmpty else { return }
        let text = NSAttributedString(
            string: marker, attributes: [.font: WorkspaceDiffStyle.code, .foregroundColor: color])
        text.draw(at: CGPoint(x: x + floor((width - text.size().width) / 2), y: geometry.top))
    }

    private func drawLabel(symbol: String, text: String, color: NSColor) {
        let label = NSAttributedString(
            string: text, attributes: [.font: WorkspaceDiffStyle.label, .foregroundColor: color])
        let middle = bounds.height / 2
        var x: CGFloat = 12
        if let image = Self.symbol(symbol, size: 8, weight: .bold, color: color) {
            drawSymbol(image, x: x, centeredOn: middle)
            x += ceil(image.size.width) + 6
        }
        let size = label.size()
        label.draw(at: CGPoint(x: x, y: floor(middle - size.height / 2)))
    }

    private func drawSymbol(_ image: NSImage, x: CGFloat, centeredOn middle: CGFloat) {
        let rect = CGRect(
            x: x, y: floor(middle - image.size.height / 2), width: image.size.width, height: image.size.height)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    // MARK: Style

    static func badgeText(_ section: String, _ palette: WorkspaceDiffPalette) -> NSAttributedString {
        NSAttributedString(
            string: section.uppercased(),
            attributes: [
                .font: WorkspaceDiffStyle.badge, .kern: 0.4,
                .foregroundColor: section == "staged" ? palette.reviewAccent : palette.tertiary,
            ])
    }

    static func countsText(_ additions: Int, _ deletions: Int, _ palette: WorkspaceDiffPalette) -> NSAttributedString {
        let font = WorkspaceDiffStyle.counts
        let text = NSMutableAttributedString(
            string: "+\(additions)", attributes: [.font: font, .foregroundColor: palette.addition])
        // The counts sit 5 points apart.
        text.append(NSAttributedString(string: " ", attributes: [.font: font, .kern: 5 - spaceWidth(font)]))
        text.append(
            NSAttributedString(string: "−\(deletions)", attributes: [.font: font, .foregroundColor: palette.deletion]))
        return text
    }

    private static func spaceWidth(_ font: NSFont) -> CGFloat {
        NSAttributedString(string: " ", attributes: [.font: font]).size().width
    }

    private static func foreground(_ kind: UnifiedDiffLine.Kind?, _ palette: WorkspaceDiffPalette) -> NSColor {
        switch kind {
        case .addition: palette.addition
        case .deletion: palette.deletion
        case .header, .hunk: palette.shell
        case .context, nil: palette.text
        }
    }

    private static func lineFill(_ kind: UnifiedDiffLine.Kind, _ palette: WorkspaceDiffPalette) -> NSColor {
        switch kind {
        case .addition: palette.additionFill
        case .deletion: palette.deletionFill
        case .hunk: palette.hunkLineFill
        case .header: palette.headerFill
        case .context: .clear
        }
    }

    private static func fill(_ rect: CGRect, _ color: NSColor) {
        guard color.alphaComponent > 0 else { return }
        color.setFill()
        rect.fill(using: .sourceOver)
    }

    private struct SymbolKey: Hashable {
        let name: String
        let size: CGFloat
        let weight: CGFloat
        let color: NSColor
    }

    private static var symbols: [SymbolKey: NSImage] = [:]

    private static func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSImage? {
        let key = SymbolKey(name: name, size: size, weight: weight.rawValue, color: color)
        if let image = symbols[key] { return image }
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
            .applying(.init(paletteColors: [color]))
        guard
            let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration)
        else { return nil }
        if symbols.count >= 64 { symbols.removeAll() }
        symbols[key] = image
        return image
    }
}

private extension NSBezierPath {
    func fill(with color: NSColor) {
        color.setFill()
        fill()
    }
}

// MARK: - Table

/// The diff's table. It never takes keyboard focus, so arrow keys stay with
/// the file list; its text views still select and copy.
final class WorkspaceDiffTableView: NSTableView {
    var widthDidChange: () -> Void = {}
    var liveResizeDidEnd: () -> Void = {}
    private var measuredWidth: CGFloat = 0

    override var acceptsFirstResponder: Bool { false }

    /// The width rows wrap to: the one column's, which fills the table.
    var rowWidth: CGFloat { tableColumns.first?.width ?? 0 }

    override func setFrameSize(_ newSize: NSSize) {
        let width = frame.width
        super.setFrameSize(newSize)
        if abs(newSize.width - width) >= 0.5 { needsLayout = true }
    }

    // A new width measures the rows again before AppKit lays them out, and
    // outside the table's delegate callbacks, which must not change it.
    override func layout() {
        if abs(rowWidth - measuredWidth) >= 0.5 {
            measuredWidth = rowWidth
            widthDidChange()
        }
        super.layout()
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        liveResizeDidEnd()
    }
}

/// The diff's rows in a native table. Each row's height comes from wrapping
/// its text at the table's width; heights are kept per row until the width or
/// the diff changes, and while a window resizes live only the visible rows
/// are measured again.
struct WorkspaceDiffTable: NSViewRepresentable {
    let layout: WorkspaceDiffLayout
    let loadingMore: Bool
    let reviewSection: String?
    let palette: WorkspaceDiffPalette
    let addComment: (UnifiedDiffLine) -> Void
    let loadMore: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        let table = WorkspaceDiffTableView()
        table.headerView = nil
        table.backgroundColor = .clear
        table.intercellSpacing = .zero
        table.style = .plain
        table.selectionHighlightStyle = .none
        table.allowsEmptySelection = true
        table.usesAutomaticRowHeights = false
        table.rowSizeStyle = .custom
        table.gridStyleMask = []
        table.focusRingType = .none
        let column = NSTableColumn(identifier: .init("diff"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.widthDidChange = { [weak coordinator = context.coordinator] in coordinator?.widthChanged() }
        table.liveResizeDidEnd = { [weak coordinator = context.coordinator] in coordinator?.liveResizeEnded() }
        scroll.documentView = table
        context.coordinator.table = table
        context.coordinator.reload()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(to: self)
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        private(set) var parent: WorkspaceDiffTable
        weak var table: WorkspaceDiffTableView?
        private(set) var items: [WorkspaceDiffItem] = []
        private var expandedFolds: Set<Int> = []
        private var geometries: [WorkspaceDiffItem.Key: WorkspaceDiffGeometry] = [:]

        init(parent: WorkspaceDiffTable) {
            self.parent = parent
        }

        private var rowContext: WorkspaceDiffRowContext {
            WorkspaceDiffRowContext(
                palette: parent.palette, reviewSection: parent.reviewSection, more: parent.layout.more,
                loadingMore: parent.loadingMore, note: parent.layout.note)
        }

        /// The width rows wrap to; nothing is measured before the table has one.
        private var width: CGFloat { table?.rowWidth ?? 0 }

        func update(to next: WorkspaceDiffTable) {
            let previous = parent
            parent = next
            if next.layout.revision != previous.layout.revision {
                // New rows: expanded folds and measured rows belong to the old ones.
                expandedFolds = []
                geometries = [:]
            }
            if next.reviewSection != previous.reviewSection { geometries = [:] }
            if next.layout.more != previous.layout.more || next.layout.note != previous.layout.note {
                geometries[.footer] = nil
            }
            if next.layout != previous.layout || next.reviewSection != previous.reviewSection {
                reload()
            } else if next.palette != previous.palette || next.loadingMore != previous.loadingMore {
                reconfigureVisibleRows()
            }
        }

        func reload() {
            items = WorkspaceDiffItem.items(parent.layout, expandedFolds: expandedFolds)
            table?.reloadData()
        }

        func toggleFold(_ id: Int) {
            if expandedFolds.contains(id) { expandedFolds.remove(id) } else { expandedFolds.insert(id) }
            reload()
        }

        func geometry(_ item: WorkspaceDiffItem, width: CGFloat) -> WorkspaceDiffGeometry {
            if let geometry = geometries[item.key], geometry.width == width { return geometry }
            let geometry = item.geometry(width: width, context: rowContext)
            geometries[item.key] = geometry
            return geometry
        }

        // MARK: Width

        func widthChanged() {
            guard let table, !items.isEmpty else { return }
            // While a window resizes live, only what is on screen wraps again;
            // the rest follows when the resize ends.
            let rows =
                table.inLiveResize ? table.rows(in: table.visibleRect) : NSRange(location: 0, length: items.count)
            noteHeights(of: IndexSet(integersIn: Range(rows) ?? 0..<0))
        }

        func liveResizeEnded() {
            noteHeights(of: IndexSet(integersIn: 0..<items.count))
        }

        /// Measures `rows` again and keeps the first visible row where it was.
        private func noteHeights(of rows: IndexSet) {
            guard let table, !rows.isEmpty else { return }
            let visible = table.visibleRect
            let anchor = table.row(at: CGPoint(x: 0, y: visible.minY))
            let offset = anchor >= 0 ? visible.minY - table.rect(ofRow: anchor).minY : 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                context.allowsImplicitAnimation = false
                table.noteHeightOfRows(withIndexesChanged: rows)
            }
            if anchor >= 0, let clip = table.enclosingScrollView?.contentView {
                clip.scroll(to: CGPoint(x: 0, y: max(0, table.rect(ofRow: anchor).minY + offset)))
                table.enclosingScrollView?.reflectScrolledClipView(clip)
            }
        }

        private func reconfigureVisibleRows() {
            guard let table else { return }
            let context = rowContext
            table.enumerateAvailableRowViews { rowView, row in
                guard row < self.items.count, let cell = rowView.view(atColumn: 0) as? WorkspaceDiffCell else { return }
                cell.configure(self.items[row], context: context)
            }
        }

        // MARK: Table

        func numberOfRows(in tableView: NSTableView) -> Int { items.count }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard row < items.count, width >= 40 else { return WorkspaceDiffStyle.row }
            return geometry(items[row], width: width).height
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row < items.count else { return nil }
            let item = items[row]
            let cell =
                tableView.makeView(withIdentifier: item.reuseIdentifier, owner: nil) as? WorkspaceDiffCell
                ?? {
                    let cell = WorkspaceDiffCell()
                    cell.identifier = item.reuseIdentifier
                    return cell
                }()
            cell.resolveGeometry = { [weak self] item, width in
                self?.geometry(item, width: width)
                    ?? item.geometry(width: width, context: WorkspaceDiffRowContext(palette: .current))
            }
            cell.addComment = { [weak self] line in self?.parent.addComment(line) }
            cell.toggleFold = { [weak self] id in self?.toggleFold(id) }
            cell.loadMore = { [weak self] in self?.parent.loadMore() }
            cell.configure(item, context: rowContext)
            return cell
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
    }
}
