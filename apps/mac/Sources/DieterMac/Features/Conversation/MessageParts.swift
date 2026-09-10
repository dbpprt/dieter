import DieterAPI
import SwiftUI
import UniformTypeIdentifiers

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
        let normalized =
            toolName
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
    @Environment(ConversationContext.self) private var context
    let messageID: String
    let part: Dieter_V1_MessagePart
    let inUserBubble: Bool
    @State private var reasoningExpanded = false

    var body: some View {
        switch part.type.lowercased() {
        case "reasoning", "thinking":
            if context.showReasoning {
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) { reasoningExpanded.toggle() }
                } label: {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 7) {
                            Image(systemName: reasoningExpanded ? "chevron.down" : "chevron.right").font(
                                .system(size: 8, weight: .bold))
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
                previewableAttachmentImage(image)
            } else if let url = URL(string: part.url), !part.url.isEmpty {
                AsyncImage(url: url) {
                    $0.resizable().scaledToFit()
                } placeholder: {
                    ProgressView()
                }
                .frame(maxHeight: 340).clipShape(RoundedRectangle(cornerRadius: 9))
            }
        case "file", "attachment":
            if part.mediaType.hasPrefix("image/"), let image = attachmentImage {
                previewableAttachmentImage(image)
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
                ConversationMarkdownView(source: part.text, inUserBubble: inUserBubble)
            }
        }
    }

    private var attachmentImage: NSImage? {
        AttachmentImagePayload.image(from: part)
    }

    private func previewableAttachmentImage(_ image: NSImage) -> some View {
        AttachmentImageButton(part: part, image: image, maximumHeight: 340)
    }
}

struct AttachmentImageButton: View {
    let part: Dieter_V1_MessagePart
    let image: NSImage
    let maximumHeight: CGFloat
    @State private var previewPresented = false

    var body: some View {
        Button {
            previewPresented = true
        } label: {
            Image(nsImage: image)
                .resizable().scaledToFit().frame(maxHeight: maximumHeight)
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(.white)
                        .padding(7).background(Color.black.opacity(0.55), in: Circle()).padding(7)
                }
        }
        .buttonStyle(.plain)
        .help("Preview \(part.filename.isEmpty ? "image" : part.filename)")
        .accessibilityLabel("Preview \(part.filename.isEmpty ? "image attachment" : part.filename)")
        .sheet(isPresented: $previewPresented) {
            AttachmentImagePreview(part: part, image: image)
        }
    }
}

struct ToolCallView: View {
    @Environment(ConversationContext.self) private var context
    let messageID: String
    let part: Dieter_V1_MessagePart
    @State private var expanded = false
    @State private var output: Dieter_V1_ToolOutput?
    @State private var loading = false

    private var completed: Bool {
        ["completed", "success", "done", "output-available"].contains(part.state.lowercased())
    }
    private var needsAttention: Bool { ConversationActivityGrouping.needsAttention(part) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .bold))
                        .foregroundStyle(DieterTheme.tertiary)
                    Image(
                        systemName: needsAttention
                            ? "exclamationmark.circle" : (completed ? "checkmark.circle" : "terminal")
                    ).font(
                        .system(size: 11, weight: .medium)
                    ).foregroundStyle(
                        needsAttention ? DieterTheme.amber : (completed ? DieterTheme.eyes : DieterTheme.shell))
                    Text(part.effectiveToolName.isEmpty ? "Command" : part.effectiveToolName).font(
                        .caption.monospaced().weight(.medium)
                    ).lineLimit(1)
                    Spacer()
                    if loading {
                        ProgressView().controlSize(.mini)
                    } else {
                        Text(
                            part.state.isEmpty
                                ? (part.hasOutput_p ? "output available" : "tool")
                                : part.state.replacingOccurrences(of: "_", with: " ")
                        ).font(.caption2).foregroundStyle(DieterTheme.tertiary)
                    }
                }
                .padding(.horizontal, 10).frame(height: 34)
                .contentShape(Rectangle())
            }.buttonStyle(.plain)

            if needsAttention, !part.errorText.isEmpty {
                Text(part.errorText).font(.caption.monospaced()).foregroundStyle(DieterTheme.coral)
                    .padding(.horizontal, 10).padding(.bottom, 10)
            }
            if expanded {
                VStack(alignment: .leading, spacing: 9) {
                    let input = output.map { String(decoding: $0.inputJson, as: UTF8.self) } ?? part.inputPreview
                    let result = output.map { String(decoding: $0.outputJson, as: UTF8.self) } ?? part.outputPreview
                    if !input.isEmpty { CodeBlock(title: "Input", value: input) }
                    if !result.isEmpty { CodeBlock(title: "Output", value: result) }
                    let error = output?.errorText ?? part.errorText
                    if !error.isEmpty, !(needsAttention && error == part.errorText) {
                        Text(error).font(.caption.monospaced()).foregroundStyle(DieterTheme.coral)
                    }
                }
                .padding(.horizontal, 10).padding(.bottom, 10)
            }
        }
        .background(DieterTheme.surface.opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
        .onChange(of: expanded) { _, value in if value && output == nil { Task { await load() } } }
    }

    private func load() async {
        guard !part.toolCallID.isEmpty else { return }
        loading = true
        do {
            output = try await context.toolOutput(
                messageID: messageID,
                toolCallID: part.toolCallID,
                revision: part.payloadRevision
            )
        } catch { context.show(error) }
        loading = false
    }
}

struct ToolCallGroupView: View {
    let items: [ConversationToolCall]
    @State private var expanded = false

    private var title: String { ToolCallGroupSummary(toolNames: items.map(\.part.effectiveToolName)).title }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) { expanded.toggle() }
            } label: {
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
            Text(title.uppercased()).font(.system(size: 9, weight: .bold)).tracking(0.7).foregroundStyle(
                DieterTheme.tertiary)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(value).font(.system(size: 11, design: .monospaced)).foregroundStyle(DieterTheme.subtle)
                    .lineSpacing(3)
            }
        }
        .padding(10).background(DieterTheme.input, in: RoundedRectangle(cornerRadius: 7))
    }
}

struct PendingToolRow: View {
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

struct PendingToolGroupView: View {
    let tools: [Dieter_V1_PendingTool]
    @State private var expanded = false

    private var title: String { ToolCallGroupSummary(toolNames: tools.map(\.toolName)).title }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) { expanded.toggle() }
            } label: {
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
