import AppKit
import SwiftUI

/// A diff as the core laid it out: folded context, hunks with their counts,
/// and side-by-side pairs. Every line wraps to the pane, so nothing scrolls
/// sideways. The rows are a native table that lays out only what is on
/// screen, so a diff of thousands of lines opens, scrolls, and resizes smoothly.
/// Equatable over what it shows: its actions are the same for one diff, so a
/// parent's unrelated update never reaches the table.
struct WorkspaceDiffContent: View, Equatable {
    let layout: WorkspaceDiffLayout
    let addComment: (UnifiedDiffLine) -> Void
    let loadMore: () -> Void
    var loadingMore = false
    var reviewSection: String? = nil

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.layout == rhs.layout && lhs.loadingMore == rhs.loadingMore && lhs.reviewSection == rhs.reviewSection
    }

    var body: some View {
        // Reading the theme here repaints the table when it changes.
        WorkspaceDiffTable(
            layout: layout, loadingMore: loadingMore, reviewSection: reviewSection, palette: .current,
            addComment: addComment, loadMore: loadMore
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The diff's colors, resolved from the theme as the diff renders.
struct WorkspaceDiffPalette: Equatable {
    var text: NSColor
    var subtle: NSColor
    var tertiary: NSColor
    var addition: NSColor
    var deletion: NSColor
    var shell: NSColor
    var reviewAccent: NSColor
    var border: NSColor
    var hairline: NSColor
    var additionFill: NSColor
    var deletionFill: NSColor
    var hunkLineFill: NSColor
    var headerFill: NSColor
    var gutterFill: NSColor
    var foldFill: NSColor
    var missingFill: NSColor
    var commentFill: NSColor
    var badgeFill: NSColor
    var stagedBadgeFill: NSColor

    @MainActor static var current: Self {
        Self(
            text: NSColor(DieterTheme.text), subtle: NSColor(DieterTheme.subtle),
            tertiary: NSColor(DieterTheme.tertiary), addition: NSColor(DieterTheme.diffAddition),
            deletion: NSColor(DieterTheme.coral), shell: NSColor(DieterTheme.shell),
            reviewAccent: NSColor(DieterTheme.reviewAccent), border: NSColor(DieterTheme.border),
            hairline: NSColor(DieterTheme.border.opacity(0.5)),
            additionFill: NSColor(DieterTheme.diffAddition.opacity(0.14)),
            deletionFill: NSColor(DieterTheme.coral.opacity(0.14)), hunkLineFill: NSColor(DieterTheme.selection),
            headerFill: NSColor(DieterTheme.sidebar), gutterFill: NSColor(DieterTheme.sidebar.opacity(0.72)),
            foldFill: NSColor(DieterTheme.raised.opacity(0.55)), missingFill: NSColor(DieterTheme.raised.opacity(0.35)),
            commentFill: NSColor(DieterTheme.raised), badgeFill: NSColor(DieterTheme.elevated),
            stagedBadgeFill: NSColor(DieterTheme.reviewAccent.opacity(0.12)))
    }
}

/// The diff's end: loading its next page, or why the rest is not shown.
struct WorkspaceDiffEnd: View {
    let more: Bool
    let loading: Bool
    let note: String
    let loadMore: () -> Void

    var body: some View {
        Group {
            if more {
                Button("Load the rest of this diff", action: loadMore)
                    .disabled(loading)
                    .buttonStyle(DieterBarButtonStyle(size: 30))
            } else {
                Text(note).font(.system(size: 11)).foregroundStyle(DieterTheme.tertiary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
