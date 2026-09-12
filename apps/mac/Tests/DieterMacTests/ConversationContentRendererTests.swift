import AppKit
import DieterAPI
import Testing
@testable import DieterMac

@MainActor
struct ConversationContentRendererTests {
    @Test func remoteBrowserRejectsLoopbackNavigationAndRedirectTargets() throws {
        let model = ConversationBrowserModel()
        model.allowsLoopback = false
        for address in [
            "localhost", "app.localhost", "127.0.0.1", "127.1", "2130706433", "[::1]", "[::ffff:127.0.0.1]", "0.0.0.0",
        ] {
            let url = try #require(URL(string: "http://\(address):8080"))
            #expect(ConversationBrowserModel.isLoopback(url))
            #expect(!model.accepts(url))
        }
        #expect(model.accepts(try #require(URL(string: "https://example.com"))))
        model.allowsLoopback = true
        #expect(model.accepts(try #require(URL(string: "http://localhost:8080"))))
    }

    @Test func choosesNativeRenderersFromDocumentMetadata() {
        func kind(_ name: String, mime: String = "", binary: Bool = false) -> ConversationFileRendererKind {
            var document = Dieter_V1_FileDocument()
            document.name = name
            document.mimeType = mime
            document.binary = binary
            return ConversationFileRendererKind(document: document)
        }
        #expect(kind("plan.md") == .markdown)
        #expect(kind("main.swift") == .text)
        #expect(kind("README") == .text)
        #expect(kind("photo.PNG", binary: true) == .image)
        #expect(kind("asset", mime: "image/jpeg", binary: true) == .image)
        #expect(kind("report.PDF", binary: true) == .pdf)
        #expect(kind("report", mime: "application/pdf; charset=binary", binary: true) == .pdf)
        #expect(kind("archive.zip", binary: true) == .unsupported)
        #expect(kind("broken.md", binary: true) == .unsupported)
    }

    @Test func codeLinksUseOneBasedUTF16LineRangesAndClampStaleLineNumbers() {
        let source = "let emoji = \"💡\"\r\nsecond line\r\nfinal"
        let native = source as NSString
        let second = SyntaxHighlightedEditor.range(ofLine: 2, in: source)
        #expect(native.substring(with: second) == "second line")
        #expect(second.location == ("let emoji = \"💡\"\r\n" as NSString).length)
        #expect(native.substring(with: SyntaxHighlightedEditor.range(ofLine: -4, in: source)) == "let emoji = \"💡\"")
        #expect(native.substring(with: SyntaxHighlightedEditor.range(ofLine: 999, in: source)) == "final")
        #expect(SyntaxHighlightedEditor.range(ofLine: 3, in: "a\n") == NSRange(location: 2, length: 0))
        #expect(SyntaxHighlightedEditor.range(ofLine: 1, in: "") == NSRange(location: 0, length: 0))
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
