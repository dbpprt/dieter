import AppKit
import Foundation
import DieterAPI
import SwiftUI
import Testing
@testable import DieterMac

// Regression: the transcript must render with reasoning shown and hidden, and
// hiding reasoning must not leave hidden parts breaking tool-call grouping.

private func part(_ type: String, text: String = "", tool: String = "", callID: String = "") -> Dieter_V1_MessagePart {
    var part = Dieter_V1_MessagePart()
    part.type = type
    part.text = text
    part.toolName = tool
    part.toolCallID = callID
    part.state = type == "dynamic-tool" ? "output-available" : "done"
    return part
}

@Test @MainActor func conversationTimelineRendersWithBothReasoningStates() throws {
    var assistant = Dieter_V1_UiMessage()
    assistant.id = "message_1"
    assistant.role = "assistant"
    assistant.parts = [
        part("reasoning", text: "Weighing the options before touching files."),
        part("dynamic-tool", tool: "Read", callID: "tool_1"),
        part("reasoning", text: "The config needs one more edit."),
        part("dynamic-tool", tool: "Edit", callID: "tool_2"),
        part("dynamic-tool", tool: "Bash", callID: "tool_3"),
        part("text", text: "All done — the config is updated."),
    ]
    var user = Dieter_V1_UiMessage()
    user.id = "message_0"
    user.role = "user"
    user.parts = [part("text", text: "Please update the config.")]
    let messages = [user, assistant]

    for showReasoning in [true, false] {
        let store = DieterStore()
        store.showReasoning = showReasoning
        var conversation = Dieter_V1_ConversationSnapshot()
        conversation.conversation.messages = messages
        store.conversation = conversation

        let timeline = VStack(alignment: .leading, spacing: 15) {
            ForEach(ConversationTimelineItem.group(messages, showReasoning: showReasoning)) { item in
                if let message = item.messages.first {
                    MessageView(message: message).environment(store)
                }
            }
        }
        .frame(width: 700)
        .environment(store)

        let renderer = ImageRenderer(content: timeline)
        renderer.proposedSize = .init(width: 700, height: nil)
        #expect(renderer.nsImage != nil, "timeline must render with showReasoning=\(showReasoning)")
    }

    let hidden = ConversationMessagePartGroup.group(assistant.parts, showReasoning: false)
    #expect(hidden.count == 2)
    #expect(hidden[0].isToolCallGroup)
    #expect(hidden[0].parts.map(\.toolName) == ["Read", "Edit", "Bash"])
    let shown = ConversationMessagePartGroup.group(assistant.parts, showReasoning: true)
    #expect(shown.filter(\.isToolCallGroup).count == 2)
}
