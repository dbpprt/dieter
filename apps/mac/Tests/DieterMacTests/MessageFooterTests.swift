import AppKit
import DieterAPI
import SwiftUI
import Testing
@testable import DieterMac

@Test @MainActor func messageFooterKeepsItsHeightWhenHoverAndLatestStateChange() {
    let content = MessageFooterContent(
        row: .with {
            $0.createdAtMillis = 1_789_000_000_000
            $0.copyable = true
        },
        messages: [footerMessage(role: "user", text: "A draft 👋")])
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
