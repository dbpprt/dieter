import DieterAPI
import SwiftUI
import UniformTypeIdentifiers

/// A prose, attachment, or other part of a message.
struct MessagePartView: View {
    let messageID: String
    let part: Dieter_V1_MessagePart
    let inUserBubble: Bool

    var body: some View {
        switch part.type.lowercased() {
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

/// A tool call with the status and title the core gives its step; its full
/// input and output load when expanded.
struct ToolCallView: View {
    @Environment(ConversationContext.self) private var context
    let messageID: String
    let part: Dieter_V1_MessagePart
    let step: ClientTimelineStep
    @State private var expanded = false
    @State private var output: Dieter_V1_ToolOutput?
    @State private var loading = false

    private var completed: Bool { step.toolStatus == .completed }
    private var needsAttention: Bool { [.failed, .needsApproval, .denied].contains(step.toolStatus) }

    private var statusLabel: String {
        switch step.toolStatus {
        case .running: "running"
        case .completed: "completed"
        case .failed: "failed"
        case .needsApproval: "needs approval"
        case .denied: "denied"
        default: "tool"
        }
    }

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
                    Text(step.toolTitle).font(
                        .caption.monospaced().weight(.medium)
                    ).lineLimit(1)
                    Spacer()
                    if loading {
                        ProgressView().controlSize(.mini)
                    } else {
                        Text(statusLabel).font(.caption2).foregroundStyle(DieterTheme.tertiary)
                    }
                }
                .padding(.horizontal, 10).frame(height: 34)
                .contentShape(Rectangle())
            }.buttonStyle(.plain)

            if !step.routine, !part.errorText.isEmpty {
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
                    if !error.isEmpty, !(!step.routine && error == part.errorText) {
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

/// Running tool calls the transcript has not finished, under the core's summary.
struct PendingToolGroupView: View {
    let title: String
    let tools: [Dieter_V1_PendingTool]
    @State private var expanded = false

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
