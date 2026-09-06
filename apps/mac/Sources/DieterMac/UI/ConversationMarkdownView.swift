import SwiftUI

struct ConversationMarkdownView: View {
    let source: String
    let inUserBubble: Bool

    private var foreground: Color {
        inUserBubble ? DieterTheme.userMessageForeground : DieterTheme.text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(ConversationRenderCache.blocks(source).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
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

    private var columnWidths: [CGFloat] {
        table.headers.indices.map { column in
            let values = [table.headers[column]] + table.rows.map { row in
                column < row.count ? row[column] : ""
            }
            let longest = values.map(\.count).max() ?? 0
            return CGFloat(min(max(longest, 8), 28) * 7 + 24)
        }
    }

    var body: some View {
        ScrollView(.horizontal) {
            VStack(spacing: 0) {
                row(table.headers, header: true)
                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, values in
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
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Markdown table, \(table.headers.count) columns, \(table.rows.count) rows")
    }

    private func row(_ values: [String], header: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(table.headers.indices, id: \.self) { column in
                Text(ConversationRenderCache.markdown(column < values.count ? values[column] : ""))
                    .font(.system(size: 12, weight: header ? .semibold : .regular))
                    .foregroundStyle(foreground)
                    .multilineTextAlignment(textAlignment(column))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(width: columnWidths[column], alignment: frameAlignment(column))
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
