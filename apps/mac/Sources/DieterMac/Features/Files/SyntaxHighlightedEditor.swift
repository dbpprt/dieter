import AppKit
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
    /// available line. NSString keeps the selection in NSTextView's UTF-16 units.
    static func range(ofLine line: Int, in text: String) -> NSRange {
        let source = text as NSString
        var location = 0
        var currentLine = 1
        while currentLine < max(1, line), location < source.length {
            let next = NSMaxRange(source.lineRange(for: NSRange(location: location, length: 0)))
            guard next > location else { break }
            if next == source.length {
                let finalCharacter = source.character(at: source.length - 1)
                if finalCharacter != 0x0A && finalCharacter != 0x0D { break }
            }
            location = next
            currentLine += 1
        }
        var start = 0, end = 0, contentsEnd = 0
        source.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
        return NSRange(location: start, length: contentsEnd - start)
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
        private var highlightedLanguage: ProjectFileLanguage?
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
            guard let textView, let storage = textView.textStorage else { return }
            let language = ProjectFileLanguage.detect(filename: parent.filename)
            guard force || needsFullHighlight || highlightedLanguage != language else { return }
            highlightedLanguage = language
            needsFullHighlight = false
            textView.typingAttributes = FileSyntaxHighlighter.baseAttributes
            guard storage.length <= FileSyntaxHighlighter.backgroundFullHighlightLimit else { return }
            scheduleFullHighlight(language: language, delayNanoseconds: 0)
        }

        private func highlightEditedRange(_ editedRange: NSRange?) {
            guard isActive else { needsFullHighlight = true; return }
            guard let textView, let storage = textView.textStorage, let editedRange else { return }
            let source = storage.string as NSString
            let safeLocation = min(editedRange.location, source.length)
            let safeLength = min(editedRange.length, source.length - safeLocation)
            let lineRange = source.lineRange(for: NSRange(location: safeLocation, length: safeLength))
            let language = ProjectFileLanguage.detect(filename: parent.filename)
            FileSyntaxHighlighter.apply(
                FileSyntaxHighlightPlanner.build(source: storage.string, language: language, requestedRange: lineRange),
                to: storage
            )
            guard storage.length <= FileSyntaxHighlighter.backgroundFullHighlightLimit else { return }
            scheduleFullHighlight(language: language, delayNanoseconds: 550_000_000)
        }

        private func scheduleFullHighlight(language: ProjectFileLanguage, delayNanoseconds: UInt64) {
            guard isActive else { return }
            guard let storage = textView?.textStorage else { return }
            fullHighlightTask?.cancel()
            let source = storage.string
            let revision = parent.session.revision
            let documentKey = parent.documentKey
            fullHighlightTask = Task { @MainActor [weak self] in
                if delayNanoseconds > 0 {
                    try? await Task.sleep(nanoseconds: delayNanoseconds)
                }
                guard !Task.isCancelled, self?.isActive == true else { return }
                let plan = await Task.detached(priority: .userInitiated) {
                    FileSyntaxHighlightPlanner.build(source: source, language: language)
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
        textView.textContainer?.widthTracksTextView = true
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
        textView.textContainer?.widthTracksTextView = active
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
        guard viewport.width > 0, let textContainer = textView.textContainer else { return }
        textContainer.containerSize = NSSize(width: viewport.width, height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = viewport
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

@MainActor
private enum FileSyntaxHighlighter {
    static let backgroundFullHighlightLimit = 180_000
    static let baseFont = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
    static let boldFont = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .semibold)
    static let foreground = NSColor.textColor
    static let keyword = NSColor.systemPurple
    static let string = NSColor.systemGreen
    static let comment = NSColor.secondaryLabelColor
    static let number = NSColor.systemOrange
    static let function = NSColor.systemBlue
    static let type = NSColor.systemTeal
    static let property = NSColor.systemPink

    static var baseAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        paragraph.tabStops = []
        paragraph.defaultTabInterval = 28
        return [.font: baseFont, .foregroundColor: foreground, .paragraphStyle: paragraph]
    }

    static func apply(_ plan: FileSyntaxHighlightPlan, to storage: NSTextStorage) {
        let fullRange = NSRange(location: 0, length: storage.length)
        let range = NSIntersectionRange(NSRange(location: plan.location, length: plan.length), fullRange)
        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: range)
        guard range.length > 0 else { storage.endEditing(); return }
        for run in plan.runs {
            let runRange = NSIntersectionRange(NSRange(location: run.location, length: run.length), fullRange)
            guard runRange.length > 0 else { continue }
            storage.addAttribute(.foregroundColor, value: color(for: run.style), range: runRange)
            if run.style == .keywordBold {
                storage.addAttribute(.font, value: boldFont, range: runRange)
            }
        }
        storage.endEditing()
    }

    private static func color(for style: FileSyntaxHighlightStyle) -> NSColor {
        switch style {
        case .number: number
        case .type: type
        case .function: function
        case .keyword, .keywordBold: keyword
        case .property: property
        case .string: string
        case .comment: comment
        }
    }
}
