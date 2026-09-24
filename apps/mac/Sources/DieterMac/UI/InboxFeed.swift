import DieterAPI
import SwiftUI

struct InboxFeed: View {
    @Environment(DieterStore.self) private var store
    let onOpen: (Dieter_V1_Card) -> Void
    @State private var query = ""
    @State private var projectID = ""
    @State private var hours = 1
    @State private var visibleLimit = 20

    var body: some View {
        let entries = store.inboxEntries
        let projects = store.projects.filter { !$0.archived }
        let selectedProject = projects.contains { $0.id == projectID } ? projectID : ""
        let filtered = filteredEntries(entries, projectID: selectedProject)
        let live = store.workspaceIsLive
        // With no recorded sync time, use recorded activity rather than advancing
        // a cached running interval to the wall clock.
        let cachedNow = store.lastSyncedAt ?? entries.compactMap(\.at).max() ?? .distantPast
        VStack(spacing: 0) {
            header(entries: filtered, projects: projects, selectedProject: selectedProject)
            Divider().overlay(DieterTheme.border)
            TimelineView(.periodic(from: .now, by: 15)) { clock in
                let now = live ? clock.date : cachedNow
                let intervals = InboxActivity.timeline(entries: filtered, now: now, hours: hours)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 7) {
                        timelineSummary(intervals: intervals, live: live)
                        if filtered.isEmpty {
                            emptyState(filtered: !query.isEmpty || !selectedProject.isEmpty)
                        } else {
                            section("Running", id: "running", entries: filtered.filter(\.running), now: now)
                            section("Needs you", id: "needs-you", entries: filtered.filter(\.needsYou), now: now)
                            section(
                                "Recent", id: "recent", entries: filtered.filter { !$0.needsYou && !$0.running },
                                now: now)
                        }
                    }
                    .padding(12)
                }
                .accessibilityIdentifier("inbox.feed").smokeTarget("inbox.feed")
            }
        }
        .foregroundStyle(DieterTheme.text)
        .background(DieterPaneBackground(role: .content))
        .ignoresSafeArea(.container, edges: .top)
        .onChange(of: query) { _, _ in visibleLimit = 20 }
        .onChange(of: projectID) { _, _ in visibleLimit = 20 }
        .onChange(of: hours) { _, _ in visibleLimit = 20 }
        .onChange(of: store.endpoint.credentialID) { _, _ in
            query = ""; projectID = ""; visibleLimit = 20
        }
    }

    private func filteredEntries(_ entries: [InboxActivityEntry], projectID: String) -> [InboxActivityEntry] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.filter { entry in
            (projectID.isEmpty || entry.card.projectID == projectID)
                && (search.isEmpty
                    || [
                        entry.card.title, store.projectDirectory[entry.card.projectID]?.name ?? "",
                        store.board(id: entry.card.boardID)?.name ?? "",
                    ].contains { $0.localizedCaseInsensitiveContains(search) })
        }
    }

    private func header(entries: [InboxActivityEntry], projects: [Dieter_V1_Project], selectedProject: String)
        -> some View
    {
        VStack(alignment: .leading, spacing: 10) {
            Text("Inbox").font(.system(size: 19, weight: .semibold))
            HStack(spacing: 5) {
                Text("\(entries.filter(\.running).count) running").foregroundStyle(DieterTheme.subtle)
                Text("·").foregroundStyle(DieterTheme.tertiary)
                Text("\(entries.filter(\.needsYou).count) need you")
                    .foregroundStyle(entries.contains(where: \.needsYou) ? DieterTheme.amber : DieterTheme.subtle)
            }
            .font(DieterFont.meta)
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(DieterTheme.tertiary)
                TextField("Search activity", text: $query)
                    .textFieldStyle(.plain).font(.system(size: 12))
                    .foregroundStyle(DieterTheme.text)
                    .accessibilityLabel("Search activity")
                    .accessibilityIdentifier("inbox.search").smokeTarget("inbox.search")
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
            .padding(.horizontal, 9).frame(height: 31)
            .background(DieterTheme.input, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(DieterTheme.border, lineWidth: 1))
            Menu {
                Button("All projects") { projectID = "" }
                    .accessibilityIdentifier("inbox.project.all")
                ForEach(projects, id: \.id) { project in
                    Button(project.name) { projectID = project.id }
                        .accessibilityIdentifier("inbox.project.\(project.id)")
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: selectedProject.isEmpty ? "square.grid.2x2" : "folder")
                    Text(projects.first { $0.id == selectedProject }?.name ?? "All projects").lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                }
                .font(DieterFont.meta).foregroundStyle(DieterTheme.subtle)
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden)
            .foregroundStyle(DieterTheme.subtle)
            .accessibilityLabel("Filter by project")
            .accessibilityIdentifier("inbox.project-filter").smokeTarget("inbox.project-filter")
        }
        .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 12)
    }

    private func timelineSummary(intervals: [InboxActivityInterval], live: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 5) {
                Circle().fill(live ? DieterTheme.eyes : DieterTheme.amber).frame(width: 5, height: 5)
                Text(live ? "LIVE" : "CACHED").font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(live ? DieterTheme.eyes : DieterTheme.amber)
                Spacer(minLength: 3)
                Menu {
                    ForEach([1, 6, 24], id: \.self) { value in
                        Button("Last \(value)h") { hours = value }
                            .accessibilityIdentifier("inbox.range.\(value)")
                    }
                } label: {
                    Text("Last \(hours)h").font(DieterFont.meta).foregroundStyle(DieterTheme.subtle)
                }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityLabel("Timeline range")
                .accessibilityIdentifier("inbox.range").smokeTarget("inbox.range")
            }
            if intervals.isEmpty {
                Text("No activity in the last \(hours)h")
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
                    .smokeTarget("inbox.range.current.\(hours)")
                Spacer()
                Text(hours == 1 ? "−30m" : "−\(hours / 2)h")
                Spacer()
                Text(live ? "Now" : "Last sync")
            }
            .font(.system(size: 9, design: .monospaced)).foregroundStyle(DieterTheme.tertiary)
        }
        .padding(11)
        .background(DieterTheme.surface, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(DieterTheme.border, lineWidth: 1))
    }

    @ViewBuilder
    private func section(_ title: String, id: String, entries: [InboxActivityEntry], now: Date) -> some View {
        if !entries.isEmpty {
            HStack {
                Text(title.uppercased()).font(DieterFont.sectionLabel)
                Spacer()
                Text("\(entries.count)").font(.system(size: 10, design: .monospaced))
            }
            .foregroundStyle(DieterTheme.subtle).padding(.top, 13).padding(.bottom, 2)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("inbox.section.\(id)").smokeTarget("inbox.section.\(id)")
            ForEach(entries.prefix(visibleLimit)) { entry in
                InboxActivityRow(entry: entry, now: now, onOpen: onOpen)
            }
            if entries.count > visibleLimit { showMore }
        }
    }

    private var showMore: some View {
        Button("Show more activity") { visibleLimit += 20 }
            .buttonStyle(.plain).font(DieterFont.meta).foregroundStyle(DieterTheme.primary)
            .frame(maxWidth: .infinity).padding(.vertical, 9)
            .accessibilityIdentifier("inbox.show-more").smokeTarget("inbox.show-more")
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
        .accessibilityIdentifier("inbox.empty").smokeTarget("inbox.empty")
    }

}

private struct InboxActivityRow: View {
    @Environment(DieterStore.self) private var store
    let entry: InboxActivityEntry
    let now: Date
    let onOpen: (Dieter_V1_Card) -> Void
    @State private var renamePresented = false
    @State private var editPresented = false
    @State private var renameText = ""

    var body: some View {
        if entry.card.scope == "chat" {
            row.modifier(ChatContextMenu(card: entry.card))
        } else {
            row.modifier(
                BoardCardContextMenu(
                    card: entry.card, currentBoard: store.board(id: entry.card.boardID),
                    open: { onOpen(entry.card) },
                    renamePresented: $renamePresented, editPresented: $editPresented, renameText: $renameText
                )
            )
        }
    }

    private var row: some View {
        let selected = (store.selectedCardID ?? store.selectedChatID) == entry.id
        let accent = inboxAccent(entry.kind)
        return ZStack(alignment: .bottomTrailing) {
            Button {
                onOpen(entry.card)
            } label: {
                HStack(alignment: .top, spacing: 9) {
                    RoundedRectangle(cornerRadius: 2).fill(accent).frame(width: 3)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(
                            entry.card.title.isEmpty
                                ? "Untitled \(entry.card.scope == "chat" ? "chat" : "card")" : entry.card.title
                        )
                        .font(.system(size: 13, weight: .semibold)).lineLimit(2)
                        .foregroundStyle(DieterTheme.text)
                        .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                        Text(metadata)
                            .font(.system(size: 10)).foregroundStyle(DieterTheme.tertiary).lineLimit(1)
                        if entry.running {
                            Text(entry.detail).font(.system(size: 11))
                                .foregroundStyle(DieterTheme.subtle).lineLimit(1)
                        }
                        HStack(spacing: 5) {
                            Image(systemName: statusSymbol(entry.kind)).font(.system(size: 9, weight: .semibold))
                            Text(entry.kind.label).font(.system(size: 10, weight: .medium))
                            Spacer(minLength: 4)
                            Text(InboxActivity.age(entry.running ? entry.start : entry.at, now: now))
                                .font(.system(size: 9, design: .monospaced)).foregroundStyle(DieterTheme.tertiary)
                            if entry.kind == .review { Color.clear.frame(width: 62, height: 20) }
                        }
                        .foregroundStyle(accent)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(10)
                .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
                .background(
                    selected ? DieterTheme.selection : DieterTheme.surface, in: RoundedRectangle(cornerRadius: 8)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8).stroke(
                        selected ? accent.opacity(0.7) : DieterTheme.border, lineWidth: selected ? 1.5 : 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("inbox.row.\(entry.id)").smokeTarget("inbox.row.\(entry.id)")
            if entry.kind == .review {
                Button {
                    Task { await store.move(entry.card, lane: "done") }
                } label: {
                    Label("Finish", systemImage: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 7).frame(height: 20)
                        .foregroundStyle(DieterTheme.text)
                        .background(DieterTheme.raised, in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .disabled(store.movingCardIDs.contains(entry.id) || !store.projectIsAvailable(entry.card.projectID))
                .accessibilityLabel("Finish \(entry.card.title)")
                .accessibilityIdentifier("inbox.finish.\(entry.id)").smokeTarget("inbox.finish.\(entry.id)")
                .padding(10)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var metadata: String {
        var parts = [store.projectDirectory[entry.card.projectID]?.name ?? ""]
        if entry.card.scope != "chat" { parts.append(store.board(id: entry.card.boardID)?.name ?? "") }
        parts.append(entry.card.scope == "chat" ? "Chat" : "Card")
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

@MainActor
private func inboxAccent(_ kind: InboxActivityKind) -> Color {
    switch kind {
    case .answer: DieterTheme.amber
    case .review: DieterTheme.coral
    case .running: DieterTheme.primary
    case .failed: DieterTheme.coral
    case .recent: DieterTheme.eyes
    }
}

private func statusSymbol(_ kind: InboxActivityKind) -> String {
    switch kind {
    case .answer: "bubble.left.and.bubble.right"
    case .review: "checkmark.circle"
    case .running: "waveform"
    case .failed: "exclamationmark.circle"
    case .recent: "checkmark"
    }
}

private struct InboxTimelineChart: View {
    let intervals: [InboxActivityInterval]

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
                let left = 4 + width * interval.from
                let right = 4 + width * interval.to
                let color = inboxAccent(interval.entry.kind)
                if interval.point {
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
