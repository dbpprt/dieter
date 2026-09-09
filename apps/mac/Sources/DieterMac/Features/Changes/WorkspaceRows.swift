import AppKit
import DieterAPI
import SwiftUI

struct WorkspaceSectionHeader: View {
    let title: String
    let count: Int
    var additions: Int32? = nil
    var deletions: Int32? = nil

    var body: some View {
        HStack(spacing: 6) {
            Text(title.uppercased()).font(DieterFont.sectionLabel).tracking(0.45).foregroundStyle(DieterTheme.tertiary)
            Text("\(count)").font(.system(size: 9, weight: .bold)).foregroundStyle(DieterTheme.tertiary)
            Spacer()
            if let additions, let deletions { WorkspaceDeltaLabel(additions: additions, deletions: deletions) }
        }
        .frame(height: 22)
    }
}

struct WorkspaceDeltaLabel: View {
    let additions: Int32
    let deletions: Int32

    var body: some View {
        HStack(spacing: 6) {
            Text("+\(additions)").foregroundStyle(DieterTheme.diffAddition)
            Text("−\(deletions)").foregroundStyle(DieterTheme.coral)
        }
        .font(.system(size: 10, weight: .semibold, design: .monospaced)).fixedSize()
    }
}

struct WorkspaceEmptyRow: View {
    let symbol: String
    let title: String
    var body: some View {
        Label(title, systemImage: symbol).font(.system(size: 10)).foregroundStyle(DieterTheme.tertiary)
            .padding(.horizontal, 8).frame(height: 34)
    }
}

struct WorkspaceFileRow: View {
    let file: Dieter_V1_ChangedFile
    let selected: Bool
    var viewed = false
    let action: () -> Void

    private var deleted: Bool {
        WorkspaceChangePresentation.badge(status: file.status, conflicted: file.conflicted, untracked: file.untracked)
            == "D"
    }

    private var tint: Color {
        if file.conflicted { return DieterTheme.coral }
        if file.untracked { return DieterTheme.amber }
        return DieterTheme.shell
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Text(
                    WorkspaceChangePresentation.badge(
                        status: file.status, conflicted: file.conflicted, untracked: file.untracked)
                )
                .font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(tint)
                .frame(width: 20, height: 20).background(tint.opacity(0.11), in: RoundedRectangle(cornerRadius: 5))
                VStack(alignment: .leading, spacing: 2) {
                    Text(WorkspaceChangePresentation.filename(file.path))
                        .font(.system(size: 11, weight: .medium))
                        .strikethrough(deleted)
                        .opacity(viewed && !selected ? 0.55 : 1)
                        .lineLimit(1)
                    let directory = WorkspaceChangePresentation.directory(file.path)
                    if !directory.isEmpty {
                        Text(directory).font(.system(size: 9, design: .monospaced)).foregroundStyle(
                            DieterTheme.tertiary
                        ).lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 5)
                if viewed {
                    Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(
                        DieterTheme.diffAddition)
                }
                WorkspaceDeltaLabel(additions: file.additions, deletions: file.deletions)
            }
            .padding(.horizontal, 8).frame(minHeight: 42)
            .background(selected ? DieterTheme.selection : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(
            "\(WorkspaceChangePresentation.title(status: file.status, conflicted: file.conflicted, untracked: file.untracked)): \(file.path)"
        )
    }
}

struct WorkspaceCommitRow: View {
    let commit: Dieter_V1_WorkspaceCommit
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text(String(commit.shortSha.prefix(7)))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(DieterTheme.shell)
                VStack(alignment: .leading, spacing: 2) {
                    Text(commit.subject).font(.system(size: 11, weight: .medium)).lineLimit(2)
                    HStack(spacing: 6) {
                        WorkspaceDeltaLabel(additions: commit.additions, deletions: commit.deletions)
                        if !commit.authoredAt.isEmpty {
                            Text(WorkspaceRelativeTime.compact(commit.authoredAt))
                                .font(.system(size: 9)).foregroundStyle(DieterTheme.tertiary)
                        }
                    }
                }
                Spacer(minLength: 5)
            }
            .padding(.horizontal, 11).padding(.vertical, 8)
            .background(selected ? DieterTheme.selection : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct PullRequestStateBadge: View {
    let label: String
    let tone: PullRequestPresentation.Tone

    var body: some View {
        Text(label)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 7).frame(height: 17)
            .background(color.opacity(0.13), in: Capsule())
    }

    private var color: Color {
        switch tone {
        case .positive: DieterTheme.diffAddition
        case .active: DieterTheme.shell
        case .warning: DieterTheme.amber
        case .critical: DieterTheme.coral
        case .neutral: DieterTheme.subtle
        }
    }
}

struct PullRequestSignalLabel: View {
    let signal: PullRequestPresentation.Signal

    var body: some View {
        HStack(spacing: 4) {
            if signal.tone == .active {
                DieterActivityIndicator(color: DieterTheme.shell, size: 9)
            } else {
                Image(systemName: symbol).font(.system(size: 8, weight: .bold))
            }
            Text(signal.text)
        }
        .font(.system(size: 9, weight: .medium))
        .foregroundStyle(color)
        .lineLimit(1)
        .fixedSize()
    }

    private var symbol: String {
        switch signal.tone {
        case .positive: "checkmark"
        case .warning: "clock"
        case .critical: "xmark"
        default: "circle"
        }
    }

    private var color: Color {
        switch signal.tone {
        case .positive: DieterTheme.diffAddition
        case .active: DieterTheme.shell
        case .warning: DieterTheme.amber
        case .critical: DieterTheme.coral
        case .neutral: DieterTheme.subtle
        }
    }
}

struct WorkspaceDiffLineRow: View {
    let line: UnifiedDiffLine
    let comments: [Dieter_V1_ChangeComment]
    let canComment: Bool
    let minimumWidth: CGFloat
    let addComment: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                lineNumber(line.oldLine).frame(width: 42, alignment: .trailing)
                lineNumber(line.newLine).frame(width: 42, alignment: .trailing)
                Group {
                    if canComment {
                        Button(action: addComment) {
                            Image(systemName: "plus").font(.system(size: 8, weight: .bold)).frame(width: 22, height: 20)
                        }
                        .buttonStyle(.plain).foregroundStyle(DieterTheme.shell).opacity(
                            hovering || !comments.isEmpty ? 1 : 0)
                    } else {
                        Text(line.kind == .addition ? "+" : line.kind == .deletion ? "−" : " ")
                            .frame(width: 22, height: 23)
                    }
                }
                Text(codeText).textSelection(.enabled).fixedSize(horizontal: true, vertical: false)
                    .padding(.leading, 5).padding(.trailing, 12)
            }
            .font(.system(size: 12, design: .monospaced)).foregroundStyle(foreground)
            .frame(minWidth: minimumWidth, minHeight: 23, alignment: .topLeading)
            .background(background)
            ForEach(comments, id: \.id) { comment in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "text.bubble.fill").foregroundStyle(DieterTheme.shell)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(comment.body).font(.system(size: 11)).textSelection(.enabled)
                        Text(comment.author.isEmpty ? comment.createdAt : "\(comment.author) · \(comment.createdAt)")
                            .font(.system(size: 9)).foregroundStyle(DieterTheme.tertiary)
                    }
                }
                .padding(9).padding(.leading, 88).frame(minWidth: minimumWidth, alignment: .leading).background(
                    DieterTheme.raised)
            }
        }
        .onHover { hovering = $0 }
    }

    private func lineNumber(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "").foregroundStyle(DieterTheme.tertiary)
            .padding(.trailing, 7).frame(maxHeight: .infinity).background(DieterTheme.sidebar.opacity(0.72))
    }

    private var codeText: String {
        let text = canComment || line.kind == .header || line.kind == .hunk ? line.text : String(line.text.dropFirst())
        return text.isEmpty ? " " : text.replacingOccurrences(of: "\t", with: "    ")
    }

    private var background: Color {
        switch line.kind {
        case .addition: DieterTheme.diffAddition.opacity(0.14)
        case .deletion: DieterTheme.coral.opacity(0.14)
        case .hunk: DieterTheme.selection
        case .header: DieterTheme.sidebar
        case .context: .clear
        }
    }

    private var foreground: Color {
        switch line.kind {
        case .addition: DieterTheme.diffAddition
        case .deletion: DieterTheme.coral
        case .header, .hunk: DieterTheme.shell
        case .context: DieterTheme.text
        }
    }
}

// MARK: - Merge sheet
