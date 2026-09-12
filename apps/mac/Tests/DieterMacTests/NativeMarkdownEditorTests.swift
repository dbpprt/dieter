import AppKit
import MarkdownEngine
import SwiftUI
import Testing
import WebKit
@testable import DieterMac

@MainActor
struct NativeMarkdownEditorTests {
    @Test func markdownFilesOpenInRichEditAndKeepTheDraftAcrossModes() async throws {
        let original = "# A document\n\nEditable prose."
        let session = FileEditorSession()
        session.prepare(documentKey: "default-edit", text: original)
        let host = NSHostingView(
            rootView: MarkdownFileEditor(
                session: session, documentKey: "default-edit", text: original, filename: "document.md"))
        host.sizingOptions = []
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 1000, height: 650),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setContentSize(.init(width: 1000, height: 650))
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await settle { allTextViews(in: host).contains { $0.textLayoutManager != nil && $0.isEditable } }
        let rich = try #require(allTextViews(in: host).first { $0.textLayoutManager != nil && $0.isEditable })
        #expect(allTextViews(in: host).count == 1)
        #expect(!containsWebView(in: host))
        #expect(session.currentText() == original && !session.isDirty)
        try selectMode(.source, in: host)
        try await settle("Source mode should reveal Source and suspend Rich") {
            !rich.isEditable && allTextViews(in: host).contains { $0 !== rich && $0.string == original }
        }
        let source = try #require(allTextViews(in: host).first { $0 !== rich && $0.string == original })
        window.makeFirstResponder(source)
        source.insertText(" Updated.", replacementRange: .init(location: (source.string as NSString).length, length: 0))
        try await settle { session.currentText() == original + " Updated." }
        // Source edits must not reparse the retained, invisible rich editor.
        try await Task.sleep(for: .milliseconds(100))
        #expect(rich.string == original)
        #expect(!containsWebView(in: host))
        window.setContentSize(.init(width: 800, height: 650))
        #expect(MarkdownFileEditorMode.allCases == [.edit, .source])
        #expect(modePicker(in: host)?.segmentCount == 2)
        try selectMode(.edit, in: host)
        try await settle { rich.isEditable && rich.string == original + " Updated." }
        try selectMode(.source, in: host)
        try await settle("Source mode should retain the original native editor and dirty text") {
            source.isEditable && source.string == original + " Updated." && !rich.isEditable
        }
        #expect(allTextViews(in: host).contains { $0 === source })
        #expect(source.undoManager?.canUndo == true)
        #expect(!containsWebView(in: host))
        try selectMode(.edit, in: host)
        try await settle("Edit mode should resume the same rich buffer with source changes") {
            rich.isEditable && rich.string == original + " Updated."
        }
        #expect(!containsWebView(in: host))
        #expect(allTextViews(in: host).contains { $0 === rich })
        #expect(session.isDirty)
    }

    @Test func nativeFormattingPreservesDiagramFencesAndUndo() async throws {
        let source =
            "# Heading\n\nA **bold** word.\n\n```mermaid\ngraph LR\n A-->B\n```\n\n```vega-lite\n{\"data\":{\"values\":[{\"x\":3}]},\"mark\":\"point\"}\n```\n"
        let session = FileEditorSession()
        session.prepare(documentKey: "native-test", text: source)
        let controls = NativeMarkdownControls()
        let wrapper = NativeMarkdownTextSurface(
            session: session, documentKey: "native-test", active: true, controls: controls)
        let host = NSHostingView(rootView: wrapper)
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 750, height: 650),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setContentSize(.init(width: 750, height: 650))
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let editor = try #require(textView(in: host))
        #expect(editor.textLayoutManager != nil)
        #expect(session.currentText() == source)
        #expect(!session.isDirty)
        window.makeFirstResponder(editor)
        editor.setSelectedRange((editor.string as NSString).range(of: "Heading"))
        controls.send(.bold)
        try await Task.sleep(for: .milliseconds(100))
        #expect(session.currentText() == source.replacingOccurrences(of: "# Heading", with: "# **Heading**"))
        #expect(session.isDirty)
        #expect(editor.undoManager?.canUndo == true)
        editor.undoManager?.undo()
        try await Task.sleep(for: .milliseconds(100))
        #expect(session.currentText() == source)
        editor.undoManager?.redo()
        try await Task.sleep(for: .milliseconds(100))
        #expect(session.currentText().contains("# **Heading**"))
        // A callback from the previous document must never replace a new file.
        session.prepare(documentKey: "next", text: "next document")
        controls.send(.italic)
        try await Task.sleep(for: .milliseconds(100))
        #expect(session.currentText() == "next document")
    }

    @Test func nativeTypingUndoAndRedoUpdateTheSourceIncludingImmediateUndo() async throws {
        let original = "A paragraph."
        let session = FileEditorSession()
        session.prepare(documentKey: "typing-undo", text: original)
        let controls = NativeMarkdownControls()
        let host = NSHostingView(
            rootView: NativeMarkdownTextSurface(
                session: session, documentKey: "typing-undo", active: true, controls: controls))
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 750, height: 500),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setContentSize(.init(width: 750, height: 500))
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await settle { controls.textView != nil }
        let editor = try #require(controls.textView)
        window.makeFirstResponder(editor)
        editor.insertText(" café 🚀", replacementRange: .init(location: (original as NSString).length, length: 0))
        editor.breakUndoCoalescing()
        try await settle { session.currentText() == original + " café 🚀" }
        #expect(editor.undoManager?.canUndo == true)
        editor.undoManager?.undo()
        try await settle { session.currentText() == original && editor.string == original }
        #expect(editor.undoManager?.canRedo == true)
        editor.undoManager?.redo()
        try await settle { session.currentText() == original + " café 🚀" }
        editor.undoManager?.undo()
        try await settle { session.currentText() == original }

        // An Undo may arrive before the preceding edit's deferred binding
        // callback. Both callbacks must settle on the restored source.
        let revision = session.revision
        editor.insertText(" quick edit", replacementRange: .init(location: (original as NSString).length, length: 0))
        editor.breakUndoCoalescing()
        editor.undoManager?.undo()
        try await settle { session.revision >= revision + 2 }
        #expect(editor.string == original)
        #expect(session.currentText() == original)
    }

    @Test func sourceEditsInvalidateRichUndoAndHiddenEditorReleasesFocus() async throws {
        let session = FileEditorSession()
        session.prepare(documentKey: "shared", text: "Original")
        let controls = NativeMarkdownControls()
        let actions = NativeMarkdownTestActions()
        let host = NSHostingView(
            rootView: NativeMarkdownTestView(session: session, controls: controls, actions: actions))
        host.sizingOptions = []
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 1000, height: 650),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setContentSize(.init(width: 1000, height: 650))
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        let rich = try #require(controls.textView)
        let source = try #require(allTextViews(in: host).first { $0 !== rich })
        rich.setSelectedRange(NSRange(location: 0, length: 8))
        controls.send(.bold)
        try await Task.sleep(for: .milliseconds(100))
        #expect(session.currentText() == "**Original**")
        #expect(source.string == "**Original**")
        #expect(rich.undoManager?.canUndo == true)

        source.insertText(
            "Changed in source", replacementRange: NSRange(location: 0, length: (source.string as NSString).length))
        try await Task.sleep(for: .milliseconds(150))
        #expect(rich.string == "Changed in source")
        #expect(rich.undoManager?.canUndo == false)
        rich.undoManager?.undo()
        try await Task.sleep(for: .milliseconds(50))
        #expect(session.currentText() == "Changed in source")

        source.undoManager?.undo()
        try await Task.sleep(for: .milliseconds(100))
        #expect(session.currentText() == "**Original**")
        #expect(rich.string == "**Original**")
        window.makeFirstResponder(rich)
        let choose = try #require(actions.choose)
        choose(false)
        try await Task.sleep(for: .milliseconds(100))
        #expect(!rich.isEditable)
        #expect(window.firstResponder !== rich)
        controls.send(.italic)
        #expect(session.currentText() == "**Original**")
        choose(true)
        try await Task.sleep(for: .milliseconds(100))
        #expect(controls.textView === rich)
        #expect(rich.isEditable)
        #expect(rich.string == "**Original**")
    }

    @Test func codeButtonWrapsSelectionWithoutLosingItsContent() async throws {
        let session = FileEditorSession()
        let initial = "Before\n\nlet value = ```example```\n\nAfter"
        session.prepare(documentKey: "code", text: initial)
        let controls = NativeMarkdownControls()
        let host = NSHostingView(
            rootView: NativeMarkdownTextSurface(session: session, documentKey: "code", active: true, controls: controls)
        )
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 700, height: 600), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setContentSize(.init(width: 700, height: 600))
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let rich = try #require(controls.textView)
        rich.setSelectedRange((rich.string as NSString).range(of: "let value = ```example```"))
        controls.send(.code)
        try await Task.sleep(for: .milliseconds(100))
        #expect(session.currentText().contains("````\nlet value = ```example```\n````"))
        #expect(session.currentText().hasPrefix("Before\n\n"))
        #expect(session.currentText().hasSuffix("\n\nAfter"))
        rich.undoManager?.undo()
        try await Task.sleep(for: .milliseconds(100))
        #expect(session.currentText() == initial)
    }

    @Test func clipboardSelectionUsesDisplayedWikiLinkCoordinates() {
        let source = "[[Page|opaque-id]] Tail [[Next|next-id]] End"
        let display = WikiLinkService.makeDisplayState(from: source).display as NSString
        for (selected, expected) in [
            ("Tail", "Tail"), ("Page", "Page"), ("[[Page]]", "[[Page|opaque-id]]"), ("End", "End"),
            ("[[Next]] End", "[[Next|next-id]] End"),
        ] {
            #expect(
                NativeMarkdownControls.selectedMarkdown(source: source, displaySelection: display.range(of: selected))
                    == expected)
        }
    }

    @Test func richCopyKeepsCodeBlocksAndSelection() {
        let controls = NativeMarkdownControls()
        let source = "Before\n\n```vega-lite\n{\"mark\":\"bar\"}\n```\n\nAfter"
        let range = (source as NSString).range(of: "```vega-lite\n{\"mark\":\"bar\"}\n```")
        let menu = controls.contextMenu(NSMenu(), source: source, selection: range)
        #expect(menu.items.prefix(2).map(\.title) == ["Copy as Rich Text", "Copy as Markdown"])
        let html = MarkdownHTMLRenderer.html(from: (source as NSString).substring(with: range))
        #expect(html.contains("<pre"))
        #expect(html.contains("vega-lite"))
        #expect(html.contains("bar"))
    }

    private func selectMode(_ mode: MarkdownFileEditorMode, in view: NSView) throws {
        let picker = try #require(modePicker(in: view))
        let index = try #require(MarkdownFileEditorMode.allCases.firstIndex(of: mode))
        let action = try #require(picker.action)
        picker.selectedSegment = index
        #expect(picker.sendAction(action, to: picker.target))
    }

    private func modePicker(in view: NSView) -> NSSegmentedControl? {
        if let picker = view as? NSSegmentedControl,
            picker.segmentCount == MarkdownFileEditorMode.allCases.count
        {
            return picker
        }
        return view.subviews.lazy.compactMap { modePicker(in: $0) }.first
    }

    private func containsWebView(in view: NSView) -> Bool {
        view is WKWebView || view.subviews.contains { containsWebView(in: $0) }
    }

    private func textView(in view: NSView) -> NSTextView? {
        if let text = view as? NSTextView { return text }
        return view.subviews.lazy.compactMap { textView(in: $0) }.first
    }

    private func allTextViews(in view: NSView) -> [NSTextView] {
        if let text = view as? NSTextView { return [text] }
        return view.subviews.flatMap { allTextViews(in: $0) }
    }

    private func settle(_ message: String = "The native editor did not settle", _ ready: () -> Bool) async throws {
        for _ in 0..<100 {
            if ready() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(ready(), Comment(rawValue: message))
    }
}

@MainActor
private final class NativeMarkdownTestActions {
    var choose: ((Bool) -> Void)?
}

private struct NativeMarkdownTestView: View {
    let session: FileEditorSession
    let controls: NativeMarkdownControls
    let actions: NativeMarkdownTestActions
    @State private var active = true

    var body: some View {
        HStack {
            SyntaxHighlightedEditor(session: session, documentKey: "shared", text: "Original", filename: "file.md")
            NativeMarkdownTextSurface(session: session, documentKey: "shared", active: active, controls: controls)
                .opacity(active ? 1 : 0)
        }
        .background(NativeMarkdownTestCapture(actions: actions, choose: { active = $0 }))
    }
}

private struct NativeMarkdownTestCapture: NSViewRepresentable {
    let actions: NativeMarkdownTestActions
    let choose: (Bool) -> Void
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ nsView: NSView, context: Context) { actions.choose = choose }
}
