import AppKit
import SwiftUI
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

    @Test func typingKeepsTheNativeEditorFocusedAcrossBindingUpdates() async throws {
        let state = QuickTaskStoryEditorTestState()
        let host = NSHostingView(rootView: QuickTaskStoryEditorTestView(state: state).frame(width: 360))
        let window = NSWindow(
            contentRect: NSRect(x: -3_000, y: -3_000, width: 360, height: 160),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }

        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(60))
        let editor = try #require(quickTaskEditor(in: host))
        #expect(window.makeFirstResponder(editor))

        for character in ["f", "o", "c", "u", "s"] {
            editor.insertText(character, replacementRange: editor.selectedRange())
            try? await Task.sleep(for: .milliseconds(30))
            host.layoutSubtreeIfNeeded()
            #expect(quickTaskEditor(in: host) === editor)
            #expect(editor.window === window)
            #expect(window.firstResponder === editor)
        }
        #expect(state.text == "focus")
    }

    private func quickTaskEditor(in view: NSView) -> QuickTaskStoryTextView? {
        (view as? QuickTaskStoryTextView)
            ?? view.subviews.lazy.compactMap { quickTaskEditor(in: $0) }.first
    }
}

@MainActor @Observable
private final class QuickTaskStoryEditorTestState {
    var text = ""
}

private struct QuickTaskStoryEditorTestView: View {
    @Bindable var state: QuickTaskStoryEditorTestState
    @State private var focused = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            QuickTaskStoryEditor(
                text: $state.text,
                focus: $focused,
                canPasteAttachment: { _ in false },
                pasteAttachment: { _ in false })
            if state.text.isEmpty {
                Text("What should the agent accomplish?")
                    .allowsHitTesting(false)
            }
        }
    }
}
