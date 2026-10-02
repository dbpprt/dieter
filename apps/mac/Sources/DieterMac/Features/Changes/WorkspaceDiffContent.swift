import AppKit
import DieterAPI
import Observation
import SwiftUI

@MainActor @Observable
final class DiffHorizontalScrollState {
    private(set) var offset: CGFloat = 0

    func update(_ value: CGFloat) {
        guard abs(value - offset) > 0.25 else { return }
        offset = value
    }
}

struct DiffScrollOffsetObserver: NSViewRepresentable {
    var onChange: (CGFloat) -> Void

    final class Anchor: NSView {
        var onChange: (CGFloat) -> Void = { _ in }
        private weak var clip: NSClipView?
        private var lastOffset: CGFloat = -1
        private var connectionScheduled = false
        private var deliveryScheduled = false
        private var pendingOffset: CGFloat?
        private var active = true

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); scheduleConnection() }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); scheduleConnection() }

        func scheduleConnection() {
            guard active, !connectionScheduled else { return }
            connectionScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.connectionScheduled = false
                self.connect()
            }
        }

        private func connect() {
            guard active else { return }
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
            pendingOffset = offset
            guard !deliveryScheduled else { return }
            deliveryScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.deliveryScheduled = false
                guard let pendingOffset = self.pendingOffset else { return }
                self.pendingOffset = nil
                self.onChange(pendingOffset)
            }
        }

        func detach() {
            NotificationCenter.default.removeObserver(self)
            clip = nil
            lastOffset = -1
            pendingOffset = nil
        }

        func dismantle() {
            active = false
            detach()
        }
    }

    func makeNSView(context: Context) -> Anchor { let view = Anchor(); view.onChange = onChange; return view }
    func updateNSView(_ view: Anchor, context: Context) { view.onChange = onChange; view.scheduleConnection() }
    static func dismantleNSView(_ view: Anchor, coordinator: ()) { view.dismantle() }
}

/// A diff as the core laid it out: folded context, hunks with their counts,
/// and side-by-side pairs; this view keeps scrolling and expanded folds.
struct WorkspaceDiffContent: View {
    let layout: WorkspaceDiffLayout
    let addComment: (UnifiedDiffLine) -> Void
    let loadMore: () -> Void
    var loadingMore = false
    var reviewSection: String? = nil

    @State private var horizontalScroll = DiffHorizontalScrollState()
    @State private var expandedFolds: Set<Int> = []
    #if DIETER_UI_SMOKE
        @State private var smokeTargetID = UUID()
    #endif

    private var split: Bool { layout.split }

    var body: some View {
        GeometryReader { viewport in
            let contentWidth =
                split
                ? viewport.size.width
                    + max(0, CGFloat(layout.maxColumns) * 7.3 + 78 - viewport.size.width / 2)
                : viewport.size.width
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(layout.rows) { row in
                        WorkspaceDiffPositionedRow(split: split, scroll: horizontalScroll) {
                            diffRow(
                                row,
                                viewportWidth: max(0, viewport.size.width),
                                horizontalScroll: horizontalScroll
                            )
                            .frame(width: split ? viewport.size.width : nil, alignment: .leading)
                        }
                    }
                    if layout.more {
                        Button("Load the rest of this diff") { loadMore() }
                            .disabled(loadingMore)
                            .buttonStyle(DieterSecondaryButtonStyle()).padding(12)
                    } else if !layout.note.isEmpty {
                        Text(layout.note)
                            .font(.system(size: 11)).foregroundStyle(DieterTheme.tertiary)
                            .padding(12)
                    }
                }
                .frame(
                    minWidth: max(0, contentWidth),
                    minHeight: max(0, viewport.size.height),
                    alignment: .topLeading
                )
                .background(DiffScrollOffsetObserver { horizontalScroll.update($0) })
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onChange(of: layout.revision, initial: true) {
            expandedFolds = []
            #if DIETER_UI_SMOKE
                if NativeUISmokeTargets.enabled {
                    NativeUISmokeTargets.diffOwner = smokeTargetID
                    NativeUISmokeTargets.diffText = layout.texts.joined(separator: "\n")
                    NativeUISmokeTargets.diffSplit = split
                }
            #endif
        }
        .onDisappear {
            #if DIETER_UI_SMOKE
                // A view that replaced this one, e.g. after a resize, may already show its diff.
                if NativeUISmokeTargets.diffOwner == smokeTargetID {
                    NativeUISmokeTargets.diffText = ""
                    NativeUISmokeTargets.diffSplit = nil
                }
            #endif
        }
    }

    @ViewBuilder private func diffRow(
        _ row: WorkspaceDiffRow,
        viewportWidth: CGFloat,
        horizontalScroll: DiffHorizontalScrollState
    ) -> some View {
        switch row {
        case .line(let line):
            WorkspaceDiffLineRow(
                line: line.line,
                comments: line.comments,
                canComment: line.commentable,
                minimumWidth: viewportWidth,
                addComment: { addComment(line.line) }
            )
        case .pair(let pair):
            WorkspaceSplitPairRow(pair: pair, width: viewportWidth, horizontalScroll: horizontalScroll)
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
        case .hunk(let id, let text, let skipped, let additions, let deletions):
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
                    if additions > 0 || deletions > 0 {
                        HStack(spacing: 5) {
                            Text("+\(additions)").foregroundStyle(DieterTheme.diffAddition)
                            Text("−\(deletions)").foregroundStyle(DieterTheme.coral)
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
                            WorkspaceSplitPairRow(pair: pair, width: viewportWidth, horizontalScroll: horizontalScroll)
                        }
                    } else {
                        ForEach(lines) { line in
                            WorkspaceDiffLineRow(
                                line: line.line,
                                comments: line.comments,
                                canComment: line.commentable,
                                minimumWidth: viewportWidth,
                                addComment: { addComment(line.line) }
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

}

#if DIETER_UI_SMOKE
    extension WorkspaceDiffLayout {
        /// The shown code lines, for smoke checks of the diff.
        var texts: [String] { rows.flatMap(\.texts) }
    }

    extension WorkspaceDiffRow {
        /// The row's code lines, for smoke checks of the shown diff.
        var texts: [String] {
            switch self {
            case .line(let line): [line.line.text]
            case .pair(let pair): [pair.old?.text, pair.new?.text].compactMap { $0 }
            case .file(_, let path): [path]
            case .hunk(_, let text, _, _, _): [text]
            case .fold(_, _, let lines, _): lines.map(\.line.text)
            }
        }
    }
#endif

private struct WorkspaceDiffPositionedRow<Content: View>: View {
    let split: Bool
    let scroll: DiffHorizontalScrollState
    let content: Content

    init(split: Bool, scroll: DiffHorizontalScrollState, @ViewBuilder content: () -> Content) {
        self.split = split
        self.scroll = scroll
        self.content = content()
    }

    var body: some View {
        content.offset(x: split ? scroll.offset : 0)
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
    let horizontalScroll: DiffHorizontalScrollState

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
                .offset(x: -horizontalScroll.offset)
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
