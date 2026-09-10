import AppKit
import SwiftUI
import Testing
@testable import DieterMac

@MainActor
struct MarkdownEditorLayoutTests {
    @Test func nativeLayoutModesKeepEditorsAndRestoreTheDivider() async throws {
        let controller = MarkdownEditorSplitController()
        let session = FileEditorSession()
        controller.sourceHost.rootView = AnyView(
            SyntaxHighlightedEditor(session: session, documentKey: "test", text: "# Original", filename: "test.md"))
        controller.previewHost.rootView = AnyView(Text("Preview"))
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 1000, height: 600),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        // Assigning a content controller initially sizes the window to its
        // fitting size. Give the split a real editor-sized viewport.
        window.setContentSize(NSSize(width: 1000, height: 600))
        defer { window.close() }
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        let editor = try #require(textView(in: controller.sourceHost))
        let previewHost = controller.previewHost
        window.makeFirstResponder(editor)
        editor.insertText(" draft", replacementRange: NSRange(location: 10, length: 0))
        #expect(session.currentText() == "# Original draft")
        #expect(session.isDirty)
        controller.splitView.setPosition(610, ofDividerAt: 0)
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        window.contentView?.layoutSubtreeIfNeeded()
        let originalWidth = controller.sourceHost.frame.width
        #expect(abs(originalWidth - 610) < 2)

        for mode in [MarkdownEditorLayout.preview, .source, .preview, .split, .source, .split] {
            controller.setLayout(mode)
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
            window.contentView?.layoutSubtreeIfNeeded()
            #expect(controller.splitViewItems[0].isCollapsed == (mode == .preview))
            #expect(controller.splitViewItems[1].isCollapsed == (mode == .source))
            #expect(textView(in: controller.sourceHost) === editor)
            #expect(controller.previewHost === previewHost)
            #expect(session.currentText() == "# Original draft")
            #expect(abs(controller.splitView.bounds.width - 1000) < 2)
            #expect(abs((window.contentView?.bounds.width ?? 0) - 1000) < 2)
            if mode == .split { #expect(abs(controller.sourceHost.frame.width - originalWidth) < 2) }
        }
        #expect(abs(controller.sourceHost.frame.width - originalWidth) < 2)
        #expect(editor.undoManager?.canUndo == true)
        editor.undoManager?.undo()
        #expect(session.currentText() == "# Original")
        editor.undoManager?.redo()
        #expect(session.currentText() == "# Original draft")
    }

    @Test func swiftUISelectionKeepsTheSplitInsideItsParent() async throws {
        let actions = MarkdownLayoutTestActions()
        let host = NSHostingView(rootView: MarkdownLayoutTestView(actions: actions))
        host.sizingOptions = []
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 1000, height: 600),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.setContentSize(NSSize(width: 1000, height: 600))
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))

        let controller = try #require(splitController(in: host))
        let choose = try #require(actions.choose)
        let sourceHost = controller.sourceHost
        let previewHost = controller.previewHost
        controller.splitView.setPosition(610, ofDividerAt: 0)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        host.layoutSubtreeIfNeeded()
        #expect(abs(sourceHost.frame.width - 610) < 2)

        for mode in [MarkdownEditorLayout.preview, .source, .preview, .split] {
            choose(mode)
            // Exercise the ordinary SwiftUI update cycle without forcing a
            // parent layout that could hide the split expanding its window.
            try await Task.sleep(for: .milliseconds(100))
            #expect(controller.layout == mode)
            #expect(controller.sourceHost === sourceHost)
            #expect(controller.previewHost === previewHost)
            #expect(abs(controller.splitView.bounds.width - 1000) < 2)
            #expect(abs((window.contentView?.bounds.width ?? 0) - 1000) < 2)
        }
        host.layoutSubtreeIfNeeded()
        #expect(abs(sourceHost.frame.width - 610) < 2)
    }

    private func splitController(in view: NSView) -> MarkdownEditorSplitController? {
        if let split = view as? NSSplitView, let controller = split.delegate as? MarkdownEditorSplitController {
            return controller
        }
        return view.subviews.lazy.compactMap { splitController(in: $0) }.first
    }

    private func textView(in view: NSView) -> NSTextView? {
        if let editor = view as? NSTextView { return editor }
        return view.subviews.lazy.compactMap { textView(in: $0) }.first
    }
}

@MainActor
private final class MarkdownLayoutTestActions {
    var choose: ((MarkdownEditorLayout) -> Void)?
}

private struct MarkdownLayoutTestView: View {
    let actions: MarkdownLayoutTestActions
    @State private var layout: MarkdownEditorLayout = .split

    var body: some View {
        MarkdownEditorSplitView(source: AnyView(Text("Source")), preview: AnyView(Text("Preview")), layout: layout)
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
            .background(MarkdownLayoutTestActionCapture(actions: actions, choose: { layout = $0 }))
    }
}

private struct MarkdownLayoutTestActionCapture: NSViewRepresentable {
    let actions: MarkdownLayoutTestActions
    let choose: (MarkdownEditorLayout) -> Void

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        actions.choose = choose
    }
}
