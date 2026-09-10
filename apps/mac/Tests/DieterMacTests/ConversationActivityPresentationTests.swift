import DieterAPI
import Foundation
import Testing
@testable import DieterMac

struct ConversationActivityPresentationTests {
    private func message(_ id: String, role: String = "assistant", parts: [Dieter_V1_MessagePart] = [])
        -> Dieter_V1_UiMessage
    {
        var message = Dieter_V1_UiMessage()
        message.id = id
        message.role = role
        message.parts = parts
        return message
    }

    private func tool(_ name: String, preview: String = "", state: String = "input-available", id: String = "call")
        -> Dieter_V1_MessagePart
    {
        var part = Dieter_V1_MessagePart()
        part.type = "dynamic-tool"
        part.toolName = name
        part.toolCallID = id
        part.state = state
        part.inputPreview = preview
        return part
    }

    private func text(_ value: String, type: String = "reasoning", state: String = "streaming") -> Dieter_V1_MessagePart
    {
        var part = Dieter_V1_MessagePart()
        part.type = type
        part.text = value
        part.state = state
        return part
    }

    private func label(_ parts: [Dieter_V1_MessagePart], showReasoning: Bool = true) -> String {
        ConversationActivityPresentation.liveLabel(
            messages: [message("user", role: "user"), message("assistant", parts: parts)],
            pendingTools: [], plans: [], showReasoning: showReasoning)
    }

    @Test(arguments: [
        ("bash", "go test ./internal/harness", "Running go test ./internal/harness"),
        ("Read", "/workspace/Sources/App.swift", "Reading App.swift"),
        ("Edit", "Sources/App.swift", "Editing App.swift"),
        ("webSearch", "SwiftUI status indicator", "Searching SwiftUI status indicator"),
        ("exec_command", #"{"cmd":"just mac test"}"#, "Running just mac test"),
        ("exec_command", #"{"cmd":["go","test","./..."]}"#, "Running go test ./..."),
        ("Bash", #"{"description":"Verify the runtime","command":"just harness test"}"#, "Verify the runtime"),
        ("mcp__files__read_file", "/project/README.md", "Reading README.md"),
        ("mcp__github__get_issue", #"{"number":68}"#, "Using get issue…"),
        ("write_stdin", #"{"session_id":42}"#, "Waiting for command…"),
    ])
    func usesActualToolEventsWithoutPendingTools(_ name: String, _ preview: String, _ expected: String) {
        #expect(label([tool(name, preview: preview)]) == expected)
    }

    @Test func showsLatestCompleteReasoningHeading() {
        let summary =
            "**Inspecting the tests**\n\nMore detail.\n\n**Waiting on runtime verification**\n\nThe command is still active."
        #expect(label([text(summary)]) == "Waiting on runtime verification")
        #expect(label([text("## Checking the results\n\nDetails")]) == "Checking the results")
        #expect(label([text("Inspecting the local workspace")]) == "Inspecting the local workspace")
        #expect(label([text("**Incomplete heading")]) == "Thinking…")
        #expect(label([text(String(repeating: "A long paragraph. ", count: 100))]) == "Thinking…")
        #expect(label([text(summary)], showReasoning: false) == "Thinking…")
    }

    @Test func followsToolAndWritingTransitionsWithoutResurrectingReasoning() {
        let summary = text("**Checking the files**", state: "done")
        #expect(label([summary, tool("Read", preview: "app.swift")]) == "Reading app.swift")
        #expect(label([summary, tool("Read", state: "output-available")]) == "Thinking…")
        #expect(label([summary, tool("Read", state: "output-error")]) == "Thinking…")
        #expect(label([summary, text("Results", type: "text")]) == "Writing response…")
        #expect(label([summary, text("Results", type: "text", state: "done")]) == "Thinking…")
    }

    @Test func retainsRunningToolsWhileOtherParallelToolsFinish() {
        #expect(
            label([
                tool("bash", preview: "go test ./...", id: "first"),
                tool("Read", preview: "app.swift", state: "output-available", id: "second"),
            ]) == "Running go test ./...")
        #expect(
            label([
                tool("bash", preview: "go test ./...", id: "first"),
                tool("Read", preview: "app.swift", id: "second"),
            ]) == "Reading app.swift · +1 tool")
    }

    @Test func approvalAndCancellationHavePriority() {
        let tools = [tool("bash", state: "approval-requested"), tool("Read", preview: "app.swift", id: "other")]
        #expect(label(tools) == "Waiting for approval: bash")
        #expect(
            ConversationActivityPresentation.liveLabel(
                messages: [message("assistant", parts: tools)], pendingTools: [], plans: [],
                conversationStatus: "cancelling") == "Stopping…")
        #expect(
            ConversationActivityPresentation.liveLabel(
                messages: [message("user", role: "user")], pendingTools: [], plans: [],
                cardRuntime: "starting") == "Starting agent…")
    }

    @Test func staleToolsAndReasoningDoNotCrossUserTurnBoundary() {
        let old = message("old", parts: [text("**Old work**"), tool("bash", preview: "old-command")])
        for role in ["user", "human"] {
            #expect(
                ConversationActivityPresentation.liveLabel(
                    messages: [old, message("new-user", role: role)], pendingTools: [], plans: []) == "Thinking…")
        }
    }

    @Test func codexPlanContentWorksOnlyForTheCurrentTurn() {
        var plan = Dieter_V1_TaskPlan()
        plan.messageID = "assistant"
        plan.state = "active"
        var phase = Dieter_V1_TaskPlanPhase()
        var task = Dieter_V1_TaskPlanItem()
        task.status = "in_progress"
        task.content = "Verify runtime behavior"
        phase.tasks = [task]
        plan.phases = [phase]
        let messages = [message("user", role: "user"), message("assistant")]
        #expect(
            ConversationActivityPresentation.liveLabel(
                messages: messages, pendingTools: [], plans: [plan]) == "Verify runtime behavior")
        #expect(
            ConversationActivityPresentation.liveLabel(
                messages: messages + [message("next-user", role: "user")], pendingTools: [], plans: [plan])
                == "Thinking…")
        plan.state = "interrupted"
        #expect(
            ConversationActivityPresentation.liveLabel(
                messages: messages, pendingTools: [], plans: [plan]) == "Thinking…")
    }

    @Test func pendingListCannotReviveCompletedTool() {
        var pending = Dieter_V1_PendingTool()
        pending.toolCallID = "call"
        pending.toolName = "bash"
        pending.inputPreview = "old-command"
        #expect(
            ConversationActivityPresentation.liveLabel(
                messages: [message("assistant", parts: [tool("bash", state: "output-available")])],
                pendingTools: [pending], plans: []) == "Thinking…")
    }

    @Test func malformedPayloadsAndLongUnicodeStayCompact() {
        #expect(label([tool("exec_command", preview: #"{"cmd":"partial…"#)]) == "Running command…")
        #expect(label([tool("apply_patch", preview: "*** Begin Patch *** Add File: File.swift…")]) == "Editing files…")
        let title = label([tool("bash", preview: "  echo\n" + String(repeating: "🚀", count: 300))])
        #expect(title.count == 120)
        #expect(!title.contains("\n"))
        #expect(title.hasSuffix("…"))
        var finished = tool("Read", preview: "App.swift")
        finished.hasOutput_p = true
        #expect(label([finished]) == "Thinking…")
    }

    @Test @MainActor func queuedAndOptimisticFollowupsDoNotChangeLiveActivityOrTimer() {
        let store = DieterStore(restoreSync: false)
        var currentUser = message("current-user", role: "user")
        currentUser.metadataJson = Data(#"{"createdAt":"2026-09-10T10:00:00Z"}"#.utf8)
        let assistant = message("assistant", parts: [tool("bash", preview: "go test ./...")])
        var snapshot = Dieter_V1_ConversationSnapshot()
        snapshot.conversation.messages = [
            currentUser, assistant, message("queued", role: "user"),
            message("optimistic", role: "user"), message("failed", role: "user"),
        ]
        var queued = Dieter_V1_QueuedMessage()
        queued.id = "queued"
        snapshot.conversation.queue = [queued]
        store.conversation = snapshot
        store.pendingMessageIDs = ["optimistic"]
        store.failedOutboxIDs = ["failed"]
        store.conversationModel.olderConversationMessages = [message("old-history", role: "user")]
        store.conversationModel.browsingEarlierHistory = true
        let live = store.conversationContext.liveActivityMessages
        #expect(live.map(\.id) == ["current-user", "assistant"])
        #expect(
            ConversationActivityPresentation.liveLabel(messages: live, pendingTools: [], plans: [])
                == "Running go test ./...")
        #expect(
            ConversationActivityPresentation.turnStart(messages: live, runtimeUpdatedAt: "2026-09-10T10:05:00Z")
                == DieterTimestamp.date(from: "2026-09-10T10:00:00Z"))
    }
}
