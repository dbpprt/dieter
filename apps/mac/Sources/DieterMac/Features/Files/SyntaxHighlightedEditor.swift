import AppKit
import SwiftUI

struct SyntaxHighlightedEditor: NSViewRepresentable {
    let session: FileEditorSession
    let documentKey: String
    let text: String
    let filename: String

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> SyntaxEditorContainer {
        let container = SyntaxEditorContainer()
        let textView = container.textView
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.importsGraphics = false
        textView.allowsUndo = true
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
        session.attach(textView, documentKey: documentKey, initialText: text)
        context.coordinator.highlight(force: true)
        return container
    }

    func updateNSView(_ container: SyntaxEditorContainer, context: Context) {
        context.coordinator.parent = self
        guard context.coordinator.textView != nil else { return }
        if session.documentKey != documentKey {
            context.coordinator.isApplyingUpdate = true
            session.prepare(documentKey: documentKey, text: text)
            context.coordinator.isApplyingUpdate = false
            context.coordinator.highlight(force: true)
        } else {
            context.coordinator.highlight(force: false)
        }
        container.needsLayout = true
    }

    static func dismantleNSView(_ container: SyntaxEditorContainer, coordinator: Coordinator) {
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

        init(parent: SyntaxHighlightedEditor) { self.parent = parent }

        func textView(
            _ textView: NSTextView,
            shouldChangeTextIn affectedCharRange: NSRange,
            replacementString: String?
        ) -> Bool {
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
            container?.needsLayout = true
        }

        func highlight(force: Bool) {
            guard let textView, let storage = textView.textStorage else { return }
            let language = ProjectFileLanguage.detect(filename: parent.filename)
            guard force || highlightedLanguage != language else { return }
            highlightedLanguage = language
            textView.typingAttributes = FileSyntaxHighlighter.baseAttributes
            guard storage.length <= FileSyntaxHighlighter.backgroundFullHighlightLimit else { return }
            scheduleFullHighlight(language: language, delayNanoseconds: 0)
        }

        private func highlightEditedRange(_ editedRange: NSRange?) {
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
            guard let storage = textView?.textStorage else { return }
            fullHighlightTask?.cancel()
            let source = storage.string
            let revision = parent.session.revision
            fullHighlightTask = Task { @MainActor [weak self] in
                if delayNanoseconds > 0 {
                    try? await Task.sleep(nanoseconds: delayNanoseconds)
                }
                guard !Task.isCancelled else { return }
                let plan = await Task.detached(priority: .userInitiated) {
                    FileSyntaxHighlightPlanner.build(source: source, language: language)
                }.value
                guard !Task.isCancelled,
                    let self,
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

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
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
        let viewport = scrollView.contentSize
        guard viewport.width > 0, let textContainer = textView.textContainer else { return }
        textContainer.containerSize = NSSize(width: viewport.width, height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = viewport
        if textView.frame.width != viewport.width {
            textView.frame.size.width = viewport.width
        }
    }
}

@MainActor
final class SyntaxEditorTextView: NSTextView {
    override var acceptsFirstResponder: Bool { true }

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
