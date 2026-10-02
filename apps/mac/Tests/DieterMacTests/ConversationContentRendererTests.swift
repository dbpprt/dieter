import AppKit
import DieterAPI
import Testing
@testable import DieterMac

@MainActor
struct ConversationContentRendererTests {
    @Test func browserExposesItsNavigationPolicyToWebKit() {
        let model = ConversationBrowserModel()
        // WKNavigationDelegate is an optional Objective-C protocol. A Swift
        // method with a nearly matching actor signature can compile while
        // WebKit silently skips its policy callback.
        let selector = NSSelectorFromString("webView:decidePolicyForNavigationAction:decisionHandler:")
        #expect(model.responds(to: selector))
    }

    @Test func readOnlyCodeRefusesEditsAndOnlyRevealsTheRequestedLineOnce() {
        let session = FileEditorSession()
        let source = (1...200).map { "line \($0)" }.joined(separator: "\n")
        let editor = SyntaxHighlightedEditor(
            session: session, documentKey: "code", text: source, filename: "main.swift",
            editable: false, requestedLine: 150
        )
        let container = SyntaxEditorContainer(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        let coordinator = editor.makeCoordinator()
        coordinator.textView = container.textView
        coordinator.container = container
        container.textView.delegate = coordinator
        session.attach(container.textView, documentKey: "code", initialText: source)
        #expect(
            !coordinator.textView(
                container.textView, shouldChangeTextIn: NSRange(location: 0, length: 0), replacementString: "change"))
        #expect(session.currentText() == source)
        #expect(!session.isDirty)

        coordinator.revealRequestedLine()
        container.layoutSubtreeIfNeeded()
        let expected = SyntaxHighlightedEditor.range(ofLine: 150, in: source)
        #expect(container.textView.selectedRange() == expected)
        container.textView.setSelectedRange(NSRange(location: 0, length: 0))
        coordinator.revealRequestedLine()
        container.layoutSubtreeIfNeeded()
        #expect(container.textView.selectedRange() == NSRange(location: 0, length: 0))
        session.detach(container.textView)
    }

    @Test func browserNavigationAllowsOnlyWebURLs() throws {
        for value in ["https://example.com/docs", "http://localhost:8080", "https://example.com/#section"] {
            #expect(ConversationBrowserModel.permits(try #require(URL(string: value))))
        }
        for value in [
            "file:///etc/passwd", "javascript:alert(1)", "data:text/html,hello", "mailto:test@example.com",
            "about:blank",
        ] {
            #expect(!ConversationBrowserModel.permits(try #require(URL(string: value))))
        }
    }
}
