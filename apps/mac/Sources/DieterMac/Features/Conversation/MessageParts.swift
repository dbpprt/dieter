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
                .padding(10).dieterTile(radius: 10)
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
    @Environment(\.conversationToolsGrouped) private var grouped
    let messageID: String
    let part: Dieter_V1_MessagePart
    let step: ClientTimelineStep
    @State private var expanded = false
    @State private var output: Dieter_V1_ToolOutput?
    @State private var loading = false
    @State private var hovering = false

    private var completed: Bool { step.toolStatus == .completed }
    private var needsAttention: Bool { step.toolAttention }

    private var statusLabel: String { step.toolStatusLabel }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(
                        systemName: needsAttention
                            ? "exclamationmark.triangle" : (completed ? "checkmark" : "terminal")
                    )
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(
                        needsAttention
                            ? DieterTheme.attention : (completed ? DieterTheme.running : DieterTheme.tertiary)
                    )
                    .frame(width: 14)
                    Text(step.toolTitle)
                        .font(DieterFont.mono)
                        .foregroundStyle(DieterTheme.text.opacity(0.9))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 6)
                    if loading {
                        ProgressView().controlSize(.mini)
                    } else {
                        Text(statusLabel).font(DieterFont.monoSmall).foregroundStyle(DieterTheme.tertiary)
                    }
                    Image(systemName: "chevron.right").font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(DieterTheme.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .opacity(hovering || expanded ? 1 : 0)
                }
                .padding(.horizontal, 8).frame(height: grouped ? 26 : 32)
                .background(
                    hovering ? DieterTheme.tileHover : .clear,
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }

            if !step.routine, !part.errorText.isEmpty {
                Text(part.errorText).font(DieterFont.mono).foregroundStyle(DieterTheme.failed)
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
                        Text(error).font(DieterFont.mono).foregroundStyle(DieterTheme.failed)
                    }
                }
                .padding(.leading, 30).padding(.trailing, 8).padding(.vertical, 6)
            }
        }
        .padding(grouped ? 0 : 2)
        .background {
            if !grouped {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(DieterTheme.inset)
            }
        }
        .overlay {
            if !grouped {
                RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(DieterTheme.insetRim)
            }
        }
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
        .padding(10)
        .background(DieterTheme.inset, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct PendingToolRow: View {
    let tool: Dieter_V1_PendingTool
    var body: some View {
        HStack(spacing: 9) {
            ProgressView().controlSize(.mini)
            Text(tool.toolName.isEmpty ? "Running command" : tool.toolName).font(DieterFont.mono)
            Spacer(); Text("Running…").font(DieterFont.monoSmall).foregroundStyle(DieterTheme.running)
        }
        .padding(.horizontal, 8).frame(height: 26)
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
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(DieterTheme.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text(title).font(.system(size: 12)).foregroundStyle(DieterTheme.tertiary)
                    ProgressView().controlSize(.mini)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(expanded ? "Collapse" : "Expand") running \(title)")

            if expanded {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(tools, id: \.id) { tool in
                        PendingToolRow(tool: tool)
                    }
                }
                .padding(.horizontal, 6).padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .dieterInset(radius: 10)
                .padding(.leading, 14)
            }
        }
    }
}
