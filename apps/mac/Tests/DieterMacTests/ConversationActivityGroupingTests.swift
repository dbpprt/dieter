import DieterAPI
import Testing
@testable import DieterMac

struct ConversationActivityGroupingTests {
    @Test func alternatingReasoningAndToolsBecomeOneStableSummaryBetweenMessages() throws {
        let messages = [
            message("user", role: "user", parts: [part("text", text: "Please investigate")]),
            message("r1", parts: [part("reasoning", text: "Inspect first")]),
            message("t1", parts: [part("tool-call", name: "exec_command")]),
            message("r2", parts: [part("thinking", text: "Apply the change")]),
            message("t2", parts: [part("tool-apply_patch")]),
            message("answer", parts: [part("text", text: "Implemented.")]),
        ]
        let projection = build(messages)
        #expect(projection.displayGroups.count == 3)
        #expect(projection.displayGroups.map(\.isActivity) == [false, true, false])
        let activity = projection.displayGroups[1]
        #expect(activity.id == "message:r1")
        #expect(activity.rows.flatMap(\.item.messages).map(\.id) == ["r1", "t1", "r2", "t2"])
        let steps = ConversationActivityStep.steps(
            messages: activity.rows.flatMap(\.item.messages), showReasoning: true)
        let summary = ConversationActivitySummary(steps: steps)
        #expect(summary.reasoningCount == 2)
        #expect(summary.title == "Reasoning · 1 edit · 1 command")
        // Incoming tool events append to the same disclosure instead of resetting
        // its expansion state, and every existing timeline anchor stays addressable.
        let growing = build(Array(messages.dropLast()) + [message("t3", parts: [part("tool-call", name: "Read")])])
        #expect(growing.displayGroups[1].id == activity.id)
        #expect(growing.displayGroups[1].rows.map(\.id).starts(with: activity.rows.map(\.id)))
    }

    @Test func mixedAssistantMessageKeepsProseVisibleAndCoalescesTextSelection() throws {
        let source = message(
            "mixed",
            parts: [
                part("text", text: "Starting"), part("text", text: "with a plan"),
                part("reasoning", text: "Inspect"), part("tool-call", name: "Bash"),
                part("thinking", text: "Check"), part("tool-call", name: "Read"),
                part("text", text: "Finished"), part("image", text: "", url: "data:image/png;base64,eA=="),
            ])
        let groups = ConversationActivityPartGroup.group(
            ConversationActivityStep.steps(messages: [source], showReasoning: true))
        #expect(groups.count == 4)
        #expect(groups.map(\.isActivity) == [false, true, false, false])
        #expect(groups[0].steps[0].part.text == "Starting\n\nwith a plan")
        #expect(groups[1].steps.map(\.part.type) == ["reasoning", "tool-call", "thinking", "tool-call"])
        #expect(groups[2].steps[0].part.text == "Finished")
        #expect(build([source]).displayGroups.first?.isActivity == false)
    }

    @Test func toolFailuresApprovalsAndUserMessagesBreakActivityGroups() {
        var failed = part("tool-call", name: "Bash", state: "output-error")
        failed.errorText = "The command exited with status 1"
        let approval = part("tool-call", name: "Write", state: "approval-requested")
        let messages = [
            message("r1", parts: [part("reasoning", text: "Thinking")]),
            message("failed", parts: [failed]),
            message("r2", parts: [part("reasoning", text: "Recovering")]),
            message("approval", parts: [approval]),
            message("human", role: "human", parts: [part("reasoning", text: "This is my text")]),
        ]
        #expect(build(messages).displayGroups.map(\.isActivity) == [true, false, true, false, false])
        #expect(ConversationActivityGrouping.needsAttention(failed))
        #expect(ConversationActivityGrouping.needsAttention(approval))
        let mixed = ConversationActivityPartGroup.group(
            ConversationActivityStep.steps(
                messages: [
                    message(
                        "one",
                        parts: [part("tool-call", name: "Read"), failed, approval, part("tool-call", name: "Read")])
                ],
                showReasoning: true))
        #expect(mixed.map(\.isActivity) == [true, false, false, true])
        #expect(mixed[1].steps[0].part.errorText == failed.errorText)
    }

    @Test func hiddenReasoningDoesNotCreateExtraRowsAndStructuredDetailsStayVisible() {
        let messages = [
            message("r1", parts: [part("reasoning", text: "Thinking")]),
            message("tool", parts: [part("tool-call", name: "Bash")]),
            message("r2", parts: [part("thinking", text: "Checking")]),
            message("tool2", parts: [part("tool-call", name: "Read")]),
        ]
        let hidden = build(messages, showReasoning: false)
        #expect(hidden.displayGroups.count == 1)
        let steps = ConversationActivityStep.steps(
            messages: hidden.displayGroups[0].rows.flatMap(\.item.messages), showReasoning: false)
        #expect(steps.map(\.part.effectiveToolName) == ["Bash", "Read"])
        #expect(ConversationActivitySummary(steps: steps).title == "1 command · 1 tool call")
        var plan = Dieter_V1_TaskPlan()
        plan.id = "plan"
        plan.messageID = "tool"
        let withPlan = ConversationTimelineProjection.build(
            messages: messages, allMessageIDs: Set(messages.map(\.id)), plans: [plan],
            subagents: [], queue: [], showReasoning: true)
        #expect(withPlan.displayGroups[1].isActivity == false)
        #expect(withPlan.displayGroups[1].rows[0].details.flatMap(\.plans).map(\.id) == ["plan"])
    }

    @Test func diagnosticsRemainVisibleEvenWhenReasoningIsHidden() {
        var diagnostic = part("reasoning", text: "Provider failed", state: "error")
        diagnostic.errorText = "Connection closed"
        let projection = build([message("error", parts: [diagnostic])], showReasoning: false)
        #expect(projection.displayGroups.count == 1)
        #expect(projection.displayGroups.first?.isActivity == false)
        #expect(
            ConversationActivityStep.steps(messages: [message("error", parts: [diagnostic])], showReasoning: false)
                .count == 1)
    }

    private func build(_ messages: [Dieter_V1_UiMessage], showReasoning: Bool = true) -> ConversationTimelineProjection
    {
        ConversationTimelineProjection.build(
            messages: messages, allMessageIDs: Set(messages.map(\.id)), plans: [], subagents: [], queue: [],
            showReasoning: showReasoning)
    }

    private func message(_ id: String, role: String = "assistant", parts: [Dieter_V1_MessagePart])
        -> Dieter_V1_UiMessage
    {
        var message = Dieter_V1_UiMessage()
        message.id = id
        message.role = role
        message.parts = parts
        return message
    }

    private func part(_ type: String, text: String = "", name: String = "", state: String = "", url: String = "")
        -> Dieter_V1_MessagePart
    {
        var part = Dieter_V1_MessagePart()
        part.type = type
        part.text = text
        part.toolName = name
        part.state = state
        part.url = url
        return part
    }
}
