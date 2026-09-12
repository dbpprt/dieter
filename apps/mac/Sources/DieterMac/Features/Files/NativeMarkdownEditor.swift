import AppKit
import MarkdownEngine
import MarkdownEngineCodeBlocks
import SwiftUI

/// Markdown stays the source of truth: the native engine styles it in place,
/// including rendered Mermaid/Vega fences, without an HTML-to-Markdown conversion.
struct NativeMarkdownEditor: View {
    let session: FileEditorSession
    let documentKey: String
    var active = true
    var scrollCoordinator: MarkdownScrollCoordinator?
    @State private var controls = NativeMarkdownControls()

    var body: some View {
        // The live buffer itself is not observable; track its revision so
        // source edits and Undo refresh this retained native editor too.
        let _ = session.revision
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                formatButton("Bold", symbol: "bold", command: .bold)
                formatButton("Italic", symbol: "italic", command: .italic)
                formatButton("Strikethrough", symbol: "strikethrough", command: .strikethrough)
                Menu {
                    ForEach(1...6, id: \.self) { level in
                        Button("Heading \(level)") { controls.send(.heading, level: level) }
                    }
                } label: {
                    Image(systemName: "textformat.size")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .quickHelp("Heading")
                Divider().frame(height: 16).padding(.horizontal, 4)
                formatButton("Bulleted list", symbol: "list.bullet", command: .bullet)
                formatButton("Numbered list", symbol: "list.number", command: .numbered)
                formatButton("Quote", symbol: "text.quote", command: .quote)
                formatButton("Code block", symbol: "curlybraces", command: .code)
                Spacer(minLength: 0)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .padding(.horizontal, 10)
            .frame(height: 34)
            .overlay(alignment: .bottom) { Divider() }

            NativeMarkdownTextSurface(
                session: session, documentKey: documentKey, active: active, controls: controls,
                scrollCoordinator: scrollCoordinator
            )
            .accessibilityIdentifier("files.markdown.rich-editor")
            .smokeTarget("files.markdown.rich-editor")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func formatButton(_ label: String, symbol: String, command: NativeMarkdownControls.Command) -> some View {
        Button {
            controls.send(command)
        } label: {
            Image(systemName: symbol).frame(width: 25, height: 26)
        }
        .quickHelp(label)
        .accessibilityLabel(label)
        .accessibilityIdentifier("files.markdown.format.\(command.rawValue)")
        .smokeTarget("files.markdown.format.\(command.rawValue)")
    }
}

/// Own the engine's host so focus and undo policy apply to this editor only.
/// Retaining the host keeps the library's selection and scroll memory intact.
struct NativeMarkdownTextSurface: NSViewRepresentable {
    let session: FileEditorSession
    let documentKey: String
    let active: Bool
    let controls: NativeMarkdownControls
    var scrollCoordinator: MarkdownScrollCoordinator?
    @Environment(\.conversationLinkHandler) private var linkHandler

    func makeNSView(context: Context) -> NativeMarkdownTextContainer { NativeMarkdownTextContainer() }

    static func dismantleNSView(_ view: NativeMarkdownTextContainer, coordinator: ()) {
        view.dispose()
    }

    func updateNSView(_ view: NativeMarkdownTextContainer, context: Context) {
        let _ = session.revision
        guard active else {
            controls.setActive(false)
            view.suspend()
            return
        }
        let source = session.documentKey == documentKey ? session.currentText() : ""
        controls.synchronizeSource(source)
        controls.setActive(true)
        let wrapper = NativeTextViewWrapper(
            text: Binding(
                // Capture this active update. Observing the shared buffer from
                // the retained host would keep the hidden editor restyling.
                get: { source },
                set: { _ = session.applyReplacement($0, documentKey: documentKey) }),
            configuration: controls.configuration,
            fontName: NSFont.systemFont(ofSize: 14).fontName,
            fontSize: 14, documentId: documentKey, isEditable: active,
            onURLClick: { url in linkHandler?(url) ?? false },
            onBuildContextMenu: { menu, range in
                controls.contextMenu(menu, source: session.currentText(), selection: range)
            })
        var suspendedWrapper = wrapper
        suspendedWrapper.isEditable = false
        view.update(
            content: AnyView(wrapper), suspendedContent: AnyView(suspendedWrapper),
            controls: controls, active: active, generation: session.sourceEditGeneration,
            scrollCoordinator: scrollCoordinator)
    }
}

@MainActor
final class NativeMarkdownTextContainer: NSView {
    private let host = NSHostingView(rootView: AnyView(EmptyView()))
    private var controls: NativeMarkdownControls?
    private var generation: Int?
    private var active = false
    private var suspendedContent: AnyView?
    private var hostConstraints: [NSLayoutConstraint] = []
    private weak var scrollCoordinator: MarkdownScrollCoordinator?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        host.sizingOptions = []
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        hostConstraints = [
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.topAnchor.constraint(equalTo: topAnchor), host.bottomAnchor.constraint(equalTo: bottomAnchor),
        ]
        NSLayoutConstraint.activate(hostConstraints)
    }

    required init?(coder: NSCoder) { nil }

    func dispose() {
        controls?.detach()
        controls = nil
        scrollCoordinator = nil
        suspendedContent = nil
        host.rootView = AnyView(EmptyView())
    }

    func suspend() {
        guard active else { return }
        active = false
        // SwiftUI remains the authority for editability. Freeze the same
        // wrapper once, otherwise an internal update can re-enable the editor.
        if let suspendedContent { host.rootView = suspendedContent }
        if let editor = textView(in: host) { controls?.attach(editor, active: false) }
        // Retain the editor and undo stack at their last size. A zero-opacity
        // view otherwise still receives width changes and regenerates diagrams.
        host.isHidden = true
        NSLayoutConstraint.deactivate(hostConstraints)
        host.translatesAutoresizingMaskIntoConstraints = true
        host.autoresizingMask = []
    }

    func update(
        content: AnyView, suspendedContent: AnyView, controls: NativeMarkdownControls, active: Bool, generation: Int,
        scrollCoordinator: MarkdownScrollCoordinator?
    ) {
        self.controls = controls
        self.scrollCoordinator = scrollCoordinator
        self.active = active
        self.suspendedContent = suspendedContent
        host.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate(hostConstraints)
        host.isHidden = false
        if let previous = self.generation, previous != generation, let editor = textView(in: host) {
            // External source changes bypass the engine's range-based undo
            // registration. Old native actions would target unrelated text.
            editor.breakUndoCoalescing()
            editor.undoManager?.removeAllActions()
        }
        self.generation = generation
        reconcileEditor()
        host.rootView = content
        needsLayout = true
        DispatchQueue.main.async { [weak self] in self?.reconcileEditor() }
    }

    override func layout() {
        super.layout()
        reconcileEditor()
    }

    private func reconcileEditor() {
        guard active else { return }
        guard let editor = textView(in: host) else { return }
        controls?.attach(editor, active: active)
        if let scroll = editor.enclosingScrollView { scrollCoordinator?.attachRich(scroll) }
    }

    private func textView(in view: NSView) -> NSTextView? {
        if let editor = view as? NSTextView { return editor }
        return view.subviews.lazy.compactMap { self.textView(in: $0) }.first
    }
}

@MainActor
final class NativeMarkdownControls {
    enum Command: String { case bold, italic, strikethrough, heading, bullet, numbered, quote, code }
    private let identity = UUID().uuidString
    private lazy var highlighter = DiagramFenceHighlighter()
    private lazy var diagrams = NativeMarkdownDiagramRenderer()
    private(set) weak var textView: NSTextView?
    private var active = true

    func synchronizeSource(_ source: String) {
        diagrams.synchronizeSource(source)
    }

    func setActive(_ active: Bool) {
        self.active = active
        diagrams.setActive(active)
    }

    func detach() {
        active = false
        textView = nil
        diagrams.dispose()
    }

    func attach(_ editor: NSTextView, active: Bool) {
        textView = editor
        self.active = active
        editor.isEditable = active
        if active { diagrams.updateAppearance(editor.effectiveAppearance) }
        if !active, editor.window?.firstResponder === editor {
            editor.window?.makeFirstResponder(nil)
        }
    }

    private func notification(_ command: Command) -> Notification.Name {
        .init("Dieter.Markdown.\(identity).\(command.rawValue)")
    }

    var configuration: MarkdownEditorConfiguration {
        var configuration = MarkdownEditorConfiguration.default
        configuration.textInsets = TextInsets(horizontal: 18, vertical: 16)
        configuration.extensions = [StrikethroughExtension()]
        configuration.services = MarkdownEditorServices(
            syntaxHighlighter: highlighter,
            renderedCodeBlocks: diagrams,
            bus: MarkdownEditorBus(
                applyBoldRequest: notification(.bold), applyItalicRequest: notification(.italic),
                applyHeadingRequest: notification(.heading), applyStrikethroughRequest: notification(.strikethrough),
                applyBlockquoteRequest: notification(.quote), applyUnorderedListRequest: notification(.bullet),
                applyOrderedListRequest: notification(.numbered), applyCodeBlockRequest: notification(.code)))
        return configuration
    }

    func send(_ command: Command, level: Int? = nil) {
        guard active else { return }
        textView?.breakUndoCoalescing()
        defer { textView?.breakUndoCoalescing() }
        if let textView {
            textView.window?.makeFirstResponder(textView)
            if command == .code, textView.selectedRange().length > 0 {
                wrapSelectionInCodeBlock(textView)
                return
            }
        }
        // Each editor gets its own command bus; formatting cannot affect a
        // hidden document or another workspace window.
        NotificationCenter.default.post(
            name: notification(command), object: nil, userInfo: level.map { ["level": $0] })
    }

    func contextMenu(_ menu: NSMenu, source: String, selection: NSRange) -> NSMenu {
        let selected = Self.selectedMarkdown(source: source, displaySelection: selection)
        let html = MarkdownHTMLRenderer.html(from: selected, extensions: [StrikethroughExtension()])
        guard let payload = MarkdownClipboardPayload(body: ["markdown": selected, "text": selected, "html": html])
        else { return menu }
        menu.insertItem(.separator(), at: 0)
        for (title, rich) in [("Copy as Markdown", false), ("Copy as Rich Text", true)] {
            menu.insertItem(
                MarkdownCopyMenuItem(title: title) {
                    payload.write(to: .general, richText: rich)
                }, at: 0)
        }
        return menu
    }

    static func selectedMarkdown(source: String, displaySelection: NSRange) -> String {
        guard displaySelection.location != NSNotFound, displaySelection.length > 0 else { return source }
        let display = WikiLinkService.makeDisplayState(from: source)
        guard NSMaxRange(displaySelection) <= (display.display as NSString).length else { return source }
        let links = display.metadata.sorted { $0.key.location < $1.key.location }
        func storageOffset(_ offset: Int, upperBound: Bool) -> Int {
            var difference = 0
            for (range, metadata) in links {
                let end = range.location + range.length
                let hiddenLength = metadata.storageRange.length - range.length
                if offset >= end { difference += hiddenLength; continue }
                if offset >= range.location {
                    // Hidden |id metadata sits before the closing brackets.
                    // A selection of just the visible name excludes it.
                    let closing = end - 2
                    if offset > closing || (!upperBound && offset == closing) { difference += hiddenLength }
                }
                break
            }
            return offset + difference
        }
        let start = storageOffset(displaySelection.location, upperBound: false)
        let end = storageOffset(NSMaxRange(displaySelection), upperBound: true)
        let text = source as NSString
        guard start >= 0, end >= start, end <= text.length else { return source }
        return text.substring(with: NSRange(location: start, length: end - start))
    }

    private func wrapSelectionInCodeBlock(_ editor: NSTextView) {
        guard let storage = editor.textStorage else { return }
        let range = editor.selectedRange()
        guard NSMaxRange(range) <= storage.length else { return }
        let selected = storage.attributedSubstring(from: range)
        var run = 0
        var longest = 0
        for character in selected.string {
            run = character == "`" ? run + 1 : 0
            longest = max(longest, run)
        }
        let fence = String(repeating: "`", count: max(3, longest + 1))
        let line = (editor.string as NSString).lineRange(for: range)
        let opening = (range.location > line.location ? "\n" : "") + fence + "\n"
        let closing = (selected.string.hasSuffix("\n") ? "" : "\n") + fence + "\n"
        let replacement = NSMutableAttributedString(string: opening)
        replacement.append(selected)
        replacement.append(NSAttributedString(string: closing))
        editor.breakUndoCoalescing()
        defer { editor.breakUndoCoalescing() }
        editor.insertText(replacement, replacementRange: range)
        editor.setSelectedRange(
            NSRange(location: range.location + (opening as NSString).length, length: selected.length))
    }
}

/// Vega and Vega-Lite use JSON highlighting when a diagram is opened for
/// editing. Mermaid source stays literal; diagrams use the bundled renderer.
final class DiagramFenceHighlighter: SyntaxHighlighter, @unchecked Sendable {
    private let base = HighlighterSwiftBridge()
    func codeFont(size: CGFloat) -> NSFont { base.codeFont(size: size) }
    func backgroundColor() -> NSColor { base.backgroundColor() }
    var appearanceDidChangeNotification: Notification.Name? { base.appearanceDidChangeNotification }
    func highlight(code: String, language: String?) -> NSAttributedString? {
        let language = language?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if language == "mermaid" { return nil }
        let mapped = ["vega", "vega-lite", "vegalite"].contains(language ?? "") ? "json" : language
        // Large inline datasets remain editable without invoking a synchronous
        // JavaScript syntax highlighter for hundreds of kilobytes per keystroke.
        guard code.utf8.count <= 100_000 else { return nil }
        return base.highlight(code: code, language: mapped)
    }
}

@MainActor
private final class MarkdownCopyMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func invoke() { handler() }
}
