import AppKit
import DieterAPI
import SwiftUI
import UniformTypeIdentifiers

/// The board's glass top bar in the window's title band: the board picker,
/// filter segments, search, view controls, and New Task.
struct BoardTopBar: View {
    @Environment(DieterStore.self) private var store
    @Environment(\.dieterTitleBandLeadingInset) private var leadingInset
    @State private var quickTaskPresented = false
    @State private var deleteBoardPresented = false

    private var workspacePresented: Bool {
        guard let cardID = store.selectedCardID else { return false }
        let content = store.conversationContext.content
        return content.splitMode && content.isPresented(for: cardID)
    }

    /// The core's board view of the selected board.
    private var view: ClientBoardViewSlice { store.boardProjection.view }

    private var hasActiveFilters: Bool { store.stateFilter != .all || !store.machineFilter.isEmpty }

    var body: some View {
        DieterGlassBar {
            boardPicker
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    filterTrack(showsLabels: true)
                    Spacer(minLength: 8)
                    trailing(searchWidth: 220)
                }
                HStack(spacing: 8) {
                    filterTrack(showsLabels: true)
                    Spacer(minLength: 8)
                    trailing(searchWidth: 150)
                }
                HStack(spacing: 8) {
                    filterTrack(showsLabels: false)
                    Spacer(minLength: 8)
                    trailing(searchWidth: 0)
                }
            }
        }
        .padding(.leading, 14 + leadingInset)
        .padding(.trailing, DieterMetrics.windowInset + 4)
        .padding(.top, DieterMetrics.titleBandTop)
        .frame(height: DieterMetrics.titleBandHeight, alignment: .top)
        .background(DieterTitleBandRegion())
        .onChange(of: store.selectedBoard?.labels.map(\.id) ?? [], initial: true) { _, labels in
            if !store.labelFilter.isEmpty && !labels.contains(store.labelFilter) {
                store.labelFilter = ""
            }
        }
        .confirmationDialog(
            "Delete \(store.selectedBoard?.name ?? "board") from Dieter?",
            isPresented: $deleteBoardPresented,
            titleVisibility: .visible
        ) {
            Button("Delete board", role: .destructive) {
                if let board = store.selectedBoard { Task { await store.retireBoard(board) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Only empty boards can be deleted. Move or remove all cards, including archived cards, and schedules first. The board and its settings are preserved and can be restored."
            )
        }
    }

    // MARK: Board picker

    private var boardPicker: some View {
        let projectID = store.selectedProjectID
        let boards = store.boards(for: projectID)
        return Menu {
            ForEach(boards, id: \.id) { board in
                Button {
                    store.openBoard(board.id, projectID: projectID)
                } label: {
                    let attention = Int(store.boardAttention[board.id] ?? 0)
                    let title = attention > 0 ? "\(board.name)  ·  \(attention) need you" : board.name
                    if board.id == store.selectedBoardID {
                        Label(title, systemImage: "checkmark")
                    } else {
                        Text(title)
                    }
                }
            }
            if !boards.isEmpty { Divider() }
            Button("New board…", systemImage: "plus") { store.presentNewBoard(projectID: projectID) }
                .disabled(!store.projectIsAvailable(projectID))
            if let board = store.selectedBoard {
                Button("Rename board…", systemImage: "pencil") { store.presentRenameBoard(boardID: board.id) }
                Button("New card…", systemImage: "rectangle.badge.plus") { store.createConversationPresented = true }
                Divider()
                Button("Delete board…", systemImage: "trash", role: .destructive) { deleteBoardPresented = true }
                    .disabled(!store.projectIsAvailable(board.projectID))
            }
        } label: {
            HStack(spacing: 7) {
                Text(store.selectedBoard?.name ?? store.selectedProject?.name ?? "Board")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(DieterTheme.text)
                    .lineLimit(1)
                if store.selectedBoard != nil {
                    Text("\(view.total)")
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(DieterTheme.tertiary)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(DieterTheme.tertiary)
            }
            .padding(.horizontal, 14)
            .frame(height: DieterMetrics.capsuleHeight)
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .dieterCapsuleChrome()
        .help(view.summary)
        .accessibilityLabel("Board \(store.selectedBoard?.name ?? ""), \(view.summary)")
        .accessibilityIdentifier("board.picker")
    }

    // MARK: Filters

    @ViewBuilder private func filterTrack(showsLabels: Bool) -> some View {
        let labels = store.selectedBoard?.labels ?? []
        let waiting = store.stateFilter == .waiting
        DieterSegmentTrack {
            Button {
                store.labelFilter = ""
                if waiting { store.stateFilter = .all }
            } label: {
                Text("All")
            }
            .buttonStyle(DieterSegmentStyle(selected: store.labelFilter.isEmpty && !waiting))
            .accessibilityIdentifier("board.filter.all")
            .accessibilityValue(store.labelFilter.isEmpty && !waiting ? "Selected" : "Not selected")
            .help("All cards · \(view.total)")
            if showsLabels, let board = store.selectedBoard {
                ForEach(labels, id: \.id) { label in
                    BoardLabelSegment(
                        label: label, boardID: board.id,
                        count: Int(view.labelCounts[label.id, default: 0]),
                        selected: store.labelFilter == label.id
                    ) {
                        store.labelFilter = store.labelFilter == label.id ? "" : label.id
                    }
                }
            }
            Button {
                store.stateFilter = waiting ? .all : .waiting
            } label: {
                Text("Needs you")
            }
            .buttonStyle(DieterSegmentStyle(selected: waiting))
            .accessibilityIdentifier("board.filter.needs-you")
            .accessibilityValue(waiting ? "Selected" : "Not selected")
        }
        .fixedSize()
    }

    // MARK: Trailing controls

    private func trailing(searchWidth: CGFloat) -> some View {
        HStack(spacing: 8) {
            if !(store.selectedBoard?.conflictKeys ?? []).isEmpty {
                SharedConflictsButton(keys: store.selectedBoard?.conflictKeys ?? [])
                    .buttonStyle(DieterBarButtonStyle())
            }
            if store.selectedBoard?.retirementBlocked == true {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DieterTheme.attention)
                    .frame(width: DieterMetrics.capsuleHeight, height: DieterMetrics.capsuleHeight)
                    .dieterCircleChrome()
                    .help("This board remains available because it has references or a conflicting retirement change.")
            }
            if searchWidth > 0 {
                DieterSearchCapsule(width: searchWidth)
            } else {
                Button {
                    store.commandPalettePresented = true
                } label: {
                    Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(DieterBarButtonStyle(shape: .circle))
                .help("Search and commands (⌘K)")
                .accessibilityLabel("Search and commands")
            }
            viewControls
            quickTaskButton
        }
        .fixedSize()
    }

    private var viewControls: some View {
        HStack(spacing: 0) {
            Menu {
                stateFilterOptions
                if view.machineIds.count > 1 || !store.machineFilter.isEmpty {
                    Divider()
                    machineFilterOptions
                }
                if !(store.selectedBoard?.labels ?? []).isEmpty {
                    Divider()
                    labelFilterOptions
                }
            } label: {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(hasActiveFilters ? DieterTheme.action : DieterTheme.text)
                    .frame(width: 34, height: DieterMetrics.capsuleHeight)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help("Filter cards")
            .accessibilityLabel("Filter cards")
            .accessibilityIdentifier("board.filters")
            Button {
                store.labelsPresented = true
            } label: {
                Image(systemName: "tag")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 34, height: DieterMetrics.capsuleHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Manage board labels")
            .accessibilityLabel("Labels")
            .accessibilityIdentifier("board.filter.labels")
            Button {
                store.archivePolicyPresented = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 34, height: DieterMetrics.capsuleHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Board settings")
            .accessibilityLabel("Board settings")
            .accessibilityIdentifier("board.settings")
            .smokeTarget("board.settings")
            if workspacePresented && store.kanbanPresentedAlongsideConversation {
                Button {
                    store.kanbanPresentedAlongsideConversation = false
                } label: {
                    Image(systemName: "rectangle.3.group")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 34, height: DieterMetrics.capsuleHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Hide Kanban")
                .accessibilityLabel("Hide Kanban")
                .accessibilityIdentifier("board.kanban-toggle")
            }
        }
        .foregroundStyle(DieterTheme.text)
        .padding(.horizontal, 4)
        .dieterCapsuleChrome(interactive: false)
        .disabled(store.selectedBoard == nil)
    }

    private var stateFilterOptions: some View {
        Picker(
            "State", selection: Binding(get: { store.stateFilter }, set: { store.stateFilter = $0 })
        ) {
            ForEach(view.stateOptions, id: \.state) { option in
                Text(option.title).tag(option.state)
            }
        }
        .pickerStyle(.inline)
        .accessibilityIdentifier("board.filter.state")
    }

    private var labelFilterOptions: some View {
        Picker(
            "Label", selection: Binding(get: { store.labelFilter }, set: { store.labelFilter = $0 })
        ) {
            Text("All cards").tag("")
            ForEach(store.selectedBoard?.labels ?? [], id: \.id) { label in
                Text(label.name).tag(label.id)
            }
        }
        .pickerStyle(.inline)
    }

    private var machineFilterOptions: some View {
        Picker(
            "Machine", selection: Binding(get: { store.machineFilter }, set: { store.machineFilter = $0 })
        ) {
            Text("All machines").tag("")
            ForEach(view.machineIds, id: \.self) { id in
                Text(store.endpoints.first { $0.daemonID == id }?.name ?? id).tag(id)
            }
        }
        .pickerStyle(.inline)
        .accessibilityIdentifier("board.filter.machine")
    }

    private var quickTaskButton: some View {
        Button {
            store.quickTaskForm.selectBoardContext(projectID: store.selectedProjectID, boardID: store.selectedBoardID)
            quickTaskPresented = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                Text("New Task")
            }
        }
        .buttonStyle(DieterBarButtonStyle(prominent: true))
        .help("Create a task from its story")
        .accessibilityLabel("Quick task")
        .accessibilityIdentifier("board.quick-task")
        .smokeTarget("board.quick-task")
        .disabled(store.selectedBoard == nil)
        .popover(isPresented: $quickTaskPresented, arrowEdge: .top) {
            QuickTaskPopover(isPresented: $quickTaskPresented, draft: store.quickTaskForm)
                .environment(store)
        }
    }
}

/// A label filter segment that can also be dragged onto a card to assign it.
struct BoardLabelSegment: View {
    let label: Dieter_V1_Label
    let boardID: String
    let count: Int
    let selected: Bool
    let select: () -> Void

    private var color: Color { Color(hex: label.color) ?? DieterTheme.shell }

    var body: some View {
        Button(action: select) {
            HStack(spacing: 5) {
                Text("#\(label.name)").foregroundStyle(selected ? DieterTheme.text : color.opacity(0.95))
                if count > 0 {
                    Text("\(count)").foregroundStyle(DieterTheme.tertiary).monospacedDigit()
                }
            }
            .draggable(BoardLabelDragPayload(labelID: label.id, boardID: boardID).encoded) {
                BoardLabelDragPreview(label: label)
            }
        }
        .buttonStyle(DieterSegmentStyle(selected: selected))
        .help("Click to filter · Drag onto a card to assign")
        .accessibilityLabel("\(label.name), \(count) cards")
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityHint("Click to filter. Drag onto a card to assign this label.")
    }
}

struct BoardLabelDragPreview: View {
    let label: Dieter_V1_Label

    private var color: Color { Color(hex: label.color) ?? DieterTheme.shell }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "tag.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(
                color)
            Text(label.name).font(.system(size: 12, weight: .semibold))
            Text("Drop onto a card").font(.system(size: 10)).foregroundStyle(DieterTheme.tertiary)
        }
        .padding(.horizontal, 12).frame(minWidth: 220, minHeight: 38)
        .fixedSize(horizontal: true, vertical: true)
        .background(DieterTheme.panelSolid, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(color.opacity(0.48)))
        .shadow(color: Color.black.opacity(0.42), radius: 16, y: 7)
    }
}
