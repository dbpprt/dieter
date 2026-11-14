import DieterClientAPI
import DieterCore
import SwiftUI

struct InboxFeed: View {
    @Environment(DieterStore.self) private var store
    let onOpen: (InboxActivityEntry) -> Void
    @State private var query = ""
    @State private var projectID = ""
    @State private var hours = 1
    @State private var visibleLimit = 20
    @State private var newTaskPresented = false
    @State private var rulesPresented = false

    var body: some View {
        let entries = store.inboxEntries
        let projects = store.projects.filter { !$0.archived }
        let selectedProject = projects.contains { $0.id == projectID } ? projectID : ""
        let filtered = filteredEntries(entries, projectID: selectedProject)
        let live = store.workspaceIsLive
        // With no recorded sync time, use recorded activity rather than advancing
        // a cached running interval to the wall clock.
        let cachedNow =
            store.lastSyncedAt ?? entries.map(\.row.atMillis).max().flatMap { Date(epochMillis: $0) } ?? .distantPast
        VStack(spacing: 0) {
            header(entries: filtered, selectedProject: selectedProject)
            TimelineView(.periodic(from: .now, by: 15)) { clock in
                let now = live ? clock.date : cachedNow
                let intervals = timeline(filtered, now: now)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 7) {
                        timelineSummary(intervals: intervals, live: live)
                        if filtered.isEmpty {
                            emptyState(filtered: !query.isEmpty || !selectedProject.isEmpty)
                        } else {
                            section("Pinned", id: "pinned", entries: filtered.filter { $0.row.pinned })
                            section(
                                "Running", id: "running",
                                entries: filtered.filter { $0.section == .running && !$0.row.pinned })
                            section(
                                "Needs attention", id: "needs-you",
                                entries: filtered.filter { $0.section == .attention && !$0.row.pinned })
                            section(
                                "Recent", id: "recent",
                                entries: filtered.filter { $0.section == .recent && !$0.row.pinned })
                        }
                    }
                    .padding(.leading, 14).padding(.trailing, 6).padding(.vertical, 6)
                }
                // Each tick reaches only the rows' ages, not the rows.
                .environment(\.inboxNow, now)
                .accessibilityIdentifier("inbox.feed").e2eTarget("inbox.feed")
            }
        }
        .foregroundStyle(DieterTheme.text)
        .ignoresSafeArea(.container, edges: .top)
        .sheet(isPresented: $rulesPresented) { InboxRulesSheet().environment(store) }
        .onChange(of: query) { _, _ in visibleLimit = 20 }
        .onChange(of: projectID) { _, _ in visibleLimit = 20 }
        .onChange(of: hours) { _, _ in visibleLimit = 20 }
        .onChange(of: store.activeGateway.credentialID) { _, _ in
            query = ""; projectID = ""; visibleLimit = 20
        }
    }

    private func filteredEntries(_ entries: [InboxActivityEntry], projectID: String) -> [InboxActivityEntry] {
        entries.filter { entry in
            // The core's rule matches every row for a blank query.
            (projectID.isEmpty || entry.row.card.projectID == projectID)
                && (query.isEmpty
                    || SharedRules.shared.activityMatches(
                        query: query, title: entry.row.card.title, projectName: entry.row.projectName,
                        boardName: entry.row.boardName))
        }
    }

    /// Each entry's bar on the last `hours`, in the feed's order; entries
    /// outside the window have none.
    private func timeline(_ entries: [InboxActivityEntry], now: Date) -> [InboxTimelineBar] {
        entries.compactMap { entry in
            let bar = ClientActivityTimelineBar(
                rules: SharedRules.shared.timelineBar(
                    startMillis: entry.row.startedAtMillis, atMillis: entry.row.atMillis, running: entry.running,
                    nowMillis: now.epochMillis, hours: Int32(hours)))
            return bar.shown ? InboxTimelineBar(entry: entry, bar: bar) : nil
        }
    }

    private func header(entries: [InboxActivityEntry], selectedProject: String) -> some View {
        let projects = store.projects.filter { !$0.archived }
        return VStack(alignment: .leading, spacing: 8) {
            DieterPaneTopBar {
                DieterTitleCapsule(title: "Inbox", count: entries.count)
            } trailing: {
                Button {
                    newTaskPresented = true
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                        Text("New task")
                    }
                }
                .buttonStyle(DieterBarButtonStyle(prominent: true))
                .fixedSize()
                .help("Create a task in any project")
                .accessibilityIdentifier("inbox.new-task").e2eTarget("inbox.new-task")
                .popover(isPresented: $newTaskPresented, arrowEdge: .top) {
                    QuickTaskPopover(
                        isPresented: $newTaskPresented, draft: store.quickTaskForm, chooseDestination: true
                    )
                    .environment(store)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 5) {
                    DieterStatusDot(color: DieterTheme.running, size: 6)
                    Text("\(entries.filter(\.running).count) running").foregroundStyle(DieterTheme.subtle)
                    Text("·").foregroundStyle(DieterTheme.tertiary)
                    Text("\(entries.filter(\.needsYou).count) need attention")
                        .foregroundStyle(
                            entries.contains(where: \.needsYou) ? DieterTheme.attention : DieterTheme.subtle)
                }
                .font(DieterFont.meta)
                HStack(spacing: 7) {
                    HStack(spacing: 7) {
                        Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(
                            DieterTheme.tertiary)
                        TextField("Search activity", text: $query)
                            .textFieldStyle(.plain).font(.system(size: 12))
                            .foregroundStyle(DieterTheme.text)
                            .accessibilityLabel("Search activity")
                            .accessibilityIdentifier("inbox.search").e2eTarget("inbox.search")
                        if !query.isEmpty {
                            Button {
                                query = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain).foregroundStyle(DieterTheme.tertiary)
                            .accessibilityLabel("Clear search")
                        }
                    }
                    .padding(.horizontal, 11).frame(height: 30)
                    .dieterCapsuleChrome(interactive: false)
                    Menu {
                        Button("All projects") { projectID = "" }
                            .accessibilityIdentifier("inbox.project.all")
                        ForEach(projects, id: \.id) { project in
                            Button(project.name) { projectID = project.id }
                                .accessibilityIdentifier("inbox.project.\(project.id)")
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: selectedProject.isEmpty ? "square.grid.2x2" : "folder")
                            Text(projects.first { $0.id == selectedProject }?.name ?? "All projects").lineLimit(1)
                            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                        }
                        .font(.system(size: 11.5, weight: .medium)).foregroundStyle(DieterTheme.subtle)
                        .padding(.horizontal, 11).frame(height: 30)
                        .contentShape(Capsule())
                    }
                    .dieterMenuChrome()
                    .accessibilityLabel("Filter by project")
                    .accessibilityIdentifier("inbox.project-filter").e2eTarget("inbox.project-filter")
                    Button {
                        rulesPresented = true
                    } label: {
                        Image(
                            systemName: store.navigation.inboxRules.contains(where: \.enabled)
                                ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle"
                        )
                        .font(.system(size: 14))
                        .foregroundStyle(DieterTheme.subtle)
                        .frame(width: 30, height: 30)
                        .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Inbox rules: show or hide projects and labels")
                    .accessibilityLabel("Inbox rules")
                    .accessibilityIdentifier("inbox.rules").e2eTarget("inbox.rules")
                }
                if store.activity.summary.hidden > 0 {
                    Button {
                        rulesPresented = true
                    } label: {
                        Text("\(store.activity.summary.hidden) hidden by Inbox rules")
                            .font(DieterFont.meta).foregroundStyle(DieterTheme.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("inbox.hidden")
                }
            }
            .padding(.leading, 14).padding(.trailing, 6)
        }
        .padding(.bottom, 8)
    }

    private func timelineSummary(intervals: [InboxTimelineBar], live: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 5) {
                Circle().fill(live ? DieterTheme.running : DieterTheme.amber).frame(width: 5, height: 5)
                Text(live ? "LIVE" : "CACHED").font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(live ? DieterTheme.running : DieterTheme.amber)
                Spacer(minLength: 3)
                Menu {
                    ForEach(SharedRules.shared.timelineHours().map(\.intValue), id: \.self) { value in
                        Button(SharedRules.shared.timelineRangeTitle(hours: Int32(value))) { hours = value }
                            .accessibilityIdentifier("inbox.range.\(value)")
                    }
                } label: {
                    DieterMenuLabel(title: SharedRules.shared.timelineRangeTitle(hours: Int32(hours)), size: 24)
                }
                .dieterMenuChrome()
                .accessibilityLabel("Timeline range")
                .accessibilityIdentifier("inbox.range").e2eTarget("inbox.range")
            }
            if intervals.isEmpty {
                Text(SharedRules.shared.timelineEmpty(hours: Int32(hours)))
                    .font(DieterFont.meta).foregroundStyle(DieterTheme.subtle)
                    .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
            } else {
                InboxTimelineChart(
                    intervals: Array(intervals.sorted { $0.entry.kind.rawValue < $1.entry.kind.rawValue }.prefix(4))
                )
                .frame(height: 50)
            }
            HStack {
                Text("−\(hours)h")
                    .e2eTarget("inbox.range.current.\(hours)")
                Spacer()
                Text(hours == 1 ? "−30m" : "−\(hours / 2)h")
                Spacer()
                Text(live ? "Now" : "Last sync")
            }
            .font(.system(size: 9, design: .monospaced)).foregroundStyle(DieterTheme.tertiary)
        }
        .padding(11)
        .dieterTile(radius: DieterMetrics.cardRadius + 2)
    }

    @ViewBuilder
    private func section(_ title: String, id: String, entries: [InboxActivityEntry]) -> some View {
        Section {
            ForEach(entries.prefix(visibleLimit), id: \.rowIdentity) { entry in
                InboxActivityRow(entry: entry, onOpen: onOpen).equatable()
            }
            if entries.count > visibleLimit { showMore }
        } header: {
            if !entries.isEmpty {
                HStack {
                    Text(title).font(.system(size: 11.5, weight: .semibold))
                    Spacer()
                    Text("\(entries.count)").font(DieterFont.monoSmall)
                }
                .foregroundStyle(DieterTheme.tertiary).padding(.horizontal, 4).padding(.top, 12).padding(.bottom, 2)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("inbox.section.\(id)").e2eTarget("inbox.section.\(id)")
            }
        }
        // Scope the lazy container's identity, including its header and rows. A row
        // moving sections must not retain the old section's rendered content.
        .id(id)
    }

    private var showMore: some View {
        Button("Show more activity") { visibleLimit += 20 }
            .buttonStyle(DieterBarButtonStyle(size: 26))
            .frame(maxWidth: .infinity).padding(.vertical, 9)
            .accessibilityIdentifier("inbox.show-more").e2eTarget("inbox.show-more")
    }

    private func emptyState(filtered: Bool) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Image(systemName: filtered ? "magnifyingglass" : "tray").font(.system(size: 23, weight: .light))
                .foregroundStyle(DieterTheme.tertiary)
            Text(filtered ? "No matching activity" : "All quiet here").font(DieterFont.title)
            Text(
                filtered
                    ? "Try another project or search term."
                    : "Chats and cards appear here when an agent starts, replies, or needs you."
            )
            .font(DieterFont.meta).foregroundStyle(DieterTheme.subtle)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 24).padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("inbox.empty").e2eTarget("inbox.empty")
    }

}

/// A row redraws when its entry changes. Selection, the clock, and what the
/// Finish action needs are read by small parts of it.
private struct InboxActivityRow: View, Equatable {
    @Environment(DieterStore.self) private var store
    let entry: InboxActivityEntry
    /// Always opens the entry, so rows compare by their entries.
    let onOpen: (InboxActivityEntry) -> Void
    @State private var renamePresented = false
    @State private var editPresented = false
    @State private var renameText = ""

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.entry == rhs.entry }

    var body: some View {
        if entry.row.chat {
            row.modifier(ChatContextMenu(card: entry.row.card))
        } else {
            // The card's flags are read by its menu, when the menu is built.
            row.modifier(
                BoardCardContextMenu(
                    card: entry.row.card, currentBoard: store.board(id: entry.row.card.boardID), flags: nil,
                    open: { onOpen(entry) },
                    renamePresented: $renamePresented, editPresented: $editPresented, renameText: $renameText
                )
            )
        }
    }

    private var row: some View {
        let accent = inboxAccent(entry.kind)
        return ZStack(alignment: .bottomTrailing) {
            Button {
                onOpen(entry)
            } label: {
                HStack(alignment: .top, spacing: 9) {
                    RoundedRectangle(cornerRadius: 2).fill(accent).frame(width: 3)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.row.title)
                            .e2eTarget("inbox.title.\(entry.id).\(entry.row.title)")
                            .padding(.trailing, 22)
                            .font(.system(size: 13, weight: .semibold)).lineLimit(2)
                            .foregroundStyle(DieterTheme.text)
                            .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                        Text(metadata)
                            .font(.system(size: 10)).foregroundStyle(DieterTheme.tertiary).lineLimit(1)
                        if entry.running {
                            Text(entry.row.detail).font(.system(size: 11))
                                .foregroundStyle(DieterTheme.subtle).lineLimit(1)
                        }
                        // What its machine reports may be old, e.g. while that machine is offline.
                        if !entry.row.stale.isEmpty {
                            Label(entry.row.stale, systemImage: "icloud.slash")
                                .font(.system(size: 10)).foregroundStyle(DieterTheme.amber).lineLimit(1)
                        }
                        HStack(spacing: 5) {
                            if entry.row.pinned {
                                Image(systemName: "pin.fill").font(.system(size: 9))
                                    .accessibilityLabel("Pinned in inbox")
                            }
                            Image(systemName: statusSymbol(entry.kind)).font(.system(size: 9, weight: .semibold))
                            Text(entry.row.kindLabel).font(.system(size: 10, weight: .medium))
                                .e2eTarget(
                                    "inbox.status.\(entry.id).\(entry.row.kind)",
                                    text: "\(entry.row.title) · \(entry.row.kindLabel)")
                            Spacer(minLength: 4)
                            InboxActivityAge(atMillis: entry.row.shownAtMillis)
                                .font(.system(size: 9, design: .monospaced)).foregroundStyle(DieterTheme.tertiary)
                            if entry.canFinish { Color.clear.frame(width: 62, height: 20) }
                        }
                        .foregroundStyle(accent)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(10)
                .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
                .modifier(InboxRowSelection(entryID: entry.id, tile: true))
                .contentShape(RoundedRectangle(cornerRadius: DieterMetrics.cardRadius))
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .modifier(InboxRowSelection(entryID: entry.id, tile: false))
            .accessibilityIdentifier("inbox.row.\(entry.id)").e2eTarget("inbox.row.\(entry.id)")
            if entry.canFinish {
                InboxFinishButton(entry: entry)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button {
                store.setInboxCardPinned(entry.id, pinned: !entry.row.pinned)
            } label: {
                Image(systemName: entry.row.pinned ? "pin.fill" : "pin")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .help(entry.row.pinned ? "Unpin from inbox" : "Pin in inbox")
            .accessibilityLabel(entry.row.pinned ? "Unpin from inbox" : "Pin in inbox")
            .accessibilityIdentifier("inbox.pin.\(entry.id)")
            .e2eTarget("inbox.pin.\(entry.id)", text: entry.row.pinned ? "Unpin from inbox" : "Pin in inbox")
            .padding(10)
        }
        .accessibilityElement(children: .contain)
    }

    private var metadata: String {
        let chat = entry.row.chat
        return [entry.row.projectName, chat ? "" : entry.row.boardName, chat ? "Chat" : "Card"]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// The feed's clock: live time, or the last sync while the workspace is cached.
private struct InboxNowKey: EnvironmentKey {
    static let defaultValue = Date.distantPast
}

extension EnvironmentValues {
    fileprivate var inboxNow: Date {
        get { self[InboxNowKey.self] }
        set { self[InboxNowKey.self] = newValue }
    }
}

/// How long ago a row's activity was, by the feed's clock.
private struct InboxActivityAge: View {
    @Environment(\.inboxNow) private var now
    let atMillis: Int64

    var body: some View {
        Text(SharedRules.shared.activityAge(atMillis: atMillis, nowMillis: now.epochMillis, suffix: false))
    }
}

/// A selected row's tile, or its selected trait.
private struct InboxRowSelection: ViewModifier {
    @Environment(DieterStore.self) private var store
    let entryID: String
    /// The tile, else the accessibility trait.
    let tile: Bool

    func body(content: Content) -> some View {
        let selected = (store.selectedCardID ?? store.selectedChatID) == entryID
        if tile {
            content.dieterTile(selected ? .selected : .rest)
        } else {
            content.accessibilityAddTraits(selected ? .isSelected : [])
        }
    }
}

/// Moves a reviewable card to Done while a machine that hosts its project can take it.
private struct InboxFinishButton: View {
    @Environment(DieterStore.self) private var store
    let entry: InboxActivityEntry

    var body: some View {
        Button {
            Task { await store.finish(entry.row.card) }
        } label: {
            Label("Finish", systemImage: "checkmark")
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 8).frame(height: 22)
                .foregroundStyle(DieterTheme.text)
                .dieterCapsuleChrome()
        }
        .buttonStyle(.plain)
        .disabled(store.movingCardIDs.contains(entry.id) || !store.projectIsAvailable(entry.row.card.projectID))
        .accessibilityLabel("Finish \(entry.row.title)")
        .accessibilityIdentifier("inbox.finish.\(entry.id)").e2eTarget("inbox.finish.\(entry.id)")
        .padding(10)
    }
}

@MainActor
private func inboxAccent(_ kind: InboxActivityKind) -> Color {
    switch kind {
    case .answer, .unread: DieterTheme.attention
    case .review: DieterTheme.action
    case .running: DieterTheme.running
    case .failed: DieterTheme.failed
    case .recent: DieterTheme.tertiary
    }
}

private func statusSymbol(_ kind: InboxActivityKind) -> String {
    switch kind {
    case .answer, .unread: "bubble.left.and.bubble.right"
    case .review: "checkmark.circle"
    case .running: "waveform"
    case .failed: "exclamationmark.circle"
    case .recent: "checkmark"
    }
}

/// An entry's bar on the Inbox timeline.
private struct InboxTimelineBar: Identifiable {
    let entry: InboxActivityEntry
    let bar: ClientActivityTimelineBar
    var id: String { entry.id }
}

private struct InboxTimelineChart: View {
    let intervals: [InboxTimelineBar]

    var body: some View {
        Canvas { context, size in
            let width = max(0, size.width - 8)
            for fraction in [0.0, 0.5, 1.0] {
                var line = Path()
                let x = 4 + width * fraction
                line.move(to: CGPoint(x: x, y: 0))
                line.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(line, with: .color(DieterTheme.border), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            }
            let rowHeight = size.height / CGFloat(max(1, intervals.count))
            for (index, interval) in intervals.enumerated() {
                let y = rowHeight * (CGFloat(index) + 0.5)
                let left = 4 + width * interval.bar.startFraction
                let right = 4 + width * interval.bar.endFraction
                let color = inboxAccent(interval.entry.kind)
                if interval.bar.point {
                    context.fill(
                        Path(ellipseIn: CGRect(x: right - 3, y: y - 3, width: 6, height: 6)), with: .color(color))
                } else {
                    let rect = CGRect(x: left, y: y - 3, width: max(3, right - left), height: 6)
                    context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(color.opacity(0.6)))
                }
            }
        }
        .accessibilityHidden(true)
    }
}
