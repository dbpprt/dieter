import AppKit
import DieterAPI
import SwiftUI

struct DiffScrollOffsetObserver: NSViewRepresentable {
    var onChange: (CGFloat) -> Void

    final class Anchor: NSView {
        var onChange: (CGFloat) -> Void = { _ in }
        private weak var clip: NSClipView?
        private var lastOffset: CGFloat = -1

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); scheduleConnection() }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); scheduleConnection() }

        func scheduleConnection() {
            DispatchQueue.main.async { [weak self] in self?.connect() }
        }

        private func connect() {
            guard let next = enclosingScrollView?.contentView, next !== clip else { return }
            detach()
            clip = next
            next.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: next)
            scrolled()
        }

        @objc private func scrolled() {
            let offset = max(0, clip?.bounds.minX ?? 0)
            guard abs(offset - lastOffset) > 0.25 else { return }
            lastOffset = offset
            DispatchQueue.main.async { [weak self] in self?.onChange(offset) }
        }

        func detach() {
            NotificationCenter.default.removeObserver(self)
            clip = nil
            lastOffset = -1
        }
    }

    func makeNSView(context: Context) -> Anchor { let view = Anchor(); view.onChange = onChange; return view }
    func updateNSView(_ view: Anchor, context: Context) { view.onChange = onChange; view.scheduleConnection() }
    static func dismantleNSView(_ view: Anchor, coordinator: ()) { view.detach() }
}

struct WorkspaceDiffContent: View {
    let diff: Dieter_V1_FileDiff
    let split: Bool
    let comments: [Dieter_V1_ChangeComment]
    let canComment: Bool
    let addComment: (UnifiedDiffLine) -> Void
    let loadMore: () -> Void
    var loadingMore = false
    var reviewSection: String? = nil

    @State private var projection = WorkspaceDiffProjection()
    @State private var builtKey = ""
    @State private var horizontalOffset: CGFloat = 0
    @State private var expandedFolds: Set<Int> = []

    private var buildKey: String {
        let commentRevision = comments.map { "\($0.id):\($0.revision)" }.joined(separator: ",")
        return
            "\(diff.projectID)|\(diff.cardID)|\(diff.section)|\(diff.path)|\(diff.commitSha)|\(diff.revision)|\(split)|\(diff.nextOffset)|\(diff.totalBytes)|\(commentRevision)"
    }

    var body: some View {
        GeometryReader { viewport in
            let contentWidth =
                split
                ? viewport.size.width
                    + max(0, CGFloat(projection.maximumCodeColumns) * 7.3 + 78 - viewport.size.width / 2)
                : viewport.size.width
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(projection.rows) { row in
                        diffRow(row, viewportWidth: max(0, viewport.size.width))
                            .frame(width: split ? viewport.size.width : nil, alignment: .leading)
                            .offset(x: split ? horizontalOffset : 0)
                    }
                    if diff.truncated {
                        Button("Load the rest of this diff") { loadMore() }
                            .disabled(loadingMore)
                            .buttonStyle(DieterSecondaryButtonStyle()).padding(12)
                    }
                }
                .frame(
                    minWidth: max(0, contentWidth),
                    minHeight: max(0, viewport.size.height),
                    alignment: .topLeading
                )
                .background(DiffScrollOffsetObserver { horizontalOffset = $0 })
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .overlay {
            if builtKey.isEmpty { LoadFeedback(title: "Preparing diff…") }
        }
        .task(id: buildKey) {
            guard builtKey != buildKey else { return }
            let key = buildKey
            let patch = diff.patch
            let path = diff.path
            let commitSHA = diff.commitSha
            let split = split
            let comments = comments
            guard
                let next = try? await BackgroundPreparation.run({
                    WorkspaceDiffProjection.build(
                        patch: patch,
                        path: path,
                        commitSHA: commitSHA,
                        split: split,
                        comments: comments
                    )
                })
            else { return }
            guard !Task.isCancelled, buildKey == key else { return }
            projection = next
            builtKey = key
            expandedFolds = []
            #if DIETER_UI_SMOKE
                if NativeUISmokeTargets.enabled {
                    NativeUISmokeTargets.diffText = patch; NativeUISmokeTargets.diffSplit = split
                }
            #endif
        }
        .onDisappear {
            #if DIETER_UI_SMOKE
                NativeUISmokeTargets.diffText = ""
                NativeUISmokeTargets.diffSplit = nil
            #endif
        }
    }

    @ViewBuilder private func diffRow(_ row: WorkspaceDiffRow, viewportWidth: CGFloat) -> some View {
        switch row {
        case .line(let line):
            WorkspaceDiffLineRow(
                line: line,
                comments: commentsFor(line),
                canComment: canComment && (line.newLine ?? line.oldLine) != nil,
                minimumWidth: viewportWidth,
                addComment: { addComment(line) }
            )
        case .pair(let pair):
            WorkspaceSplitPairRow(pair: pair, width: viewportWidth, horizontalOffset: horizontalOffset)
        case .file(let id, let path):
            HStack(spacing: 7) {
                Image(systemName: "doc.text").font(.system(size: 9, weight: .semibold)).foregroundStyle(
                    DieterTheme.subtle)
                Text(path).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(
                    DieterTheme.text)
                Spacer(minLength: 0)
            }
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(minWidth: viewportWidth, minHeight: 30, alignment: .leading)
            .background(DieterTheme.sidebar)
            .id(id)
        case .hunk(let id, let text, let skipped):
            VStack(spacing: 0) {
                if skipped > 0 {
                    WorkspaceUnchangedSeparator(count: skipped, width: viewportWidth)
                }
                HStack(spacing: 10) {
                    Text(text)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(DieterTheme.subtle)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if let delta = projection.hunkDeltas[id] {
                        HStack(spacing: 5) {
                            Text("+\(delta.additions)").foregroundStyle(DieterTheme.diffAddition)
                            Text("−\(delta.deletions)").foregroundStyle(DieterTheme.coral)
                        }.font(.system(size: 10, design: .monospaced))
                    }
                    if let reviewSection {
                        Text(reviewSection.uppercased())
                            .font(.system(size: 9, weight: .semibold)).tracking(0.4)
                            .foregroundStyle(
                                reviewSection == "staged" ? DieterTheme.reviewAccent : DieterTheme.tertiary
                            )
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(
                                reviewSection == "staged"
                                    ? DieterTheme.reviewAccent.opacity(0.12) : DieterTheme.elevated,
                                in: RoundedRectangle(cornerRadius: 3))
                    }
                }
                .padding(.horizontal, 14)
                .frame(minWidth: viewportWidth, minHeight: 32, alignment: .leading)
                .background(DieterTheme.sidebar)
                .overlay(alignment: .leading) {
                    if reviewSection == "staged" { DieterTheme.reviewAccent.frame(width: 2) }
                }
                .overlay(alignment: .bottom) { Divider().overlay(DieterTheme.border.opacity(0.5)) }
            }
            .id(id)
            .smokeTarget("workspace-diff.hunk.\(id)")
        case .fold(let id, let count, let lines, let pairs):
            if expandedFolds.contains(id) {
                VStack(spacing: 0) {
                    foldButton(id: id, count: count, expanded: true, width: viewportWidth)
                    if split {
                        ForEach(pairs) { pair in
                            WorkspaceSplitPairRow(pair: pair, width: viewportWidth, horizontalOffset: horizontalOffset)
                        }
                    } else {
                        ForEach(lines) { line in
                            WorkspaceDiffLineRow(
                                line: line,
                                comments: commentsFor(line),
                                canComment: canComment && (line.newLine ?? line.oldLine) != nil,
                                minimumWidth: viewportWidth,
                                addComment: { addComment(line) }
                            )
                        }
                    }
                }
            } else {
                foldButton(id: id, count: count, expanded: false, width: viewportWidth)
            }
        }
    }

    private func foldButton(id: Int, count: Int, expanded: Bool, width: CGFloat) -> some View {
        Button {
            if expanded { expandedFolds.remove(id) } else { expandedFolds.insert(id) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .bold))
                Text(expanded ? "Hide \(count) unchanged lines" : "\(count) unchanged lines")
                    .font(.system(size: 10, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(DieterTheme.subtle)
            .padding(.horizontal, 12)
            .frame(minWidth: width, minHeight: 24, alignment: .leading)
            .background(DieterTheme.raised.opacity(0.55))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(expanded ? "Collapse this unchanged region" : "Expand this unchanged region")
    }

    private func commentsFor(_ line: UnifiedDiffLine) -> [Dieter_V1_ChangeComment] {
        projection.commentsByLine[WorkspaceDiffCommentKey(line)] ?? []
    }
}

struct WorkspaceUnchangedSeparator: View {
    let count: Int
    let width: CGFloat

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "ellipsis").font(.system(size: 8, weight: .bold))
            Text("\(count) unchanged lines").font(.system(size: 10, weight: .medium))
            Spacer(minLength: 0)
        }
        .foregroundStyle(DieterTheme.tertiary)
        .padding(.horizontal, 12)
        .frame(minWidth: width, minHeight: 22, alignment: .leading)
    }
}

struct WorkspaceSplitPairRow: View {
    let pair: WorkspaceSplitPair
    let width: CGFloat
    var horizontalOffset: CGFloat = 0

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            side(line: pair.old, number: pair.old.flatMap(\.oldLine), addition: false)
            Rectangle().fill(DieterTheme.border).frame(width: 1)
            side(line: pair.new, number: pair.new.flatMap(\.newLine), addition: true)
        }
        .frame(minWidth: width, minHeight: 23, alignment: .topLeading)
    }

    @ViewBuilder private func side(line: UnifiedDiffLine?, number: Int?, addition: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(number.map(String.init) ?? "")
                .foregroundStyle(DieterTheme.tertiary)
                .padding(.trailing, 7)
                .frame(width: 42, alignment: .trailing)
                .frame(maxHeight: .infinity)
                .background(DieterTheme.sidebar.opacity(0.72))
            Text(line?.kind == .addition ? "+" : line?.kind == .deletion ? "−" : " ")
                .foregroundStyle(foreground(line)).frame(width: 20)
            Text(displayText(line))
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(foreground(line))
                .padding(.leading, 6).padding(.trailing, 8)
                .offset(x: -horizontalOffset)
                .frame(width: max(0, (width - 1) / 2 - 62), alignment: .topLeading)
                .clipped()
        }
        .font(.system(size: 12, design: .monospaced))
        .frame(width: max(0, (width - 1) / 2), alignment: .topLeading)
        .frame(minHeight: 23)
        .background(background(line, addition: addition))
    }

    private func displayText(_ line: UnifiedDiffLine?) -> String {
        guard let line else { return " " }
        let code = String(line.text.dropFirst()).replacingOccurrences(of: "\t", with: "    ")
        return code.isEmpty ? " " : code
    }

    private func foreground(_ line: UnifiedDiffLine?) -> Color {
        switch line?.kind {
        case .addition: DieterTheme.diffAddition
        case .deletion: DieterTheme.coral
        default: DieterTheme.text
        }
    }

    private func background(_ line: UnifiedDiffLine?, addition: Bool) -> Color {
        switch line?.kind {
        case .addition: DieterTheme.diffAddition.opacity(0.14)
        case .deletion: DieterTheme.coral.opacity(0.14)
        case .context: .clear
        default: DieterTheme.raised.opacity(0.35)
        }
    }
}

// MARK: - Navigator rows
