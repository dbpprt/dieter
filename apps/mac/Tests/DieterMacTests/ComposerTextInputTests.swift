import AppKit
import SwiftUI
import Testing
@testable import DieterMac

@MainActor
struct ComposerTextInputTests {
    @Test func shiftReturnInsertsANewlineAtTheSelectionAndPlainReturnRemainsAvailableToSend() {
        let editor = NSTextView()
        editor.isFieldEditor = true
        editor.string = "First selected last"
        editor.setSelectedRange((editor.string as NSString).range(of: " selected "))

        #expect(!ComposerTextInput.insertLineBreak(shiftPressed: false, responder: editor))
        #expect(editor.string == "First selected last")
        #expect(ComposerTextInput.insertLineBreak(shiftPressed: true, responder: editor))
        #expect(editor.string == "First\nlast")
        #expect(editor.selectedRange() == NSRange(location: 6, length: 0))
    }

    @Test func composerGrowsForNewlinesAndPastedTextThenKeepsItsHeightBounded() async throws {
        let state = ComposerTextInputTestState()
        let host = NSHostingView(rootView: ComposerTextInputTestView(state: state).frame(width: 360))
        let window = NSWindow(
            contentRect: NSRect(x: -3_000, y: -3_000, width: 360, height: 220),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }

        func settle() async {
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(60))
            host.layoutSubtreeIfNeeded()
        }

        await settle()
        let editor: NSTextView
        if let embedded = textView(in: host) {
            editor = embedded
            window.makeFirstResponder(editor)
        } else {
            let field = try #require(textField(in: host))
            window.makeFirstResponder(field)
            editor = try #require(field.currentEditor() as? NSTextView)
        }
        let singleLineHeight = host.fittingSize.height
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        #expect(ComposerTextInput.insertLineBreak(shiftPressed: true, responder: editor))
        await settle()
        #expect(state.text == "First\n")
        #expect(host.fittingSize.height > singleLineHeight)
        #expect(window.firstResponder === editor)

        editor.insertText("Second\nThird\nFourth\nFifth", replacementRange: editor.selectedRange())
        await settle()
        #expect(state.text == "First\nSecond\nThird\nFourth\nFifth")
        let fiveLineHeight = host.fittingSize.height
        #expect(fiveLineHeight > singleLineHeight)

        editor.insertText(String(repeating: "\nMore", count: 15), replacementRange: editor.selectedRange())
        await settle()
        #expect(state.text.components(separatedBy: "\n").count == 20)
        #expect(abs(host.fittingSize.height - fiveLineHeight) < 1)
        #expect(editor.selectedRange() == NSRange(location: (state.text as NSString).length, length: 0))
        #expect(window.firstResponder === editor)

        state.text = ""
        await settle()
        #expect(abs(host.fittingSize.height - singleLineHeight) < 1)
    }

    private func textView(in view: NSView) -> NSTextView? {
        (view as? NSTextView) ?? view.subviews.lazy.compactMap { textView(in: $0) }.first
    }

    private func textField(in view: NSView) -> NSTextField? {
        (view as? NSTextField) ?? view.subviews.lazy.compactMap { textField(in: $0) }.first
    }
}

@MainActor @Observable
private final class ComposerTextInputTestState {
    var text = "First"
}

private struct ComposerTextInputTestView: View {
    @Bindable var state: ComposerTextInputTestState
    @FocusState private var focused: Bool

    var body: some View {
        ComposerTextInput(placeholder: "Message…", text: $state.text, focus: $focused)
    }
}
