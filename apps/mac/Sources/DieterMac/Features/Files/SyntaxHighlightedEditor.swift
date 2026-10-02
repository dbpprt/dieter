import AppKit
import DieterAPI
import DieterShared
import SwiftUI

struct SyntaxHighlightedEditor: NSViewRepresentable {
    let session: FileEditorSession
    let documentKey: String
    let text: String
    let filename: String
    var active = true
    var editable = true
    var requestedLine: Int?

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> SyntaxEditorContainer {
        let container = SyntaxEditorContainer()
        let textView = container.textView
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.isEditable = editable
        textView.isSelectable = true
        textView.importsGraphics = false
        textView.allowsUndo = editable
        textView.drawsBackground = false
        textView.insertionPointColor = .textColor
        textView.textContainerInset = NSSize(width: 14, height: 12)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.font = FileSyntaxHighlighter.baseFont
        textView.textColor = FileSyntaxHighlighter.foreground
        context.coordinator.textView = textView
        context.coordinator.container = container
        context.coordinator.setActive(active)
        session.attach(textView, documentKey: documentKey, initialText: text)
        context.coordinator.highlight(force: true)
        context.coordinator.revealRequestedLine()
        return container
    }

    func updateNSView(_ container: SyntaxEditorContainer, context: Context) {
        context.coordinator.parent = self
        guard context.coordinator.textView != nil else { return }
        context.coordinator.setActive(active)
        container.textView.isEditable = editable
        container.textView.allowsUndo = editable
        if session.documentKey != documentKey {
            context.coordinator.isApplyingUpdate = true
            session.prepare(documentKey: documentKey, text: text)
            context.coordinator.isApplyingUpdate = false
            context.coordinator.highlight(force: true)
        } else {
            context.coordinator.highlight(force: false)
        }
        context.coordinator.revealRequestedLine()
        if active { container.needsLayout = true }
    }

    /// Link line numbers are one-based; out-of-range links reveal the nearest
    /// available line, as the shared core measures it in UTF-16 units.
    static func range(ofLine line: Int, in text: String) -> NSRange {
        let packed = SharedRules.shared.fileLineRange(text: text, line: Int32(clamping: line))
        return NSRange(location: Int(packed >> 32), length: Int(packed & 0xFFFF_FFFF))
    }

    static func dismantleNSView(_ container: SyntaxEditorContainer, coordinator: Coordinator) {
        coordinator.setActive(false)
        if container.window?.firstResponder === container.textView {
            container.window?.makeFirstResponder(nil)
        }
        coordinator.parent.session.detach(container.textView)
        container.textView.delegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SyntaxHighlightedEditor
        weak var textView: NSTextView?
        weak var container: SyntaxEditorContainer?
        var isApplyingUpdate = false
        private var highlightedFilename: String?
        private var pendingEditedRange: NSRange?
        private var pendingLineDelta = 0
        private var fullHighlightTask: Task<Void, Never>?
        private var needsFullHighlight = true
        private var isActive = true
        private var revealedLine: String?

        init(parent: SyntaxHighlightedEditor) { self.parent = parent }

        func revealRequestedLine() {
            guard isActive, let line = parent.requestedLine, let textView else { return }
            let key = "\(parent.documentKey):\(line)"
            guard revealedLine != key else { return }
            revealedLine = key
            let range = SyntaxHighlightedEditor.range(ofLine: line, in: textView.string)
            container?.reveal(range: range)
        }

        func setActive(_ active: Bool) {
            let becameActive = active && !isActive
            isActive = active
            container?.setActive(active)
            if !active {
                fullHighlightTask?.cancel()
                fullHighlightTask = nil
                needsFullHighlight = true
                if textView?.window?.firstResponder === textView {
                    textView?.window?.makeFirstResponder(nil)
                }
            } else if becameActive {
                highlight(force: true)
            }
        }

        func textView(
            _ textView: NSTextView,
            shouldChangeTextIn affectedCharRange: NSRange,
            replacementString: String?
        ) -> Bool {
            guard parent.editable else { return false }
            let current = textView.string as NSString
            let removed = current.substring(with: affectedCharRange)
            let replacement = replacementString ?? ""
            pendingLineDelta = replacement.utf8.filter { $0 == 0x0A }.count - removed.utf8.filter { $0 == 0x0A }.count
            pendingEditedRange = NSRange(
                location: affectedCharRange.location,
                length: (replacement as NSString).length
            )
            return true
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingUpdate, textView != nil else { return }
            parent.session.didEdit(lineDelta: pendingLineDelta)
            highlightEditedRange(pendingEditedRange)
            pendingEditedRange = nil
            pendingLineDelta = 0
            if isActive { container?.needsLayout = true }
        }

        func highlight(force: Bool) {
            guard isActive else { needsFullHighlight = true; return }
            guard let textView, textView.textStorage != nil else { return }
            guard force || needsFullHighlight || highlightedFilename != parent.filename else { return }
            highlightedFilename = parent.filename
            needsFullHighlight = false
            textView.typingAttributes = FileSyntaxHighlighter.baseAttributes
            scheduleFullHighlight(delayNanoseconds: 0)
        }

        private func highlightEditedRange(_ editedRange: NSRange?) {
            guard isActive else { needsFullHighlight = true; return }
            guard let textView, let storage = textView.textStorage, let editedRange else { return }
            let source = storage.string as NSString
            let safeLocation = min(editedRange.location, source.length)
            let safeLength = min(editedRange.length, source.length - safeLocation)
            let lineRange = source.lineRange(for: NSRange(location: safeLocation, length: safeLength))
            FileSyntaxHighlighter.apply(
                FileSyntaxHighlightPlan.lex(source.substring(with: lineRange), path: parent.filename, in: lineRange),
                to: storage
            )
            scheduleFullHighlight(delayNanoseconds: 550_000_000)
        }

        private func scheduleFullHighlight(delayNanoseconds: UInt64) {
            guard isActive else { return }
            guard let storage = textView?.textStorage else { return }
            fullHighlightTask?.cancel()
            // The core lexes at most the first 200,000 characters; only those cross over.
            let source = storage.string as NSString
            let range = NSRange(location: 0, length: min(source.length, FileSyntaxHighlightPlan.limit))
            let text = source.substring(with: range)
            let filename = parent.filename
            let revision = parent.session.revision
            let documentKey = parent.documentKey
            fullHighlightTask = Task { @MainActor [weak self] in
                if delayNanoseconds > 0 {
                    try? await Task.sleep(nanoseconds: delayNanoseconds)
                }
                guard !Task.isCancelled, self?.isActive == true else { return }
                let plan = await Task.detached(priority: .userInitiated) {
                    FileSyntaxHighlightPlan.lex(text, path: filename, in: range)
                }.value
                guard !Task.isCancelled,
                    let self,
                    self.isActive,
                    self.parent.documentKey == documentKey,
                    self.parent.session.documentKey == documentKey,
                    self.parent.session.revision == revision,
                    let textView = self.textView,
                    let storage = textView.textStorage
                else { return }
                let selectedRanges = textView.selectedRanges
                FileSyntaxHighlighter.apply(plan, to: storage)
                textView.selectedRanges = selectedRanges
            }
        }
    }
}

@MainActor
final class SyntaxEditorContainer: NSView {
    let scrollView = NSScrollView()
    let textView = SyntaxEditorTextView()
    private(set) var isActive = true
    private var pendingReveal: NSRange?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        // This container owns the wrapping width. NSTextView's automatic
        // tracking subtracts its inset, so also assigning the viewport width
        // during layout makes the two writers repeatedly invalidate TextKit.
        // Retained editors are particularly sensitive when becoming visible.
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: frameRect.width > 0 ? frameRect.width : 600,
            height: CGFloat.greatestFiniteMagnitude)
        textView.layoutManager?.allowsNonContiguousLayout = true
        textView.minSize = scrollView.contentSize
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scrollView.documentView = textView
    }

    required init?(coder: NSCoder) { nil }

    func reveal(range: NSRange) {
        pendingReveal = range
        needsLayout = true
    }

    func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        textView.isPresentationActive = active
        textView.isVerticallyResizable = active
        textView.autoresizingMask = active ? [.width] : []
        textView.layoutManager?.backgroundLayoutEnabled = active
        if active { needsLayout = true }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isActive, bounds.contains(point) else { return nil }
        let pointInScrollView = scrollView.convert(point, from: self)
        if let scroller = scrollView.verticalScroller,
            !scroller.isHidden,
            scroller.frame.contains(pointInScrollView)
        {
            return scroller
        }
        return textView
    }

    override func layout() {
        super.layout()
        guard isActive else { return }
        let viewport = scrollView.contentSize
        let wrappingWidth = viewport.width - 2 * textView.textContainerInset.width
        guard wrappingWidth.isFinite, wrappingWidth > 0, let textContainer = textView.textContainer else { return }
        let containerSize = NSSize(width: wrappingWidth, height: CGFloat.greatestFiniteMagnitude)
        if textContainer.containerSize != containerSize { textContainer.containerSize = containerSize }
        if textView.minSize != viewport { textView.minSize = viewport }
        if textView.frame.width != viewport.width {
            textView.frame.size.width = viewport.width
        }
        if let range = pendingReveal, viewport.height > 0 {
            pendingReveal = nil
            textView.setSelectedRange(range)
            textView.scrollRangeToVisible(range)
        }
    }
}

@MainActor
final class SyntaxEditorTextView: NSTextView {
    var isPresentationActive = true
    override var acceptsFirstResponder: Bool { isPresentationActive }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }
}

/// The shared core's highlight spans for one range of a document.
struct FileSyntaxHighlightPlan: Sendable {
    /// The most characters the core lexes; text beyond stays plain.
    static let limit = 200_000

    let range: NSRange
    /// Packed (start, length, kind) triples in document UTF-16 offsets.
    let spans: [Int32]

    /// Lexes [text], which starts at [range]'s location in the document.
    static func lex(_ text: String, path: String, in range: NSRange) -> FileSyntaxHighlightPlan {
        MacPerformanceSignposts.measure("Syntax highlight plan", log: MacPerformanceSignposts.editor) {
            let highlights = ClientSyntaxHighlights(
                rules: SharedRules.shared.syntaxHighlights(text: text, path: path, offset: Int32(range.location)))
            return FileSyntaxHighlightPlan(range: range, spans: highlights.spans)
        }
    }
}

@MainActor
private enum FileSyntaxHighlighter {
    static let baseFont = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
    static let boldFont = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .semibold)
    static let foreground = NSColor.textColor

    static var baseAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        paragraph.tabStops = []
        paragraph.defaultTabInterval = 28
        return [.font: baseFont, .foregroundColor: foreground, .paragraphStyle: paragraph]
    }

    static func apply(_ plan: FileSyntaxHighlightPlan, to storage: NSTextStorage) {
        let fullRange = NSRange(location: 0, length: storage.length)
        let range = NSIntersectionRange(plan.range, fullRange)
        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: range)
        guard range.length > 0 else { storage.endEditing(); return }
        var index = 0
        while index + 2 < plan.spans.count {
            let span = NSRange(location: Int(plan.spans[index]), length: Int(plan.spans[index + 1]))
            let kind = ClientSyntaxKind(rawValue: Int(plan.spans[index + 2])) ?? .unspecified
            index += 3
            let spanRange = NSIntersectionRange(span, range)
            guard spanRange.length > 0, let color = color(for: kind) else { continue }
            storage.addAttribute(.foregroundColor, value: color, range: spanRange)
            storage.addAttribute(.font, value: bold(kind) ? boldFont : baseFont, range: spanRange)
        }
        storage.endEditing()
    }

    private static func bold(_ kind: ClientSyntaxKind) -> Bool { kind == .keyword || kind == .heading }

    private static func color(for kind: ClientSyntaxKind) -> NSColor? {
        switch kind {
        case .keyword, .heading, .tag: .systemPurple
        case .string: .systemGreen
        case .comment: .secondaryLabelColor
        case .number, .constant, .annotation, .emphasis: .systemOrange
        case .function, .link: .systemBlue
        case .type: .systemTeal
        case .property, .attribute, .variable: .systemPink
        default: nil
        }
    }
}
