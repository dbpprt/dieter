import DieterClientAPI
import DieterCore
import SwiftUI

/// The Inbox: count segments, the activity timeline, then the core's sections
/// (needs you, running, idle pins, recent) as one-line rows.
struct InboxFeed: View {
    @Environment(DieterStore.self) private var store
    var active = true
    let onOpen: (InboxActivityEntry) -> Void
    @State private var query = ""
    @State private var searching = false
    @State private var projectID = ""
    @State private var status = "ALL"
    @State private var hours = 1
    @State private var visibleLimit = 40
    @State private var newTaskPresented = false
    @State private var rulesPresented = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        let entries = store.inboxEntries
        let projects = store.projects.filter { !$0.archived }.map { InboxProjectOption(id: $0.id, name: $0.name) }
        let selectedProject = projects.contains { $0.id == projectID } ? projectID : ""
        let scoped = scopedEntries(entries, projectID: selectedProject)
        let filtered = scoped.filter { matches($0, status: status) }
        let live = store.workspaceIsLive
        // With no recorded sync time, use recorded activity rather than advancing
        // a cached running interval to the wall clock.
        let cachedNow =
            store.lastSyncedAt ?? entries.map(\.row.atMillis).max().flatMap { Date(epochMillis: $0) } ?? .distantPast
        VStack(spacing: 0) {
            header(scoped: scoped, filtered: filtered, projects: projects, selectedProject: selectedProject, live: live)
            TimelineView(.periodic(from: .now, by: 15)) { clock in
                let now = live ? clock.date : cachedNow
                let intervals = timeline(filtered, now: now)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        timelineSummary(intervals: intervals).padding(.bottom, 2)
                        if filtered.isEmpty {
                            emptyState(filtered: !query.isEmpty || !selectedProject.isEmpty || status != "ALL")
                        } else {
                            ForEach(sections(filtered), id: \.id) { group in
                                section(group)
                            }
                            if store.activity.summary.hidden > 0 { hiddenFooter }
                        }
                    }
                    .padding(.leading, 10).padding(.trailing, 6).padding(.vertical, 6)
                }
                // Each tick reaches only the rows' ages, not the rows.
                .environment(\.inboxNow, now)
                .accessibilityIdentifier("inbox.feed").e2eTarget("inbox.feed")
            }
        }
        .foregroundStyle(DieterTheme.text)
        .ignoresSafeArea(.container, edges: .top)
        .background {
            if active {
                Button("Search Inbox") {
                    searching = true
                    searchFocused = true
                }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
            }
        }
        .sheet(isPresented: $rulesPresented) { InboxRulesSheet().environment(store) }
        .onChange(of: query) { _, _ in visibleLimit = 40 }
        .onChange(of: projectID) { _, _ in visibleLimit = 40 }
        .onChange(of: status) { _, _ in visibleLimit = 40 }
        .onChange(of: store.activeGateway.credentialID) { _, _ in
            query = ""; projectID = ""; status = "ALL"; searching = false; visibleLimit = 40
        }
    }

    private func scopedEntries(_ entries: [InboxActivityEntry], projectID: String) -> [InboxActivityEntry] {
        entries.filter { entry in
            // The core's rule matches every row for a blank query.
            (projectID.isEmpty || entry.row.card.projectID == projectID)
                && (query.isEmpty
                    || SharedRules.shared.activityMatches(
                        query: query, title: entry.row.card.title, projectName: entry.row.projectName,
                        boardName: entry.row.boardName))
        }
    }

    private func matches(_ entry: InboxActivityEntry, status: String) -> Bool {
        SharedRules.shared.inboxStatusMatches(
            status: status, kind: entry.row.kind, needsYou: entry.row.needsYou, pinned: entry.row.pinned)
    }

    /// The rows grouped by the core's section, in the feed's order.
    private func sections(_ entries: [InboxActivityEntry]) -> [InboxSectionGroup] {
        var groups: [InboxSectionGroup] = []
        for entry in entries {
            if let last = groups.indices.last, groups[last].section == entry.section {
                groups[last].entries.append(entry)
            } else {
                groups.append(InboxSectionGroup(section: entry.section, entries: [entry]))
            }
        }
        return groups
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

    private func header(
        scoped: [InboxActivityEntry], filtered: [InboxActivityEntry], projects: [InboxProjectOption],
        selectedProject: String,
        live: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            DieterPaneTopBar {
                DieterTitleCapsule(title: "Inbox", count: filtered.count)
            } trailing: {
                HStack(spacing: 4) {
                    Circle().fill(live ? DieterTheme.running : DieterTheme.amber).frame(width: 5, height: 5)
                    Text(live ? "LIVE" : "CACHED").font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(live ? DieterTheme.running : DieterTheme.amber)
                }
                .padding(.trailing, 4)
                .accessibilityElement(children: .combine)
                filterMenu(projects: projects, selectedProject: selectedProject)
                Button {
                    newTaskPresented = true
                } label: {
                    Image(systemName: "plus").font(.system(size: 12.5, weight: .bold))
                }
                .buttonStyle(DieterBarButtonStyle(shape: .circle, prominent: true))
                .help("Create a task in any project")
                .accessibilityLabel("New task")
                .accessibilityIdentifier("inbox.new-task").e2eTarget("inbox.new-task")
                .popover(isPresented: $newTaskPresented, arrowEdge: .top) {
                    QuickTaskPopover(
                        isPresented: $newTaskPresented, draft: store.quickTaskForm, chooseDestination: true
                    )
                    .environment(store)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                if searching || !query.isEmpty { searchField }
                segments(scoped: scoped)
            }
            .padding(.leading, 14).padding(.trailing, 6)
        }
        .padding(.bottom, 6)
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(DieterTheme.tertiary)
            TextField("Search activity", text: $query)
                .textFieldStyle(.plain).font(.system(size: 12))
                .foregroundStyle(DieterTheme.text)
                .focused($searchFocused)
                .onExitCommand {
                    query = ""
                    searching = false
                }
                .accessibilityLabel("Search activity")
                .accessibilityIdentifier("inbox.search").e2eTarget("inbox.search")
            Button {
                query = ""
                searching = false
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain).foregroundStyle(DieterTheme.tertiary)
            .accessibilityLabel("Close search")
        }
        .padding(.horizontal, 11).frame(height: 30)
        .dieterCapsuleChrome(interactive: false)
    }

    /// The core's status filters with their counts over the searched rows.
    private func segments(scoped: [InboxActivityEntry]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            DieterSegmentTrack {
                ForEach(SharedRules.shared.inboxStatuses(), id: \.self) { value in
                    let count = value == "ALL" ? 0 : scoped.filter { matches($0, status: value) }.count
                    let slug = value.lowercased().replacingOccurrences(of: "_", with: "-")
                    Button {
                        status = value
                    } label: {
                        HStack(spacing: 5) {
                            Text(SharedRules.shared.inboxStatusTitle(status: value))
                            if count > 0 {
                                Text("\(count)").monospacedDigit().foregroundStyle(segmentTint(value))
                            }
                        }
                    }
                    .buttonStyle(DieterSegmentStyle(selected: status == value))
                    .accessibilityIdentifier("inbox.filter.\(slug)").e2eTarget("inbox.filter.\(slug)")
                }
            }
            .fixedSize()
        }
        .scrollClipDisabled()
    }

    private func segmentTint(_ status: String) -> Color {
        switch status {
        case "NEEDS_YOU": DieterTheme.attention
        case "RUNNING": DieterTheme.running
        default: DieterTheme.tertiary
        }
    }

    /// Search, the project filter, the timeline range and the Inbox rules.
    private func filterMenu(projects: [InboxProjectOption], selectedProject: String) -> some View {
        Menu {
            Button("Search…") {
                searching = true
                searchFocused = true
            }
            .keyboardShortcut("f", modifiers: .command)
            Menu("Project") {
                Toggle("All projects", isOn: Binding(get: { selectedProject.isEmpty }, set: { _ in projectID = "" }))
                    .accessibilityIdentifier("inbox.project.all")
                ForEach(projects, id: \.id) { project in
                    Toggle(
                        project.name,
                        isOn: Binding(get: { selectedProject == project.id }, set: { _ in projectID = project.id })
                    )
                    .accessibilityIdentifier("inbox.project.\(project.id)")
                }
            }
            .accessibilityIdentifier("inbox.project-filter")
            Menu("Timeline") {
                ForEach(SharedRules.shared.timelineHours().map(\.intValue), id: \.self) { value in
                    Toggle(
                        SharedRules.shared.timelineRangeTitle(hours: Int32(value)),
                        isOn: Binding(get: { hours == value }, set: { _ in hours = value })
                    )
                    .accessibilityIdentifier("inbox.range.\(value)")
                }
            }
            .accessibilityIdentifier("inbox.range")
            Divider()
            Button {
                rulesPresented = true
            } label: {
                let hidden = store.activity.summary.hidden
                Text(hidden > 0 ? "Inbox rules… (\(hidden) hidden)" : "Inbox rules…")
            }
            .accessibilityIdentifier("inbox.rules")
        } label: {
            DieterMenuLabel(
                symbol: selectedProject.isEmpty && !store.navigation.inboxRules.contains(where: \.enabled)
                    ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill",
                showsChevron: false)
        }
        .dieterMenuChrome()
        .help("Filter, search and Inbox rules")
        .accessibilityLabel("Inbox filter")
        .accessibilityIdentifier("inbox.filter-menu").e2eTarget("inbox.filter-menu")
    }

    private func timelineSummary(intervals: [InboxTimelineBar]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if intervals.isEmpty {
                Text(SharedRules.shared.timelineEmpty(hours: Int32(hours)))
                    .font(DieterFont.meta).foregroundStyle(DieterTheme.subtle)
                    .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            } else {
                InboxTimelineChart(
                    intervals: Array(intervals.sorted { $0.entry.kind.rawValue < $1.entry.kind.rawValue }.prefix(4))
                )
                .frame(height: 38)
            }
            HStack {
                Text("−\(hours)h")
                    .e2eTarget("inbox.range.current.\(hours)")
                Spacer()
                Text(hours == 1 ? "−30m" : "−\(hours / 2)h")
                Spacer()
                Text(store.workspaceIsLive ? "now" : "last sync")
            }
            .font(.system(size: 9, design: .monospaced)).foregroundStyle(DieterTheme.tertiary)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .dieterTile(radius: DieterMetrics.cardRadius + 2)
    }

    @ViewBuilder
    private func section(_ group: InboxSectionGroup) -> some View {
        // Recent can hold hundreds of rows; the other sections are short.
        let limit = group.section == .recent ? visibleLimit : group.entries.count
        Section {
            ForEach(group.entries.prefix(limit), id: \.rowIdentity) { entry in
                InboxActivityRow(entry: entry, showsPin: group.section != .pinned, onOpen: onOpen).equatable()
            }
            if group.entries.count > limit { showMore }
        } header: {
            InboxSectionHeader(section: group.section, count: group.entries.count)
        }
        // Scope the lazy container's identity, including its header and rows. A row
        // moving sections must not retain the old section's rendered content.
        .id(group.id)
    }

    private var hiddenFooter: some View {
        Button {
            rulesPresented = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "eye.slash").font(.system(size: 10))
                Text("\(store.activity.summary.hidden) hidden by Inbox rules")
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
            }
            .font(DieterFont.meta).foregroundStyle(DieterTheme.tertiary)
            .padding(.horizontal, 6).padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("inbox.hidden").e2eTarget("inbox.hidden")
    }

    private var showMore: some View {
        Button("Show more activity") { visibleLimit += 40 }
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
                    ? "Try another filter, project or search term."
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

/// A project the Inbox can filter by.
private struct InboxProjectOption {
    let id: String
    let name: String
}

/// Consecutive rows of one core section.
private struct InboxSectionGroup {
    let section: ClientActivityRow.Section
    var entries: [InboxActivityEntry]

    /// Stable per section, for the lazy container and E2E flows.
    var id: String {
        switch section {
        case .attention: "needs-you"
        case .running: "running"
        case .pinned: "pinned"
        default: "recent"
        }
    }
}

/// A section's title and count in its colour, then a rule to the edge.
private struct InboxSectionHeader: View {
    let section: ClientActivityRow.Section
    let count: Int

    var body: some View {
        let color: Color =
            switch section {
            case .attention: DieterTheme.attention
            case .running: DieterTheme.running
            default: DieterTheme.tertiary
            }
        HStack(spacing: 6) {
            Text(SharedRules.shared.inboxSectionTitle(section: Int32(section.rawValue)))
                .font(.system(size: 11.5, weight: .semibold))
            Text("\(count)").font(DieterFont.monoSmall).opacity(0.8)
            Rectangle().fill(DieterTheme.border).frame(height: 1).padding(.leading, 2)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6).padding(.top, 12).padding(.bottom, 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("inbox.section.\(InboxSectionGroup(section: section, entries: []).id)")
        .e2eTarget("inbox.section.\(InboxSectionGroup(section: section, entries: []).id)")
    }
}

/// One line per conversation: status, title, delegated agents, project and
/// age. Hovering shows pin and, for cards it can finish, Finish. A row redraws
/// when its entry changes; selection and the clock are read by small parts of it.
private struct InboxActivityRow: View, Equatable {
    @Environment(DieterStore.self) private var store
    let entry: InboxActivityEntry
    /// Outside the Pinned section a pinned row marks its pin.
    let showsPin: Bool
    /// Always opens the entry, so rows compare by their entries.
    let onOpen: (InboxActivityEntry) -> Void
    @State private var renamePresented = false
    @State private var editPresented = false
    @State private var renameText = ""
    @State private var hovering = false

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.entry == rhs.entry && lhs.showsPin == rhs.showsPin
    }

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
        Button {
            onOpen(entry)
        } label: {
            HStack(spacing: 8) {
                InboxStatusMark(kind: entry.kind)
                    .frame(width: 14)
                    .e2eTarget(
                        "inbox.status.\(entry.id).\(entry.row.kind)",
                        text: "\(entry.row.title) · \(entry.row.kindLabel)")
                Text(entry.row.title)
                    .font(.system(size: 13, weight: entry.kind == .recent ? .regular : .medium))
                    .foregroundStyle(DieterTheme.text)
                    .lineLimit(1).truncationMode(.tail)
                    .e2eTarget("inbox.title.\(entry.id).\(entry.row.title)")
                    .modifier(InboxPinnedTarget(entry: entry))
                if entry.row.pinned && showsPin {
                    Image(systemName: "pin.fill").font(.system(size: 8.5)).foregroundStyle(DieterTheme.tertiary)
                        .accessibilityLabel("Pinned in inbox")
                }
                Spacer(minLength: 6)
                if !entry.row.agents.isEmpty {
                    Text(entry.row.agents).font(DieterFont.monoSmall).foregroundStyle(DieterTheme.tertiary)
                        .lineLimit(1).fixedSize()
                }
                if !source.isEmpty { InboxSourceChip(text: source) }
                if !entry.row.stale.isEmpty {
                    Image(systemName: "icloud.slash").font(.system(size: 9.5)).foregroundStyle(DieterTheme.amber)
                        .accessibilityLabel(entry.row.stale)
                }
                InboxActivityAge(atMillis: entry.row.shownAtMillis)
                    .font(DieterFont.monoSmall).foregroundStyle(DieterTheme.tertiary)
                    .lineLimit(1).fixedSize()
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 27, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .modifier(InboxRowSelection(entryID: entry.id, hovering: hovering))
        // Pin and Finish show on hover but stay hit-testable through their
        // content shapes, so a pointer that arrives with its click (as E2E
        // events do) still reaches them.
        .overlay(alignment: .trailing) {
            HStack(spacing: 4) {
                if entry.canFinish { InboxFinishButton(entry: entry, visible: hovering) }
                InboxPinButton(entry: entry, visible: hovering)
            }
            .padding(.horizontal, 3).padding(.vertical, 2)
            .background(hovering ? DieterTheme.panelSolid : Color.clear, in: Capsule())
            .padding(.trailing, 4)
        }
        .onHover { hovering = $0 }
        .help(entry.row.preview)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("inbox.row.\(entry.id)").e2eTarget("inbox.row.\(entry.id)")
    }

    /// The project, or for an unfiled chat, nothing.
    private var source: String { entry.row.projectName }
}

/// A row's status: a dot for running, waiting, unread and failed work, a
/// glyph for reviews and finished work.
private struct InboxStatusMark: View {
    let kind: InboxActivityKind

    var body: some View {
        switch kind {
        case .running: DieterStatusDot(color: DieterTheme.running, size: 8)
        case .answer: DieterStatusDot(color: DieterTheme.attention, size: 8)
        case .unread: DieterStatusDot(color: DieterTheme.action, size: 8)
        case .failed: DieterStatusDot(color: DieterTheme.failed, size: 8)
        case .review:
            Image(systemName: "eye").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(DieterTheme.action)
                .accessibilityHidden(true)
        case .recent:
            Image(systemName: "checkmark").font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(DieterTheme.tertiary)
                .accessibilityHidden(true)
        }
    }
}

/// A pinned row's E2E anchor, in any section.
private struct InboxPinnedTarget: ViewModifier {
    let entry: InboxActivityEntry

    func body(content: Content) -> some View {
        if entry.row.pinned { content.e2eTarget("inbox.pinned.\(entry.id)") } else { content }
    }
}

/// A project name as a small monospaced chip.
private struct InboxSourceChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(DieterFont.monoSmall)
            .foregroundStyle(DieterTheme.subtle)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .frame(height: 17)
            .background(DieterTheme.tileHover, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .fixedSize()
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

/// A selected row's tile, a hovered row's fill, and the selected trait.
private struct InboxRowSelection: ViewModifier {
    @Environment(DieterStore.self) private var store
    let entryID: String
    let hovering: Bool

    func body(content: Content) -> some View {
        let selected = (store.selectedCardID ?? store.selectedChatID) == entryID
        if selected {
            content.dieterTile(.selected, radius: 7).accessibilityAddTraits(.isSelected)
        } else {
            content.background(
                hovering ? DieterTheme.tileHover : Color.clear,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
    }
}

/// Pins or unpins the conversation in the Inbox.
private struct InboxPinButton: View {
    @Environment(DieterStore.self) private var store
    let entry: InboxActivityEntry
    let visible: Bool

    var body: some View {
        let pinned = entry.row.pinned
        Button {
            store.setInboxCardPinned(entry.id, pinned: !pinned)
        } label: {
            Image(systemName: pinned ? "pin.fill" : "pin").font(.system(size: 10.5))
                .opacity(visible ? 1 : 0)
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(DieterTheme.subtle)
        .help(pinned ? "Unpin from inbox" : "Pin in inbox")
        .accessibilityLabel(pinned ? "Unpin from inbox" : "Pin in inbox")
        .accessibilityIdentifier("inbox.pin.\(entry.id)")
        .e2eTarget("inbox.pin.\(entry.id)", text: pinned ? "Unpin from inbox" : "Pin in inbox")
    }
}

/// Moves a reviewable or failed card to Done while a machine that hosts its project can take it.
private struct InboxFinishButton: View {
    @Environment(DieterStore.self) private var store
    let entry: InboxActivityEntry
    let visible: Bool

    var body: some View {
        Button {
            Task { await store.finish(entry.row.card) }
        } label: {
            Label("Finish", systemImage: "checkmark")
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 7).frame(height: 19)
                .foregroundStyle(DieterTheme.text)
                .dieterCapsuleChrome()
                .opacity(visible ? 1 : 0)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(store.movingCardIDs.contains(entry.id) || !store.projectIsAvailable(entry.row.card.projectID))
        .accessibilityLabel("Finish \(entry.row.title)")
        .accessibilityIdentifier("inbox.finish.\(entry.id)").e2eTarget("inbox.finish.\(entry.id)")
    }
}

@MainActor
private func inboxAccent(_ kind: InboxActivityKind) -> Color {
    switch kind {
    case .answer: DieterTheme.attention
    case .unread, .review: DieterTheme.action
    case .running: DieterTheme.running
    case .failed: DieterTheme.failed
    case .recent: DieterTheme.tertiary
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
