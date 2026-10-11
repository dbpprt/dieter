import DieterAPI
import DieterCore
import SwiftUI

/// The Inbox's active rows, grouped by project for the sidebar.
enum SidebarProjectActivity {
    /// Each project's running, waiting, and reviewable conversations.
    static func group(_ entries: [InboxActivityEntry]) -> [String: [InboxActivityEntry]] {
        Dictionary(grouping: entries.filter(isActive)) { $0.row.card.projectID }
    }

    static func isActive(_ entry: InboxActivityEntry) -> Bool {
        entry.running || entry.needsYou || entry.kind == .review || entry.kind == .failed
    }

    @MainActor static func color(_ entry: InboxActivityEntry) -> Color {
        if entry.needsYou { return DieterTheme.attention }
        if entry.running { return DieterTheme.running }
        if entry.kind == .failed { return DieterTheme.failed }
        return DieterTheme.tertiary
    }
}

/// A project: its name, a strip of its active conversations, and, while
/// expanded, its destinations and the conversations that are running or wait.
struct SidebarProjectRow: View {
    @Environment(DieterStore.self) private var store
    let project: Dieter_V1_Project
    let projectIDs: [String]
    let expanded: Bool
    let pinned: Bool
    let activity: [InboxActivityEntry]
    let toggleExpanded: () -> Void
    let moveProject: (String, String?) -> Void
    @State private var dropTargeted = false
    @State private var hovering = false

    private var selected: Bool {
        store.selectedProjectID == project.id && [.board, .files, .changes, .schedules].contains(store.section)
    }

    private var accessibilityLabel: String {
        "\(project.name), \(SharedRules.shared.count(count: Int32(project.checkoutChoices.count), noun: "checkout", plural: ""))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Button(action: toggleExpanded) {
                    HStack(spacing: 6) {
                        Text(project.name)
                            .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                            .foregroundStyle(selected ? DieterTheme.text : DieterTheme.text.opacity(0.88))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .layoutPriority(1)
                            .e2eTarget("sidebar.project.\(project.id).name")
                        if pinned {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(DieterTheme.tertiary)
                                .accessibilityLabel("Pinned project")
                        }
                        Spacer(minLength: 4)
                        if !hovering && !activity.isEmpty {
                            SidebarActivityStrip(entries: activity)
                            Text("\(activity.count)")
                                .font(.system(size: 11, weight: .medium))
                                .monospacedDigit()
                                .foregroundStyle(DieterTheme.tertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(project.name)
                .accessibilityLabel(accessibilityLabel)
                .accessibilityIdentifier("sidebar.project.\(project.id)")
                .accessibilityAction(named: "Edit project") {
                    guard store.projectIsAvailable(project.id) else { return }
                    store.presentProjectEditor(projectID: project.id)
                }
                .accessibilityAction(named: "New board") {
                    guard store.projectIsAvailable(project.id) else { return }
                    store.presentNewBoard(projectID: project.id)
                }

                if hovering {
                    Button {
                        store.presentProjectEditor(projectID: project.id)
                    } label: {
                        Image(systemName: "gearshape").font(.system(size: 11)).frame(width: 18, height: 20)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(DieterTheme.tertiary)
                    .help("Project context for \(project.name)")
                    .accessibilityLabel("Project context for \(project.name)")
                    .accessibilityIdentifier("sidebar.project.\(project.id).settings")
                    .e2eTarget("sidebar.project.\(project.id).settings")
                    .disabled(!store.projectIsAvailable(project.id))
                    .transition(.opacity)

                    Button {
                        store.presentNewBoard(projectID: project.id)
                    } label: {
                        Image(systemName: "plus").font(.system(size: 10, weight: .semibold))
                            .frame(width: 16, height: 20)
                    }
                    .buttonStyle(.plain).foregroundStyle(DieterTheme.tertiary)
                    .disabled(!store.projectIsAvailable(project.id))
                    .help("New board in \(project.name)")
                    .accessibilityLabel("New board in \(project.name)")
                    .accessibilityIdentifier("sidebar.project.\(project.id).new-board")
                    .e2eTarget("sidebar.project.\(project.id).new-board")
                    .transition(.opacity)
                }

                Button(action: toggleExpanded) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(DieterTheme.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 14, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(hovering || expanded ? 1 : 0.55)
                .help(expanded ? "Collapse \(project.name)" : "Expand \(project.name)")
                .accessibilityLabel(expanded ? "Collapse \(project.name)" : "Expand \(project.name)")
                .accessibilityIdentifier("sidebar.project.\(project.id).toggle")
                .e2eTarget(
                    "sidebar.project.\(project.id).toggle",
                    text: expanded ? "Collapse \(project.name)" : "Expand \(project.name)")
            }
            .padding(.leading, 10).padding(.trailing, 6).frame(height: DieterMetrics.rowHeight + 2)
            .background {
                RoundedRectangle(cornerRadius: DieterMetrics.rowRadius + 1, style: .continuous)
                    .fill(
                        dropTargeted
                            ? DieterTheme.tileSelected
                            : (selected ? DieterTheme.tileSelected : (hovering ? DieterTheme.tileHover : .clear)))
            }
            .overlay {
                RoundedRectangle(cornerRadius: DieterMetrics.rowRadius + 1, style: .continuous)
                    .strokeBorder(
                        dropTargeted ? DieterTheme.shell.opacity(0.55) : (selected ? DieterTheme.tileRim : .clear))
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .draggable(SidebarProjectDragPayload(projectID: project.id).encoded) {
                SidebarProjectDragPreview(name: project.name)
            }
            .dropDestination(for: String.self) { values, location in
                guard let value = values.first, let payload = SidebarProjectDragPayload(value),
                    payload.projectID != project.id
                else { return false }
                let targetIndex = projectIDs.firstIndex(of: project.id) ?? 0
                let beforeProjectID: String?
                if location.y < 16 {
                    beforeProjectID = project.id
                } else if projectIDs.indices.contains(targetIndex + 1) {
                    beforeProjectID = projectIDs[targetIndex + 1]
                } else {
                    beforeProjectID = nil
                }
                moveProject(payload.projectID, beforeProjectID)
                return true
            } isTargeted: {
                dropTargeted = $0
            }
            .animation(.easeOut(duration: 0.12), value: dropTargeted)
            .animation(.easeOut(duration: 0.12), value: hovering)

            if expanded {
                SidebarProjectTabs(project: project)
                if !activity.isEmpty {
                    SidebarProjectActivityList(entries: activity)
                }
            }
        }
        .padding(.bottom, expanded ? 8 : 1)
        .animation(.snappy(duration: 0.18), value: expanded)
        .projectContextMenu(for: project)
    }
}

/// One short dash per active conversation, coloured by what it is doing.
private struct SidebarActivityStrip: View {
    let entries: [InboxActivityEntry]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(entries.prefix(5).enumerated()), id: \.offset) { _, entry in
                Capsule().fill(SidebarProjectActivity.color(entry)).frame(width: 7, height: 2.5)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Board · Files · Changes · Schedules for an expanded project.
private struct SidebarProjectTabs: View {
    @Environment(DieterStore.self) private var store
    let project: Dieter_V1_Project

    private var projectIsUnavailable: Bool { !store.projectIsAvailable(project.id) }

    /// The board the Board tab opens: the selected one in this project, else its first.
    private var board: Dieter_V1_Board? {
        let boards = store.boards(for: project.id)
        if store.selectedProjectID == project.id, let selected = boards.first(where: { $0.id == store.selectedBoardID })
        {
            return selected
        }
        return boards.first
    }

    private var current: Bool { store.selectedProjectID == project.id }

    var body: some View {
        HStack(spacing: 2) {
            if let board {
                tab(
                    "Board", symbol: "rectangle.split.3x1", selected: current && store.section == .board,
                    id: "sidebar.board.\(board.id)"
                ) { store.openBoard(board.id, projectID: project.id) }
                .attentionDot(Int(store.boardAttention[board.id] ?? 0))
            } else {
                tab(
                    "Board", symbol: "rectangle.split.3x1", selected: false,
                    id: "sidebar.boardless-create.\(project.id)"
                ) {
                    store.presentNewBoard(projectID: project.id)
                }
                .disabled(projectIsUnavailable)
                .opacity(projectIsUnavailable ? 0.42 : 1)
            }
            tab(
                "Files", symbol: "folder", selected: current && store.section == .files,
                id: "sidebar.files.\(project.id)"
            ) {
                Task { await store.openProject(project.id, section: .files) }
            }
            .disabled(projectIsUnavailable)
            .opacity(projectIsUnavailable ? 0.42 : 1)
            tab(
                "Changes", symbol: "arrow.triangle.branch", selected: current && store.section == .changes,
                id: "sidebar.changes.\(project.id)"
            ) {
                Task { await store.openProjectChanges(project.id) }
            }
            .disabled(projectIsUnavailable)
            .opacity(projectIsUnavailable ? 0.42 : 1)
            tab(
                "Schedules", symbol: "clock", selected: current && store.section == .schedules,
                id: "sidebar.schedules.\(project.id)"
            ) {
                Task { await store.openProject(project.id, section: .schedules) }
            }
            .disabled(projectIsUnavailable)
            .opacity(projectIsUnavailable ? 0.42 : 1)
        }
        .padding(3)
        .dieterControlChrome(RoundedRectangle(cornerRadius: 12, style: .continuous), interactive: false)
    }

    private func tab(
        _ title: String, symbol: String, selected: Bool, id: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 12, weight: .regular))
                Text(title).font(.system(size: 9.5, weight: selected ? .semibold : .medium)).lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .buttonStyle(SidebarProjectTabStyle(selected: selected))
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(id)
        .e2eTarget(id)
    }
}

/// A vertical segment in the project tab track: the glass segment thumb
/// behind a symbol over its title.
private struct SidebarProjectTabStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        SidebarProjectTabBody(label: configuration.label, selected: selected, pressed: configuration.isPressed)
    }
}

private struct SidebarProjectTabBody<Label: View>: View {
    let label: Label
    let selected: Bool
    let pressed: Bool
    @State private var hovering = false

    var body: some View {
        label
            .foregroundStyle(selected ? DieterTheme.text : DieterTheme.subtle)
            .frame(maxWidth: .infinity, minHeight: 40)
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(
                        selected
                            ? DieterTheme.segmentThumb
                            : (hovering || pressed ? DieterTheme.tileHover : Color.clear)
                    )
                    .shadow(color: .black.opacity(selected && !DieterTheme.isDark ? 0.08 : 0), radius: 1.5, y: 0.5)
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: selected)
    }
}

private extension View {
    /// A small attention marker on a project tab.
    func attentionDot(_ count: Int) -> some View {
        overlay(alignment: .topTrailing) {
            if count > 0 {
                DieterStatusDot(color: DieterTheme.attention, size: 6).padding(5).accessibilityHidden(true)
            }
        }
    }
}

/// The project's running, waiting, and reviewable conversations.
private struct SidebarProjectActivityList: View {
    @Environment(DieterStore.self) private var store
    let entries: [InboxActivityEntry]

    var body: some View {
        let now = Date()
        VStack(spacing: 0) {
            ForEach(entries.prefix(8)) { entry in
                let selected = (store.selectedCardID ?? store.selectedChatID) == entry.id
                DieterNavRow(
                    title: entry.row.title, selected: selected,
                    leadingDot: SidebarProjectActivity.color(entry)
                ) {
                    Text(
                        SharedRules.shared.activityAge(
                            atMillis: entry.row.shownAtMillis, nowMillis: now.epochMillis, suffix: false)
                    )
                    .font(DieterFont.monoSmall)
                    .foregroundStyle(DieterTheme.tertiary)
                } action: {
                    guard !selected else { return }
                    Task { await store.openConversation(cardID: entry.id, chat: entry.row.chat) }
                }
                .accessibilityIdentifier("sidebar.activity.\(entry.id)")
            }
        }
        .padding(.top, 2)
    }
}

private struct ProjectContextMenuModifier: ViewModifier {
    @Environment(DieterStore.self) private var store
    let project: Dieter_V1_Project
    @State private var deleteConfirmationPresented = false

    func body(content: Content) -> some View {
        content
            .contextMenu {
                let pinned = store.navigation.projects.pinned.contains(project.id)
                Button(pinned ? "Unpin project" : "Pin project", systemImage: pinned ? "pin.slash" : "pin") {
                    store.setProjectPinned(project.id, pinned: !pinned)
                }
                Divider()
                Button("Rename project…", systemImage: "pencil") {
                    store.presentRenameProject(projectID: project.id)
                }
                Button("Edit project…", systemImage: "slider.horizontal.3") {
                    store.presentProjectEditor(projectID: project.id)
                }
                .disabled(!store.projectIsAvailable(project.id))
                Button("New board…", systemImage: "plus") {
                    store.presentNewBoard(projectID: project.id)
                }
                .disabled(!store.projectIsAvailable(project.id))
                let folders = store.navigation.projects.folders
                if !folders.isEmpty {
                    Divider()
                    Menu("Move to folder", systemImage: "folder") {
                        ForEach(folders, id: \.id) { folder in
                            Button {
                                moveProject(to: folder.id)
                            } label: {
                                if folder.itemIds.contains(project.id) {
                                    Label(folder.name, systemImage: "checkmark")
                                } else {
                                    Text(folder.name)
                                }
                            }
                        }
                        if folders.folder(containing: project.id) != nil {
                            Divider()
                            Button("No folder", systemImage: "arrow.up.backward") {
                                moveProject(to: nil)
                            }
                        }
                    }
                }
                Divider()
                Button("Delete project…", systemImage: "trash", role: .destructive) {
                    deleteConfirmationPresented = true
                }
            }
            .confirmationDialog(
                "Delete \(project.name) from Dieter?",
                isPresented: $deleteConfirmationPresented,
                titleVisibility: .visible
            ) {
                Button("Delete project", role: .destructive) {
                    Task { await store.setProjectArchived(id: project.id, archived: true) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    "This removes the project from the sidebar without deleting its Git working tree. You can restore it from Archive."
                )
            }
    }

    private func moveProject(to folderID: String?) {
        store.moveToFolder(.projects, itemID: project.id, folderID: folderID)
    }
}

private extension View {
    func projectContextMenu(for project: Dieter_V1_Project) -> some View {
        modifier(ProjectContextMenuModifier(project: project))
    }
}
