import DieterAPI
import SwiftUI
import UniformTypeIdentifiers

enum ComposerReturnPolicy {
    static func sendsMessage(shiftPressed: Bool) -> Bool { !shiftPressed }
}

enum ConversationRefreshText {
    static func label(lastRefreshedAt: Date?, syncing: Bool, now: Date = Date()) -> String {
        guard let lastRefreshedAt else { return syncing ? "Refreshing…" : "Not refreshed yet" }
        let seconds = max(0, now.timeIntervalSince(lastRefreshedAt))
        let freshness: String
        switch seconds {
        case ..<60:
            freshness = "just now"
        case ..<3_600:
            freshness = "\(Int(seconds / 60))m ago"
        case ..<86_400:
            freshness = "\(Int(seconds / 3_600))h ago"
        default:
            freshness = lastRefreshedAt.formatted(date: .abbreviated, time: .shortened)
        }
        return "Last refreshed \(freshness)" + (syncing ? " · Refreshing…" : "")
    }
}

struct ConversationView: View {
    @Environment(DieterStore.self) private var store
    var compact = false
    @State private var tab = "Conversation"
    @State private var fileImporterPresented = false

    private var standalone: Bool {
        (store.selectedCard ?? store.selectedDetail?.card)?.scope == "chat"
    }

    var body: some View {
        VStack(spacing: 0) {
            ConversationChrome(compact: compact, standalone: standalone, tab: $tab)

            Group {
                if store.conversationLoading {
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Loading conversation…").font(.caption).foregroundStyle(DieterTheme.tertiary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if tab == "Subagents" {
                    SubagentsView()
                } else if tab == "Comments" {
                    CommentsView()
                } else {
                    ConversationTimeline()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if tab == "Conversation" {
                ConversationComposer(fileImporterPresented: $fileImporterPresented)
            }
        }
        .background(DieterTheme.background)
        .onChange(of: store.selectedCardID) { _, _ in tab = "Conversation" }
        .onChange(of: store.selectedChatID) { _, _ in tab = "Conversation" }
        .fileImporter(isPresented: $fileImporterPresented, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case let .success(urls) = result { store.addAttachments(urls) }
            else if case let .failure(error) = result { store.show(error) }
        }
        .onPasteCommand(of: [.image, .fileURL]) { providers in
            store.addPastedAttachments(providers)
        }
        .attachmentPasteCatcher { pasteboard in
            store.attachPasteboard(pasteboard)
        }
    }
}

private struct ConversationChrome: View {
    @Environment(DieterStore.self) private var store
    let compact: Bool
    let standalone: Bool
    @Binding var tab: String

    private var card: Dieter_V1_Card? { store.selectedCard ?? store.selectedDetail?.card }
    private var status: String { store.conversation?.conversation.status ?? card?.runtime ?? "idle" }
    private var subagentCount: Int { store.conversation?.conversation.subagents.count ?? 0 }

    var body: some View {
        FluidPaneChrome(background: DieterTheme.sidebar, spacing: 8) {
            HStack(spacing: 10) {
                if compact {
                    Button { store.closeConversation() } label: { Image(systemName: "xmark") }
                        .buttonStyle(DieterIconButtonStyle()).help("Close conversation")
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(card?.title.isEmpty == false ? card!.title : "Conversation")
                        .font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    HStack(spacing: 4) {
                        if let detail = store.selectedDetail {
                            Text(detail.project.name).lineLimit(1)
                            Text(standalone ? "· Standalone chat" : "/ \(detail.board.name)").lineLimit(1)
                        }
                        if let id = card?.id, !id.isEmpty { Text("· \(id.prefix(8))").font(.system(size: 10).monospaced()) }
                        if card != nil {
                            Text("·")
                            TimelineView(.periodic(from: .now, by: 30)) { context in
                                Text(ConversationRefreshText.label(
                                    lastRefreshedAt: store.conversationLastRefreshedAt,
                                    syncing: store.conversationSyncing,
                                    now: context.date
                                ))
                                .accessibilityIdentifier("conversation-last-refreshed")
                            }
                            if store.conversationSyncing {
                                ProgressView().controlSize(.mini)
                                    .accessibilityLabel("Refreshing conversation")
                            }
                        }
                    }
                    .font(DieterFont.subtitle).foregroundStyle(DieterTheme.tertiary)
                }
                Spacer(minLength: 10)
                StatusPill(text: status, color: runtimeColor(status))
                if let card {
                    Menu {
                        if store.isFailedOutboxItem(card.id) {
                            Button("Retry queued creation") { Task { await store.retryOutboxItem(card.id) } }
                            Button("Discard queued creation", role: .destructive) { Task { await store.discardOutboxItem(card.id) } }
                            Divider()
                        }
                        if standalone { Button(card.pinned ? "Unpin chat" : "Pin chat") { Task { await store.pin(card, pinned: !card.pinned) } } }
                        if ["running", "starting", "waiting_for_user"].contains(status) {
                            Button("Interrupt agent", role: .destructive) { Task { await store.cancel(card) } }
                        }
                        Divider()
                        Button("Archive \(standalone ? "chat" : "card")", role: .destructive) { Task { await store.archive(card, archived: true) } }
                    } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .buttonStyle(DieterIconButtonStyle())
                }
            }
        } secondary: {
            ConversationTabBar(
                items: standalone ? [("Conversation", 0), ("Subagents", subagentCount)] : [
                    ("Conversation", 0),
                    ("Comments", Int(store.selectedDetail?.card.commentCount ?? 0)),
                    ("Subagents", subagentCount),
                ],
                selection: $tab
            )
        }
    }
}

private struct ConversationTabBar: View {
    let items: [(String, Int)]
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 16) {
            ForEach(items, id: \.0) { item in
                Button { selection = item.0 } label: {
                    VStack(spacing: 5) {
                        HStack(spacing: 5) {
                            Text(item.0).lineLimit(1)
                            if item.1 > 0 {
                                Text("\(item.1)").font(.caption2.weight(.bold)).foregroundStyle(selection == item.0 ? DieterTheme.shell : DieterTheme.tertiary)
                            }
                        }
                        .font(.system(size: 12, weight: selection == item.0 ? .semibold : .medium))
                        .foregroundStyle(selection == item.0 ? DieterTheme.text : DieterTheme.subtle)
                        Capsule().fill(selection == item.0 ? DieterTheme.primary : .clear).frame(height: 2)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }.buttonStyle(.plain)
            }
            Spacer()
        }
    }
}

private struct ConversationTimelineRow: View {
    let item: ConversationTimelineItem
    let details: [ConversationTimelineMessageDetails]

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            if item.isToolCallGroup {
                ToolCallGroupView(items: item.toolCalls)
            } else if let message = item.messages.first {
                MessageView(message: message)
            }
            ForEach(details) { detail in
                ForEach(detail.plans, id: \.id) {
                    TaskPlanView(plan: $0)
                }
                if !detail.subagents.isEmpty {
                    SubagentTimelineGroup(agents: detail.subagents)
                }
            }
        }
    }
}

private struct ConversationTimelineMessageDetails: Identifiable {
    let id: String
    let plans: [Dieter_V1_TaskPlan]
    let subagents: [Dieter_V1_Subagent]
}

private struct ConversationTimelineRowContent: Identifiable {
    let item: ConversationTimelineItem
    let details: [ConversationTimelineMessageDetails]

    var id: String { item.id }
}

struct ConversationTimeline: View {
    @Environment(DieterStore.self) private var store
    @State private var historyLoadInFlight = false

    private var messages: [Dieter_V1_UiMessage] { store.conversationMessages }
    private var timelineItems: [ConversationTimelineItem] {
        ConversationTimelineItem.group(messages, showReasoning: store.showReasoning)
    }
    private var plans: [Dieter_V1_TaskPlan] { store.conversation?.conversation.taskPlans ?? [] }
    private var subagents: [Dieter_V1_Subagent] { store.conversation?.conversation.subagents ?? [] }
    private var timelineRows: [ConversationTimelineRowContent] {
        let plansByMessage = Dictionary(grouping: plans, by: \.messageID)
        let subagentsByMessage = Dictionary(grouping: subagents, by: \.messageID)
        return timelineItems.map { item in
            ConversationTimelineRowContent(
                item: item,
                details: item.messages.enumerated().map { index, message in
                    ConversationTimelineMessageDetails(
                        id: message.id.isEmpty ? "\(item.id):\(index)" : message.id,
                        plans: plansByMessage[message.id] ?? [],
                        subagents: subagentsByMessage[message.id] ?? []
                    )
                }
            )
        }
    }
    private var conversationID: String { store.selectedCardID ?? store.selectedChatID ?? "" }
    private var draftPrompt: String {
        let card = store.selectedCard ?? store.selectedDetail?.card
        return card?.initialPromptSentAt.isEmpty == true ? (card?.initialPrompt ?? "") : ""
    }
    private var draftAttachments: [Dieter_V1_MessagePart] {
        store.conversation?.conversation.draftAttachments ?? []
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // The server delivers a bounded page, so eager layout is both
                // affordable and avoids the macOS LazyVStack/SelectionOverlay
                // anchor-translation cycle that can trap AttributeGraph in one
                // transaction indefinitely.
                VStack(alignment: .leading, spacing: 15) {
                    if store.conversationHistoryLoading {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Loading earlier messages…")
                                .font(.caption)
                                .foregroundStyle(DieterTheme.tertiary)
                        }
                        .frame(maxWidth: .infinity)
                        .id("conversation.history-loading")
                    } else if store.conversationHistoryHasMore {
                        Button("Load earlier messages · \(messages.count) of \(store.conversationHistoryTotal)") {
                            loadEarlierHistory(proxy: proxy)
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(DieterTheme.tertiary)
                        .frame(maxWidth: .infinity)
                    }

                    if messages.isEmpty {
                        EmptyConversationView(
                            standalone: store.selectedCard?.scope == "chat",
                            prompt: draftPrompt,
                            attachments: draftAttachments
                        )
                    }

                    ForEach(timelineRows) { row in
                        ConversationTimelineRow(item: row.item, details: row.details)
                            .id(row.id)
                    }

                    ForEach(plans.filter { plan in !plan.messageID.isEmpty && messages.contains(where: { $0.id == plan.messageID }) == false }, id: \.id) {
                        TaskPlanView(plan: $0)
                    }

                    let pendingTools = store.conversation?.conversation.pendingTools ?? []
                    if !pendingTools.isEmpty {
                        PendingToolGroupView(tools: pendingTools)
                    }
                    Color.clear.frame(height: 1).id(ConversationScrollBehavior.bottomID)
                }
                .padding(.horizontal, 18).padding(.vertical, 17)
            }
            .textSelection(.disabled)
            .background(DieterTheme.background)
            .task(id: conversationID) {
                historyLoadInFlight = false
                await Task.yield()
                scrollToLatest(proxy)
            }
            .onChange(of: store.conversation?.conversation.lastSeq) { _, _ in
                Task { @MainActor in
                    await Task.yield()
                    scrollToLatest(proxy)
                }
            }
        }
    }

    private func scrollToLatest(_ proxy: ScrollViewProxy) {
        proxy.scrollTo(ConversationScrollBehavior.bottomID, anchor: .bottom)
    }

    private func loadEarlierHistory(proxy: ScrollViewProxy) {
        guard !historyLoadInFlight else { return }
        historyLoadInFlight = true
        // Anchor by message id, not timeline-item id: prepending a page can
        // merge the current first item into a differently-identified tool
        // group, and a missed scroll restore leaves the viewport at offset
        // zero, which would chain-load the entire history.
        let anchorMessageID = timelineItems.first?.messages.first?.id
        Task { @MainActor in
            let loaded = await store.loadEarlierMessages()
            if loaded {
                await Task.yield()
                if let anchor = ConversationScrollBehavior.anchorItem(containing: anchorMessageID, in: timelineItems) {
                    proxy.scrollTo(anchor, anchor: .top)
                }
            }
            historyLoadInFlight = false
        }
    }
}

enum ConversationScrollBehavior {
    static let bottomID = "conversation.bottom"

    static func anchorItem(containing messageID: String?, in items: [ConversationTimelineItem]) -> String? {
        guard let messageID, !messageID.isEmpty else { return nil }
        return items.first { item in item.messages.contains { $0.id == messageID } }?.id
    }
}

private struct EmptyConversationView: View {
    let standalone: Bool
    let prompt: String
    let attachments: [Dieter_V1_MessagePart]
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left").font(.system(size: 24)).foregroundStyle(DieterTheme.shell)
            Text("Ready when you are").font(.headline)
            Text(standalone ? "Start a focused conversation in this project." : "Send this card's brief to start its local harness session.")
                .font(.caption).foregroundStyle(DieterTheme.tertiary).multilineTextAlignment(.center)
            if !prompt.isEmpty || !attachments.isEmpty {
                VStack(alignment: .leading, spacing: 9) {
                    if !prompt.isEmpty { Text(prompt).font(.callout) }
                    if !attachments.isEmpty {
                        HStack(spacing: 8) {
                            ForEach(Array(attachments.enumerated()), id: \.offset) { _, part in
                                AttachmentPreviewTile(part: part)
                            }
                        }
                    }
                }
                .padding(12).frame(maxWidth: 520, alignment: .leading)
                .background(DieterTheme.elevated, in: RoundedRectangle(cornerRadius: 10))
            }
        }.frame(maxWidth: .infinity).padding(.vertical, 55)
    }
}

struct MessageView: View {
    @Environment(DieterStore.self) private var store
    let message: Dieter_V1_UiMessage

    private var deliveryState: MessageDeliveryState {
        MessageDeliveryState(
            pending: store.isPendingMessage(message.id),
            accepted: store.isAcceptedOutboxItem(message.id),
            failed: store.isFailedOutboxItem(message.id)
        )
    }

    var body: some View {
        if message.role == "user" {
            HStack {
                Spacer(minLength: 70)
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(message.parts.enumerated()), id: \.offset) { _, part in
                        MessagePartView(messageID: message.id, part: part, inUserBubble: true)
                    }
                }
                .padding(.leading, 13).padding(.trailing, 18).padding(.vertical, 10)
                .background(DieterTheme.shellDeep.opacity(0.9), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .frame(maxWidth: 620, alignment: .trailing)
            }
            .opacity(store.isPendingMessage(message.id) ? 0.52 : 1)
            .overlay(alignment: .bottomTrailing) {
                MessageDeliveryReceipt(state: deliveryState)
                    .padding(.trailing, 4)
                    .padding(.bottom, 4)
            }
            .contextMenu {
                if deliveryState == .failed {
                    Button("Retry queued message") { Task { await store.retryOutboxItem(message.id) } }
                    Button("Discard queued message", role: .destructive) { Task { await store.discardOutboxItem(message.id) } }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(ConversationMessagePartGroup.group(message.parts, showReasoning: store.showReasoning).enumerated()), id: \.offset) { _, group in
                    if group.isToolCallGroup {
                        ToolCallGroupView(items: group.parts.map {
                            ConversationToolCall(messageID: message.id, part: $0)
                        })
                    } else if let part = group.parts.first {
                        MessagePartView(messageID: message.id, part: part, inUserBubble: false)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

enum MessageDeliveryState: Equatable {
    case local
    case accepted
    case synced
    case failed

    init(pending: Bool, accepted: Bool, failed: Bool) {
        if failed { self = .failed }
        else if !pending { self = .synced }
        else if accepted { self = .accepted }
        else { self = .local }
    }
}

private struct MessageDeliveryReceipt: View {
    let state: MessageDeliveryState

    var body: some View {
        Group {
            switch state {
            case .local:
                Image(systemName: "clock")
            case .accepted:
                Image(systemName: "checkmark")
            case .synced:
                ZStack {
                    Image(systemName: "checkmark")
                        .offset(x: -2)
                    Image(systemName: "checkmark")
                        .offset(x: 2)
                }
                .frame(width: 14, height: 10)
            case .failed:
                Image(systemName: "exclamationmark.circle.fill")
            }
        }
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(state == .failed ? DieterTheme.coral : DieterTheme.tertiary)
        .accessibilityLabel(accessibilityLabel)
        .help(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        switch state {
        case .local: "Waiting to send"
        case .accepted: "Accepted by daemon"
        case .synced: "Synced"
        case .failed: "Send failed; use the context menu to retry or discard"
        }
    }
}

struct ConversationMessagePartGroup {
    var parts: [Dieter_V1_MessagePart]
    let isToolCallGroup: Bool

    static func group(_ parts: [Dieter_V1_MessagePart], showReasoning: Bool = true) -> [ConversationMessagePartGroup] {
        var groups: [ConversationMessagePartGroup] = []
        for part in parts {
            if isHidden(part, showReasoning: showReasoning) { continue }
            let isToolCall = isToolCall(part)
            if isToolCall, groups.last?.isToolCallGroup == true {
                groups[groups.count - 1].parts.append(part)
            } else {
                groups.append(.init(parts: [part], isToolCallGroup: isToolCall))
            }
        }
        return groups
    }

    static func isToolCall(_ part: Dieter_V1_MessagePart) -> Bool {
        let type = part.type.lowercased()
        return toolTypes.contains(type) || type.hasPrefix("tool-")
    }

    // Hidden parts must not split adjacent tool calls into separate groups,
    // matching the Android timeline behavior.
    static func isHidden(_ part: Dieter_V1_MessagePart, showReasoning: Bool) -> Bool {
        if isToolCall(part) { return false }
        switch part.type.lowercased() {
        case "reasoning", "thinking":
            return !showReasoning || part.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case "step-start":
            return true
        case "image":
            return part.url.isEmpty && part.data.isEmpty
        case "file", "attachment":
            return false
        default:
            return part.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private static let toolTypes: Set<String> = ["tool", "tool_call", "dynamic-tool"]
}

extension Dieter_V1_MessagePart {
    // AI SDK static tool parts are typed "tool-<Name>" and may omit toolName.
    var effectiveToolName: String {
        if !toolName.isEmpty { return toolName }
        if type.lowercased().hasPrefix("tool-") { return String(type.dropFirst("tool-".count)) }
        return ""
    }
}

struct ConversationToolCall: Identifiable {
    let messageID: String
    let part: Dieter_V1_MessagePart

    var id: String {
        if !part.toolCallID.isEmpty { return "\(messageID):\(part.toolCallID)" }
        return "\(messageID):\(part.toolName):\(part.payloadRevision)"
    }
}

struct ConversationTimelineItem: Identifiable {
    var messages: [Dieter_V1_UiMessage]
    let isToolCallGroup: Bool
    let id: String

    var toolCalls: [ConversationToolCall] {
        messages.flatMap { message in
            message.parts.filter(ConversationMessagePartGroup.isToolCall).map {
                ConversationToolCall(messageID: message.id, part: $0)
            }
        }
    }

    static func group(_ messages: [Dieter_V1_UiMessage], showReasoning: Bool = true) -> [ConversationTimelineItem] {
        var result: [ConversationTimelineItem] = []
        for (position, message) in messages.enumerated() {
            let toolOnly = message.role.lowercased() != "user" &&
                message.parts.contains(where: ConversationMessagePartGroup.isToolCall) &&
                message.parts.allSatisfy { part in
                    ConversationMessagePartGroup.isToolCall(part) ||
                        ConversationMessagePartGroup.isHidden(part, showReasoning: showReasoning) ||
                        (part.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                            part.data.isEmpty && part.url.isEmpty && part.filename.isEmpty)
                }
            if toolOnly, result.last?.isToolCallGroup == true {
                result[result.count - 1].messages.append(message)
            } else {
                let prefix = toolOnly ? "tools" : "message"
                let sourceID = message.id.isEmpty ? "position:\(position)" : message.id
                let itemID = "\(prefix):\(sourceID)"
                result.append(.init(
                    messages: [message],
                    isToolCallGroup: toolOnly,
                    id: itemID
                ))
            }
        }
        return result
    }
}

struct ToolCallGroupSummary: Equatable {
    let edits: Int
    let commands: Int
    let otherTools: Int

    init(toolNames: [String]) {
        var edits = 0
        var commands = 0
        var otherTools = 0
        for toolName in toolNames {
            switch Self.category(for: toolName) {
            case .edit: edits += 1
            case .command: commands += 1
            case .other: otherTools += 1
            }
        }
        self.edits = edits
        self.commands = commands
        self.otherTools = otherTools
    }

    var title: String {
        var components: [String] = []
        if edits > 0 { components.append("\(edits) edit\(edits == 1 ? "" : "s")") }
        if commands > 0 { components.append("\(commands) command\(commands == 1 ? "" : "s")") }
        if otherTools > 0 { components.append("\(otherTools) tool call\(otherTools == 1 ? "" : "s")") }
        return components.isEmpty ? "Tool calls" : components.joined(separator: ", ")
    }

    private enum Category { case edit, command, other }

    private static func category(for toolName: String) -> Category {
        let normalized = toolName
            .lowercased()
            .split(whereSeparator: { $0 == "." || $0 == "/" })
            .last
            .map(String.init) ?? ""
        if ["edit", "apply_patch", "patch", "write_file", "multi_edit", "str_replace_editor"].contains(normalized) {
            return .edit
        }
        if ["bash", "shell", "command", "exec", "exec_command", "write_stdin", "terminal"].contains(normalized) {
            return .command
        }
        return .other
    }
}

struct MessagePartView: View {
    @Environment(DieterStore.self) private var store
    let messageID: String
    let part: Dieter_V1_MessagePart
    let inUserBubble: Bool
    @State private var reasoningExpanded = false

    var body: some View {
        switch part.type.lowercased() {
        case "reasoning", "thinking":
            if store.showReasoning {
                Button { withAnimation(.easeInOut(duration: 0.16)) { reasoningExpanded.toggle() } } label: {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 7) {
                            Image(systemName: reasoningExpanded ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .bold))
                            Text("Reasoning").font(.caption.weight(.medium))
                        }.foregroundStyle(DieterTheme.tertiary)
                        if reasoningExpanded {
                            Text(part.text).font(.caption).foregroundStyle(DieterTheme.subtle).lineSpacing(3)
                                .padding(.leading, 15)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain)
            }
        case "tool", "tool-call", "tool_call", "dynamic-tool":
            ToolCallView(messageID: messageID, part: part)
        case "image":
            if let image = attachmentImage {
                Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 340).clipShape(RoundedRectangle(cornerRadius: 9))
            } else if let url = URL(string: part.url), !part.url.isEmpty {
                AsyncImage(url: url) { $0.resizable().scaledToFit() } placeholder: { ProgressView() }
                    .frame(maxHeight: 340).clipShape(RoundedRectangle(cornerRadius: 9))
            }
        case "file", "attachment":
            if part.mediaType.hasPrefix("image/"), let image = attachmentImage {
                Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 340).clipShape(RoundedRectangle(cornerRadius: 9))
            } else {
                HStack(spacing: 9) {
                    Image(systemName: "doc.fill").foregroundStyle(DieterTheme.shell)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(part.filename.isEmpty ? "Attachment" : part.filename).font(.caption.weight(.semibold))
                        Text(part.mediaType).font(.caption2).foregroundStyle(DieterTheme.tertiary)
                    }
                }
                .padding(10).background(DieterTheme.surface, in: RoundedRectangle(cornerRadius: 8))
            }
        default:
            if !part.text.isEmpty {
                Text(markdown(part.text))
                    .font(.system(size: 13))
                    .foregroundStyle(inUserBubble ? Color.white : DieterTheme.text)
                    .lineSpacing(4)
            }
        }
    }

    private func markdown(_ string: String) -> AttributedString {
        (try? AttributedString(markdown: string, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(string)
    }

    private var attachmentImage: NSImage? {
        if !part.data.isEmpty { return NSImage(data: part.data) }
        guard let marker = part.url.range(of: ";base64,") else { return nil }
        return Data(base64Encoded: String(part.url[marker.upperBound...])).flatMap(NSImage.init(data:))
    }
}

struct ToolCallView: View {
    @Environment(DieterStore.self) private var store
    let messageID: String
    let part: Dieter_V1_MessagePart
    @State private var expanded = false
    @State private var output: Dieter_V1_ToolOutput?
    @State private var loading = false

    private var completed: Bool { ["completed", "success", "done"].contains(part.state.lowercased()) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(DieterTheme.tertiary)
                    Image(systemName: completed ? "checkmark.circle" : "terminal").font(.system(size: 11, weight: .medium)).foregroundStyle(completed ? DieterTheme.eyes : DieterTheme.shell)
                    Text(part.effectiveToolName.isEmpty ? "Command" : part.effectiveToolName).font(.caption.monospaced().weight(.medium)).lineLimit(1)
                    Spacer()
                    if loading { ProgressView().controlSize(.mini) }
                    else { Text(part.state.isEmpty ? (part.hasOutput_p ? "output available" : "tool") : part.state.replacingOccurrences(of: "_", with: " ")).font(.caption2).foregroundStyle(DieterTheme.tertiary) }
                }
                .padding(.horizontal, 10).frame(height: 34)
                .contentShape(Rectangle())
            }.buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 9) {
                    let input = output.map { String(decoding: $0.inputJson, as: UTF8.self) } ?? part.inputPreview
                    let result = output.map { String(decoding: $0.outputJson, as: UTF8.self) } ?? part.outputPreview
                    if !input.isEmpty { CodeBlock(title: "Input", value: input) }
                    if !result.isEmpty { CodeBlock(title: "Output", value: result) }
                    let error = output?.errorText ?? part.errorText
                    if !error.isEmpty { Text(error).font(.caption.monospaced()).foregroundStyle(DieterTheme.coral) }
                }
                .padding(.horizontal, 10).padding(.bottom, 10)
            }
        }
        .background(DieterTheme.surface.opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
        .onChange(of: expanded) { _, value in if value && output == nil { Task { await load() } } }
    }

    private func load() async {
        guard !part.toolCallID.isEmpty, let cardID = store.selectedCardID ?? store.selectedChatID, let rpc = store.rpc else { return }
        loading = true
        var request = Dieter_V1_GetToolOutputRequest()
        request.cardID = cardID; request.messageID = messageID; request.toolCallID = part.toolCallID; request.revision = part.payloadRevision
        do { output = try await rpc.toolOutput(request) } catch { store.show(error) }
        loading = false
    }
}

private struct ToolCallGroupView: View {
    let items: [ConversationToolCall]
    @State private var expanded = false

    private var title: String { ToolCallGroupSummary(toolNames: items.map(\.part.effectiveToolName)).title }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button { withAnimation(.easeInOut(duration: 0.16)) { expanded.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(DieterTheme.tertiary)
                    Text(title)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(DieterTheme.subtle)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(expanded ? "Collapse" : "Expand") \(title)")

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(items) { item in
                        ToolCallView(messageID: item.messageID, part: item.part)
                    }
                }
                .padding(.leading, 14)
            }
        }
    }
}

struct CodeBlock: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.system(size: 9, weight: .bold)).tracking(0.7).foregroundStyle(DieterTheme.tertiary)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(value).font(.system(size: 11, design: .monospaced)).foregroundStyle(DieterTheme.subtle).lineSpacing(3)
            }
        }
        .padding(10).background(DieterTheme.input, in: RoundedRectangle(cornerRadius: 7))
    }
}

private struct PendingToolRow: View {
    let tool: Dieter_V1_PendingTool
    var body: some View {
        HStack(spacing: 9) {
            ProgressView().controlSize(.mini)
            Text(tool.toolName.isEmpty ? "Running command" : tool.toolName).font(.caption.monospaced())
            Spacer(); Text("Running…").font(.caption2).foregroundStyle(DieterTheme.primary)
        }
        .padding(.horizontal, 11).frame(height: 36)
        .background(DieterTheme.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(DieterTheme.primary.opacity(0.18)))
    }
}

private struct PendingToolGroupView: View {
    let tools: [Dieter_V1_PendingTool]
    @State private var expanded = false

    private var title: String { ToolCallGroupSummary(toolNames: tools.map(\.toolName)).title }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button { withAnimation(.easeInOut(duration: 0.16)) { expanded.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(DieterTheme.tertiary)
                    Text(title).font(.caption.weight(.medium)).foregroundStyle(DieterTheme.subtle)
                    ProgressView().controlSize(.mini)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(expanded ? "Collapse" : "Expand") running \(title)")

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(tools, id: \.id) { tool in
                        PendingToolRow(tool: tool)
                    }
                }
                .padding(.leading, 14)
            }
        }
    }
}

struct TaskPlanView: View {
    let plan: Dieter_V1_TaskPlan
    @State private var expanded = true

    private var tasks: [Dieter_V1_TaskPlanItem] { plan.phases.flatMap(\.tasks) }
    private var completed: Int { tasks.filter { $0.status == "completed" }.count }

    var body: some View {
        VStack(spacing: 0) {
            Button { withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: "checklist").font(.system(size: 11)).foregroundStyle(DieterTheme.shell)
                    Text("Progress").font(.caption.weight(.semibold))
                    Spacer()
                    Text("\(completed) of \(tasks.count)").font(.caption2).foregroundStyle(DieterTheme.tertiary)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(DieterTheme.tertiary)
                }.padding(.horizontal, 12).frame(height: 38)
            }.buttonStyle(.plain)

            if expanded {
                if !plan.explanation.isEmpty {
                    Text(plan.explanation).font(.caption).foregroundStyle(DieterTheme.subtle)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.bottom, 9)
                }
                ForEach(Array(tasks.enumerated()), id: \.offset) { _, task in
                    Divider().overlay(DieterTheme.border)
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: planIcon(task.status))
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(planColor(task.status)).frame(width: 14)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(task.status == "in_progress" && !task.activeForm.isEmpty ? task.activeForm : task.content)
                                .font(.caption).foregroundStyle(task.status == "pending" ? DieterTheme.subtle : DieterTheme.text)
                            if !task.blocker.isEmpty { Text(task.blocker).font(.caption2).foregroundStyle(DieterTheme.coral) }
                        }
                        Spacer()
                    }.padding(.horizontal, 12).padding(.vertical, 10)
                }
            }
        }
        .background(DieterTheme.surface.opacity(0.72), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(DieterTheme.border))
    }

    private func planIcon(_ status: String) -> String {
        status == "completed" ? "checkmark.circle.fill" : status == "in_progress" ? "circle.dotted.circle.fill" : "circle"
    }
    private func planColor(_ status: String) -> Color {
        status == "completed" ? DieterTheme.eyes : status == "in_progress" ? DieterTheme.primary : DieterTheme.tertiary
    }
}

private struct SubagentTimelineGroup: View {
    let agents: [Dieter_V1_Subagent]
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button { withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() } } label: {
                HStack(spacing: 7) {
                    Image(systemName: "person.2.fill").font(.system(size: 10)).foregroundStyle(DieterTheme.shell)
                    Text("\(agents.count) subagent\(agents.count == 1 ? "" : "s")").font(.caption.weight(.semibold))
                    Spacer(); Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 8)).foregroundStyle(DieterTheme.tertiary)
                }
                .padding(.horizontal, 10).frame(height: 31)
                .background(DieterTheme.raised, in: RoundedRectangle(cornerRadius: 7))
            }.buttonStyle(.plain)
            if expanded {
                VStack(spacing: 7) { ForEach(agents, id: \.id) { SubagentTimelineCard(agent: $0) } }.padding(.leading, 14)
            }
        }
    }
}

private struct SubagentTimelineCard: View {
    let agent: Dieter_V1_Subagent
    @State private var expanded = false

    var body: some View {
        VStack(spacing: 0) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 9) {
                    Image(systemName: agent.status == "completed" ? "checkmark" : "circle.dotted")
                        .foregroundStyle(runtimeColor(agent.status)).frame(width: 13)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(agent.name.isEmpty ? (agent.agentType.isEmpty ? "Subagent" : agent.agentType) : agent.name).font(.caption.weight(.semibold)).lineLimit(1)
                        Text([agent.provider, agent.model].filter { !$0.isEmpty }.joined(separator: "/")).font(.caption2).foregroundStyle(DieterTheme.tertiary)
                    }
                    Spacer(); Text(agent.status.uppercased()).font(.system(size: 9, weight: .bold)).tracking(0.8).foregroundStyle(runtimeColor(agent.status))
                    Image(systemName: expanded ? "chevron.up" : "chevron.right").font(.system(size: 8)).foregroundStyle(DieterTheme.tertiary)
                }.padding(11)
            }.buttonStyle(.plain)
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    Text(agent.assignment.isEmpty ? agent.task : agent.assignment).font(.caption).foregroundStyle(DieterTheme.subtle)
                    if !agent.recentOutput.isEmpty { CodeBlock(title: "Recent output", value: agent.recentOutput.joined(separator: "\n")) }
                }.padding(.horizontal, 11).padding(.bottom, 11)
            }
        }
        .background(DieterTheme.surface, in: RoundedRectangle(cornerRadius: 9))
    }
}

struct SubagentsView: View {
    @Environment(DieterStore.self) private var store
    private var agents: [Dieter_V1_Subagent] { store.conversation?.conversation.subagents ?? [] }
    private var running: Int { agents.filter { ["running", "pending"].contains($0.status) }.count }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 11) {
                HStack {
                    Text("\(agents.count) subagent\(agents.count == 1 ? "" : "s")").font(.headline)
                    if running > 0 { Text("• \(running) running").font(.caption.weight(.semibold)).foregroundStyle(DieterTheme.primary) }
                    Spacer()
                    if running > 0, let card = store.selectedCard {
                        Button { Task { await store.cancel(card) } } label: { Label("Stop all", systemImage: "stop.fill") }
                            .buttonStyle(.bordered).tint(DieterTheme.coral)
                    }
                }.padding(.bottom, 4)

                if agents.isEmpty {
                    ContentUnavailableView("No subagents", systemImage: "person.2", description: Text("Delegated work will appear here in real time."))
                        .padding(.vertical, 40)
                }
                ForEach(agents, id: \.id) { SubagentDetailCard(agent: $0) }
                if !agents.isEmpty { Text("Updates stream while connected").font(.caption2).foregroundStyle(DieterTheme.tertiary).padding(.top, 3) }
            }.padding(18)
        }.background(DieterTheme.background)
    }
}

private struct SubagentDetailCard: View {
    let agent: Dieter_V1_Subagent
    private var fraction: Double {
        guard agent.contextWindow > 0 else { return agent.status == "completed" ? 1 : 0 }
        return min(1, Double(agent.contextTokens) / Double(agent.contextWindow))
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: agent.status == "completed" ? "checkmark.circle" : "circle.dotted")
                        .foregroundStyle(runtimeColor(agent.status))
                    Text(agent.name.isEmpty ? (agent.agentType.isEmpty ? "Subagent" : agent.agentType) : agent.name).font(.subheadline.weight(.semibold))
                    Spacer(); Text(duration(agent.durationMs)).font(.caption2).foregroundStyle(DieterTheme.tertiary)
                }
                Text(agent.activity.isEmpty ? (agent.assignment.isEmpty ? agent.task : agent.assignment) : agent.activity)
                    .font(.caption).foregroundStyle(DieterTheme.subtle).lineLimit(2)
                if agent.status == "running" {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(DieterTheme.raised).frame(height: 3)
                            Capsule().fill(DieterTheme.primary).frame(width: max(16, geometry.size.width * fraction), height: 3)
                        }
                    }.frame(height: 3)
                }
            }.padding(13)
            Divider().overlay(DieterTheme.border)
            HStack {
                Text(agent.name.isEmpty ? String(agent.id.prefix(8)) : agent.name).font(.caption.weight(.semibold))
                Text([agent.provider, agent.model].filter { !$0.isEmpty }.joined(separator: "/")).font(.caption2).foregroundStyle(DieterTheme.tertiary)
                Spacer(); StatusPill(text: agent.status, color: runtimeColor(agent.status))
            }.padding(.horizontal, 13).frame(height: 36)
        }
        .background(DieterTheme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(agent.status == "running" ? DieterTheme.primary.opacity(0.5) : .clear))
    }

    private func duration(_ milliseconds: Int64) -> String {
        guard milliseconds > 0 else { return "" }
        let seconds = milliseconds / 1_000
        return seconds >= 60 ? "\(seconds / 60)m \(seconds % 60)s" : "\(seconds)s"
    }
}

struct CommentsView: View {
    @Environment(DieterStore.self) private var store
    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if (store.selectedDetail?.comments ?? []).isEmpty {
                        ContentUnavailableView("No Dieter comments yet", systemImage: "text.bubble", description: Text("Comments are non-triggering annotations and never resume the harness session."))
                            .padding(.vertical, 45)
                    }
                    ForEach(store.selectedDetail?.comments ?? [], id: \.id) { comment in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(comment.author.name.isEmpty ? comment.author.kind.capitalized : comment.author.name).font(.caption.weight(.semibold))
                                Spacer(); Text(comment.createdAt).font(.caption2).foregroundStyle(DieterTheme.tertiary)
                            }
                            Text(comment.body).font(.system(size: 13)).textSelection(.enabled).lineSpacing(3)
                        }
                        .padding(12).background(DieterTheme.surface, in: RoundedRectangle(cornerRadius: 9))
                    }
                }.padding(18)
            }
            Divider().overlay(DieterTheme.border)
            HStack(spacing: 9) {
                TextField("Add a non-triggering comment…", text: $store.commentText).textFieldStyle(.plain)
                    .padding(.horizontal, 11).frame(height: 36).background(DieterTheme.input, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(DieterTheme.border))
                Button("Comment") { Task { await store.addComment() } }.buttonStyle(DieterPrimaryButtonStyle()).disabled(store.commentText.isEmpty)
            }.padding(12).background(DieterTheme.sidebar)
        }
    }
}


private struct ConversationComposer: View {
    @Environment(DieterStore.self) private var store
    @Binding var fileImporterPresented: Bool
    @FocusState private var composerFocused: Bool
    @State private var attachmentDropTargeted = false

    private var harness: Dieter_V1_Harness? { store.harnessCatalog.harnesses.first { $0.id == store.composerProvider } }
    private var model: Dieter_V1_HarnessModel? { harness?.models.first { $0.id == store.composerModel } }
    private var working: Bool { ["running", "starting"].contains(store.conversation?.conversation.status ?? "") }
    private var hasDraft: Bool {
        !store.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !store.composerAttachments.isEmpty
    }
    private var composerEditorHeight: CGFloat {
        let lines = store.composerText.split(separator: "\n", omittingEmptySubsequences: false).count
        return min(126, 54 + CGFloat(max(0, lines - 1)) * 18)
    }

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 8) {
            if let queue = store.conversation?.conversation.queue, !queue.isEmpty {
                HStack(spacing: 7) {
                    Image(systemName: "clock").font(.caption)
                    Text("\(queue.count) queued message\(queue.count == 1 ? "" : "s")").font(.caption)
                    Spacer(); Text("Delivered after this turn").font(.caption2)
                }.foregroundStyle(DieterTheme.amber)
            }
            VStack(alignment: .leading, spacing: 0) {
                TextField("Message the local agent…", text: $store.composerText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .lineLimit(1...5)
                    .focused($composerFocused)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .accessibilityIdentifier("conversation.composer")
                    .onKeyPress(.return, phases: .down) { press in
                        if !ComposerReturnPolicy.sendsMessage(shiftPressed: press.modifiers.contains(.shift)) {
                            return .ignored
                        }
                        if hasDraft { Task { await store.sendComposer() } }
                        return .handled
                    }
                    .frame(height: composerEditorHeight, alignment: .topLeading)

                if !store.composerAttachments.isEmpty {
                    AttachmentPreviewStrip(attachments: $store.composerAttachments)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 6)
                }

                HStack(alignment: .center, spacing: 9) {
                    ViewThatFits(in: .horizontal) {
                        composerSettings(showContext: true)
                        composerSettings(showContext: false)
                    }
                    .frame(maxWidth: .infinity)

                    Button {
                        if working, let card = store.selectedCard { Task { await store.cancel(card) } }
                        else { Task { await store.sendComposer() } }
                    } label: {
                        Image(systemName: working ? "stop.fill" : "arrow.up")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(working || hasDraft ? Color.white : DieterTheme.tertiary)
                            .frame(width: 36, height: 36)
                            .background(
                                working ? DieterTheme.coral : (hasDraft ? DieterTheme.primary : DieterTheme.elevated),
                                in: Circle()
                            )
                            .overlay(Circle().stroke(Color.white.opacity(working || hasDraft ? 0.14 : 0.055)))
                            .shadow(color: working ? DieterTheme.coral.opacity(0.2) : DieterTheme.shellDeep.opacity(hasDraft ? 0.3 : 0), radius: 9, y: 3)
                    }
                    .buttonStyle(.plain)
                    .disabled(!working && !hasDraft)
                    .help(working ? "Stop agent" : "Send message")
                    .accessibilityIdentifier("conversation.send")
                }
                .padding(.leading, 10)
                .padding(.trailing, 9)
                .padding(.bottom, 9)

            }
            .background(attachmentDropTargeted ? DieterTheme.shellDeep.opacity(0.12) : DieterTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(attachmentDropTargeted ? DieterTheme.shell : (composerFocused ? DieterTheme.shellDeep.opacity(0.55) : DieterTheme.border), lineWidth: attachmentDropTargeted ? 1.5 : 1)
            }
            .shadow(color: Color.black.opacity(0.24), radius: 12, y: 5)
            .animation(.easeOut(duration: 0.16), value: composerFocused)
            .animation(.easeOut(duration: 0.12), value: attachmentDropTargeted)
            .attachmentDropTarget(isTargeted: $attachmentDropTargeted) { providers in
                store.addPastedAttachments(providers)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(DieterTheme.sidebar)
    }

    private func composerSettings(showContext: Bool) -> some View {
        HStack(spacing: 7) {
            Button { fileImporterPresented = true } label: { Image(systemName: "paperclip") }
                .buttonStyle(DieterIconButtonStyle())
                .help("Attach files")

            Button { store.showReasoning.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 10, weight: .semibold))
                    Capsule().fill(store.showReasoning ? DieterTheme.shellDeep : DieterTheme.elevated).frame(width: 25, height: 14)
                        .overlay(alignment: store.showReasoning ? .trailing : .leading) { Circle().fill(.white).frame(width: 10, height: 10).padding(2) }
                }
                .foregroundStyle(store.showReasoning ? DieterTheme.shell : DieterTheme.subtle)
                .padding(.horizontal, 9).frame(height: 28)
                .background(DieterTheme.surface, in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .help(store.showReasoning ? "Hide reasoning" : "Show reasoning")

            Menu {
                ForEach(store.harnessCatalog.harnesses, id: \.id) { item in
                    Button(item.name) {
                        store.composerProvider = item.id
                        store.composerModel = item.defaultModel
                        store.composerEffort = item.models.first(where: { $0.id == item.defaultModel })?.defaultEffort ?? ""
                        store.composerProviderOptions = ProviderOptionValues.defaults(for: item)
                    }
                }
            } label: {
                DieterChipLabel(title: harness?.name ?? store.composerProvider, symbol: "cpu")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Menu {
                ForEach(harness?.models ?? [], id: \.id) { item in
                    Button(item.name) {
                        store.composerModel = item.id
                        store.composerEffort = item.defaultEffort
                    }
                }
            } label: {
                DieterChipLabel(title: model?.name ?? store.composerModel, symbol: "terminal", maximumTitleWidth: 190)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            if let efforts = model?.efforts, !efforts.isEmpty {
                Menu {
                    ForEach(efforts, id: \.self) { value in
                        Button(value.capitalized) { store.composerEffort = value }
                    }
                } label: {
                    DieterChipLabel(title: store.composerEffort.isEmpty ? "Default" : store.composerEffort.capitalized, symbol: "sparkles")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            ProviderOptionChips(options: harness?.options ?? [], values: Binding(
                get: { store.composerProviderOptions },
                set: { store.composerProviderOptions = $0 }
            ))

            Spacer(minLength: 0)
            if showContext, let usage = ConversationContextUsage.latest(
                messages: store.conversation?.conversation.messages ?? [],
                fallbackWindow: Int64(model?.contextWindow ?? 0)
            ) {
                ContextUsageIndicator(usage: usage)
            }
        }
    }
}

struct ConversationContextUsage: Equatable {
    let used: Int64
    let window: Int64

    var fraction: Double { window > 0 ? min(1, max(0, Double(used) / Double(window))) : 0 }
    var percentage: Int { Int((fraction * 100).rounded()) }

    static func latest(messages: [Dieter_V1_UiMessage], fallbackWindow: Int64) -> ConversationContextUsage? {
        for message in messages.reversed() where !message.metadataJson.isEmpty {
            guard let root = try? JSONSerialization.jsonObject(with: message.metadataJson) as? [String: Any] else { continue }
            let usage = root["usage"] as? [String: Any]
            let used = integer(usage?["totalTokens"]) ?? integer(usage?["inputTokens"])
            let window = integer(root["contextWindowTokens"]) ?? (fallbackWindow > 0 ? fallbackWindow : nil)
            if let used, let window, window > 0 { return .init(used: used, window: window) }
        }
        return nil
    }

    private static func integer(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        if let text = value as? String { return Int64(text) }
        return nil
    }
}

private struct ContextUsageIndicator: View {
    let usage: ConversationContextUsage

    var body: some View {
        ZStack {
            Circle().stroke(DieterTheme.raised, lineWidth: 3)
            Circle().trim(from: 0, to: usage.fraction)
                .stroke(usage.fraction > 0.85 ? DieterTheme.amber : DieterTheme.shell, style: .init(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(usage.percentage)").font(.system(size: 8, weight: .bold, design: .rounded)).foregroundStyle(DieterTheme.subtle)
        }
        .frame(width: 28, height: 28)
        .help("Context used: \(compact(usage.used)) of \(compact(usage.window)) tokens (\(usage.percentage)%)")
        .accessibilityLabel("Context used \(usage.percentage) percent")
    }

    private func compact(_ value: Int64) -> String {
        value >= 1_000_000 ? String(format: "%.1fM", Double(value) / 1_000_000) : value >= 1_000 ? "\(value / 1_000)k" : "\(value)"
    }
}
