import AppKit
import Testing
@testable import DieterMac

@MainActor
struct QuickTaskStoryEditorTests {
    @Test func attachmentPasteIsHandledByTheNativeFirstResponder() {
        let editor = QuickTaskStoryTextView()
        editor.string = "Keep this text"
        var calls = 0
        editor.pasteAttachment = { pasteboard in
            calls += 1
            #expect(pasteboard === NSPasteboard.general)
            return true
        }

        editor.paste(nil)

        #expect(calls == 1)
        #expect(editor.string == "Keep this text")
    }

    @Test func declinedAttachmentPasteRemainsAvailableToNativeTextPaste() {
        let editor = QuickTaskStoryTextView()
        let pasteboard = NSPasteboard(name: .init("quick-task-story-editor-test"))
        pasteboard.clearContents()
        pasteboard.setString("Plain text", forType: .string)
        editor.pasteAttachment = { _ in false }

        #expect(!editor.consumesAttachmentPaste(from: pasteboard))
    }
}
