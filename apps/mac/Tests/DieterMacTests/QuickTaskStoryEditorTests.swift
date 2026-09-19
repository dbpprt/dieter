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

    @Test func commandVPasteIsConsumedEvenWhenTheNativeTextMenuRejectsAnImage() throws {
        let editor = QuickTaskStoryTextView()
        var calls = 0
        editor.pasteAttachment = { _ in
            calls += 1; return true
        }
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 1,
                windowNumber: 0, context: nil, characters: "v", charactersIgnoringModifiers: "v",
                isARepeat: false, keyCode: 9))

        #expect(editor.performKeyEquivalent(with: event))
        #expect(calls == 1)
    }

    @Test func attachmentPasteKeepsTheEditMenuEnabled() {
        let editor = QuickTaskStoryTextView()
        editor.canPasteAttachment = { _ in true }
        let paste = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")

        #expect(editor.validateUserInterfaceItem(paste))
    }

    @Test func conversationPasteMonitorGivesTheFocusedQuickTaskEditorPriority() {
        let editor = QuickTaskStoryTextView()
        let pasteboard = NSPasteboard(name: .init("quick-task-priority-test"))
        var quickTaskCalls = 0
        var conversationCalls = 0
        editor.pasteAttachment = { received in
            quickTaskCalls += 1
            #expect(received === pasteboard)
            return true
        }

        let consumed = AttachmentPasteRouting.consume(
            firstResponder: editor, from: pasteboard,
            fallback: { _ in
                conversationCalls += 1
                return true
            })

        #expect(consumed)
        #expect(quickTaskCalls == 1)
        #expect(conversationCalls == 0)
    }
}
