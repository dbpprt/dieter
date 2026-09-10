import AppKit
import DieterAPI
import SwiftUI
import Testing
@testable import DieterMac

@Test @MainActor func messageFooterCopiesExactMarkdownForUserAndAssistant() throws {
    let source = "  # A heading\n\n**Bold** and [a link](https://example.com).\n\n```swift\nlet emoji = \"👋\"\n```\n\n"
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }

    for role in ["user", "assistant"] {
        let content = MessageFooterContent(messages: [footerMessage(role: role, text: source)])
        #expect(content.copy(to: pasteboard))
        #expect(pasteboard.string(forType: .string) == source)
        #expect(content.timestamp == DieterTimestamp.date(from: "2026-09-10T12:34:56.123Z"))
    }
}

@Test @MainActor func messageFooterCopiesAllTextPartsWithoutCopyingAttachmentOrToolPreviews() {
    var message = footerMessage(role: "assistant", text: "First **paragraph**.\n")
    var attachment = Dieter_V1_MessagePart()
    attachment.type = "file"
    attachment.filename = "screenshot.png"
    attachment.text = "Attachment metadata"
    var tool = Dieter_V1_MessagePart()
    tool.type = "tool-exec"
    tool.inputPreview = "echo preview"
    tool.outputPreview = "Tool output preview"
    var reasoning = Dieter_V1_MessagePart()
    reasoning.type = "reasoning"
    reasoning.text = "Private reasoning is separate from the response"
    message.parts += [attachment, tool, reasoning, footerPart("Last `paragraph`.  ")]
    let content = MessageFooterContent(messages: [message])
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    #expect(content.copy(to: pasteboard))
    #expect(pasteboard.string(forType: .string) == "First **paragraph**.\n\n\nLast `paragraph`.  ")
}

@Test @MainActor func messageFooterDoesNotClearClipboardForRowsWithoutMessageText() {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    pasteboard.setString("Keep the clipboard", forType: .string)
    var message = footerMessage(role: "assistant", text: "")
    message.parts[0].type = "tool"
    message.parts[0].outputPreview = "A preview is not the full tool result"
    let content = MessageFooterContent(messages: [message])
    #expect(content.markdown.isEmpty)
    #expect(!content.copy(to: pasteboard))
    #expect(pasteboard.string(forType: .string) == "Keep the clipboard")
}

@Test func messageFooterUsesLastGroupedMessageTimeAndNeverInventsMissingTimes() {
    let first = footerMessage(role: "assistant", text: "First")
    var last = footerMessage(role: "assistant", text: "Last")
    last.metadataJson = Data(#"{"createdAt":"2026-09-10T13:45:00Z"}"#.utf8)
    #expect(
        MessageFooterContent(messages: [first, last]).timestamp
            == DieterTimestamp.date(from: "2026-09-10T13:45:00Z"))

    for invalid in [Data(), Data("not JSON".utf8), Data(#"{"createdAt":"invalid"}"#.utf8)] {
        last.metadataJson = invalid
        let content = MessageFooterContent(messages: [first, last])
        #expect(content.timestamp == nil)
        #expect(content.timestampLabel == "Time unavailable")
        #expect(content.markdown == "First\n\nLast")
    }
}

@Test @MainActor func messageFooterKeepsItsHeightWhenHoverAndLatestStateChange() {
    let content = MessageFooterContent(messages: [footerMessage(role: "user", text: "A draft 👋")])
    for width in [CGFloat(180), 320, 620] {
        let root = NSHostingView(
            rootView: MessageFooter(content: content, messageID: "footer-test", isLatest: false, isHovered: false)
                .frame(width: width))
        root.frame = NSRect(x: 0, y: 0, width: width, height: 24)
        root.layoutSubtreeIfNeeded()
        let originalHeight = root.fittingSize.height
        #expect(originalHeight == 24)
        for (latest, hovered) in [(false, true), (true, false), (true, true), (false, false)] {
            root.rootView = MessageFooter(
                content: content, messageID: "footer-test", isLatest: latest, isHovered: hovered
            ).frame(width: width)
            root.layoutSubtreeIfNeeded()
            #expect(root.fittingSize.height == originalHeight)
            #expect(root.fittingSize.width == width)
        }
    }
}

private func footerMessage(role: String, text: String) -> Dieter_V1_UiMessage {
    var message = Dieter_V1_UiMessage()
    message.id = "footer-\(role)"
    message.role = role
    message.metadataJson = Data(#"{"createdAt":"2026-09-10T12:34:56.123Z"}"#.utf8)
    message.parts = [footerPart(text)]
    return message
}

private func footerPart(_ text: String) -> Dieter_V1_MessagePart {
    var part = Dieter_V1_MessagePart()
    part.type = "text"
    part.text = text
    return part
}
