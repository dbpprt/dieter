import AppKit
import SwiftUI

struct ConversationMarkdownView: View {
    let source: String
    let inUserBubble: Bool
    @State private var preparedBlocks: [ConversationMarkdownBlock]?
    @State private var preparedSource = ""
    @State private var showingFullText = false

    private var foreground: Color {
        inUserBubble ? DieterTheme.userMessageForeground : DieterTheme.text
    }

    var body: some View {
        let preview = ConversationRenderCache.preview(source)
        let blocks = ConversationRenderCache.cachedBlocks(preview) ?? (preparedSource == preview ? preparedBlocks : nil)
        VStack(alignment: .leading, spacing: 7) {
            if let blocks {
                ForEach(Array(blocks.prefix(80).enumerated()), id: \.offset) { _, block in
                    blockView(block)
                }
                if preview != source || blocks.count > 80 {
                    Button("Open full text…") { showingFullText = true }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("conversation.full-text").smokeTarget("conversation.full-text")
                }
            } else {
                LoadFeedback(title: "Preparing text…", compact: true)
            }
        }
        .task(id: preview) {
            guard ConversationRenderCache.cachedBlocks(preview) == nil else { return }
            guard let next = try? await BackgroundPreparation.run({ try ConversationRenderCache.prepare(preview) }),
                !Task.isCancelled
            else { return }
            preparedBlocks = next
            preparedSource = preview
        }
        .sheet(isPresented: $showingFullText) {
            FullConversationText(source: source)
        }
    }

    @ViewBuilder
    private func blockView(_ block: ConversationMarkdownBlock) -> some View {
        switch block {
        case .paragraph(let text):
            inlineText(text)
                .font(.system(size: 13))
                .lineSpacing(4)
        case .heading(let level, let text):
            inlineText(text)
                .font(.system(size: level == 1 ? 17 : 15, weight: .semibold))
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("•")
                inlineText(text)
                    .font(.system(size: 13))
                    .lineSpacing(4)
            }
        case .code(let text):
            ScrollView(.horizontal) {
                Text(text)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(DieterTheme.subtle)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 9)
            }
            .background(DieterTheme.raised, in: RoundedRectangle(cornerRadius: 9))
        case .table(let table):
            ConversationMarkdownTableView(table: table, foreground: foreground)
        }
    }

    private func inlineText(_ source: String) -> Text {
        Text(ConversationRenderCache.markdown(source)).foregroundStyle(foreground)
    }
}

private struct ConversationMarkdownTableView: View {
    let table: ConversationMarkdownTable
    let foreground: Color

    @State private var page = 0
    @State private var columnPage = 0
    private let pageSize = 20
    private let columnsPerPage = 8
    private var visibleColumns: Range<Int> {
        let start = min(columnPage * columnsPerPage, table.headers.count)
        return start..<min(start + columnsPerPage, table.headers.count)
    }

    var body: some View {
        ScrollView(.horizontal) {
            VStack(spacing: 0) {
                row(table.headers, header: true)
                ForEach(Array(table.rows.enumerated()).dropFirst(page * pageSize).prefix(pageSize), id: \.offset) {
                    _, values in
                    row(values, header: false)
                }
            }
            .background(DieterTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(DieterTheme.border)
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 4) {
                if table.rows.count > pageSize {
                    HStack {
                        Button("Previous rows") { page = max(0, page - 1) }.disabled(page == 0)
                        Text(
                            "Rows \(page * pageSize + 1)–\(min(table.rows.count, (page + 1) * pageSize)) of \(table.rows.count)"
                        )
                        .font(.caption)
                        .smokeTarget("conversation.table.rows.\(page)")
                        Button("Next rows") { page += 1 }.disabled((page + 1) * pageSize >= table.rows.count)
                            .accessibilityIdentifier("conversation.table.next-rows").smokeTarget(
                                "conversation.table.next-rows")
                    }.padding(.vertical, 5)
                }
                if table.headers.count > columnsPerPage {
                    HStack {
                        Button("Previous columns") { columnPage = max(0, columnPage - 1) }.disabled(columnPage == 0)
                        Text(
                            "Columns \(visibleColumns.lowerBound + 1)–\(visibleColumns.upperBound) of \(table.headers.count)"
                        ).font(.caption)
                        Button("Next columns") { columnPage += 1 }.disabled(
                            visibleColumns.upperBound == table.headers.count)
                    }
                }
            }
        }
        .onChange(of: table.rows.count) { _, count in page = min(page, max(0, (count - 1) / pageSize)) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Markdown table, \(table.headers.count) columns, \(table.rows.count) rows")
    }

    private func row(_ values: [String], header: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(visibleColumns, id: \.self) { column in
                Text(ConversationRenderCache.markdown(column < values.count ? values[column] : ""))
                    .font(.system(size: 12, weight: header ? .semibold : .regular))
                    .foregroundStyle(foreground)
                    .multilineTextAlignment(textAlignment(column))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(width: table.columnWidths[column], alignment: frameAlignment(column))
            }
        }
        .background(header ? DieterTheme.raised : DieterTheme.surface)
        .overlay(alignment: .bottom) { Divider().foregroundStyle(DieterTheme.border) }
    }

    private func textAlignment(_ column: Int) -> TextAlignment {
        switch table.alignments[column] {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    private func frameAlignment(_ column: Int) -> Alignment {
        switch table.alignments[column] {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}

/// AppKit lays out long plain text incrementally. Opening the full source is an
/// explicit action and does not inflate every message in the eager timeline.
private struct FullConversationText: View {
    let source: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Full message").font(.headline); Spacer();
                Button("Done") { dismiss() }.accessibilityIdentifier("conversation.full-text.done").smokeTarget(
                    "conversation.full-text.done")
            }.padding(14)
            FullConversationTextEditor(source: source)
        }.frame(minWidth: 650, minHeight: 500)
    }
}

private struct FullConversationTextEditor: NSViewRepresentable {
    let source: String
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        if let text = scroll.documentView as? NSTextView {
            text.isEditable = false
            text.isSelectable = true
            text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            text.string = source
        }
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {}
}
