import AppKit
import DieterAPI
import SwiftUI
import UniformTypeIdentifiers

struct BoardHeader: View {
    @Environment(DieterStore.self) private var store
    var usesTitlebarSpace = false
    var active = true
    @State private var quickTaskPresented = false

    private var workspacePresented: Bool {
        guard let cardID = store.selectedCardID else { return false }
        let content = store.conversationContext.content
        return content.splitMode && content.isPresented(for: cardID)
    }

    /// The core's board view of the selected board.
    private var view: ClientBoardViewSlice { store.boardProjection.view }

    private func machineFilterMenu(iconOnly: Bool) -> some View {
        Menu {
            machineFilterOptions
        } label: {
            if iconOnly {
                Label("Machine", systemImage: "desktopcomputer")
                    .labelStyle(.iconOnly)
            } else {
                Text(
                    store.machineFilter.isEmpty
                        ? "All machines"
                        : (store.endpoints.first { $0.daemonID == store.machineFilter }?.name
                            ?? store.machineFilter))
            }
        }
        .menuStyle(.button)
        .tint(store.machineFilter.isEmpty ? nil : Color.accentColor)
        .accessibilityIdentifier("board.filter.machine")
        .help("Filter cards by their execution machine")
    }

    private var stateFilterTitle: String {
        view.stateTitle.isEmpty ? "All states" : view.stateTitle
    }

    var body: some View {
        FluidPaneChrome(background: .clear, spacing: 7) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.selectedBoard?.name ?? "Board")
                        .font(DieterFont.paneTitle).lineLimit(1)
                    Text(view.summary)
                        .font(DieterFont.subtitle)
                        .foregroundStyle(DieterTheme.tertiary).lineLimit(1)
                }
                .layoutPriority(1)
                Spacer(minLength: 8)
                if workspacePresented && store.kanbanPresentedAlongsideConversation {
                    Button {
                        store.kanbanPresentedAlongsideConversation = false
                    } label: {
                        ConversationWorkspaceSymbol(
                            systemName: "rectangle.3.group",
                            selected: true,
                            frameSize: ConversationWorkspaceChromeMetrics.actionSize
                        )
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Hide Kanban")
                    .accessibilityLabel("Hide Kanban")
                    .accessibilityIdentifier("board.kanban-toggle")
                }
            }
        } secondary: {
            ViewThatFits(in: .horizontal) {
                fullToolbar.fixedSize(horizontal: true, vertical: false)
                compactToolbar.fixedSize(horizontal: true, vertical: false)
                collapsedToolbar.fixedSize(horizontal: true, vertical: false)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .font(.callout)
            .controlSize(.regular)
            .buttonStyle(.bordered)
        }
        .onChange(of: store.selectedBoard?.labels.map(\.id) ?? [], initial: true) { _, labels in
            if !store.labelFilter.isEmpty && !labels.contains(store.labelFilter) {
                store.labelFilter = ""
            }
        }
    }

    private var fullToolbar: some View {
        HStack(spacing: 8) {
            if store.selectedBoard?.labels.isEmpty == false {
                allCardsButton(compact: false)
            }
            labelShelf
            stateFilterMenu(iconOnly: false)
            machineFilterMenu(iconOnly: false)
            boardSettingsButton
            Button {
                store.labelsPresented = true
            } label: {
                Label("Labels", systemImage: "tag")
            }
            .help("Manage board labels")
            newCardButton(iconOnly: false)
            quickTaskButton
        }
    }

    private var compactToolbar: some View {
        HStack(spacing: 8) {
            if store.selectedBoard?.labels.isEmpty == false {
                allCardsButton(compact: true)
                labelFilterMenu
            }
            stateFilterMenu(iconOnly: true)
            machineFilterMenu(iconOnly: true)
            boardSettingsButton.labelStyle(.iconOnly)
            newCardButton(iconOnly: true)
            quickTaskButton.labelStyle(.iconOnly)
        }
    }

    private var collapsedToolbar: some View {
        HStack(spacing: 8) {
            Menu {
                if store.selectedBoard?.labels.isEmpty == false {
                    labelFilterOptions
                    Divider()
                }
                stateFilterOptions
                Divider()
                machineFilterOptions
                Divider()
                Button("Manage labels…", systemImage: "tag") { store.labelsPresented = true }
            } label: {
                Label("Filters", systemImage: "line.3.horizontal.decrease")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.button)
            .tint(hasActiveFilters ? Color.accentColor : nil)
            .help("Filter cards")
            .accessibilityIdentifier("board.filters")
            boardSettingsButton.labelStyle(.iconOnly)
            newCardButton(iconOnly: true)
            quickTaskButton.labelStyle(.iconOnly)
        }
    }

    private var hasActiveFilters: Bool {
        !store.labelFilter.isEmpty || store.stateFilter != .all || !store.machineFilter.isEmpty
    }

    private func stateFilterMenu(iconOnly: Bool) -> some View {
        Menu {
            stateFilterOptions
        } label: {
            if iconOnly {
                Label("State", systemImage: "line.3.horizontal.decrease")
                    .labelStyle(.iconOnly)
            } else {
                Text(stateFilterTitle)
            }
        }
        .menuStyle(.button)
        .tint(store.stateFilter == .all ? nil : Color.accentColor)
        .accessibilityIdentifier("board.filter.state")
        .help("Filter cards by state")
    }

    private var labelFilterMenu: some View {
        Menu {
            labelFilterOptions
            Divider()
            Button("Manage labels…", systemImage: "tag") { store.labelsPresented = true }
        } label: {
            Label("Labels", systemImage: "tag")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.button)
        .tint(store.labelFilter.isEmpty ? nil : Color.accentColor)
        .help("Filter cards by label")
        .accessibilityIdentifier("board.filter.labels")
    }

    private func newCardButton(iconOnly: Bool) -> some View {
        Button {
            store.createConversationPresented = true
        } label: {
            if iconOnly {
                Label("New card", systemImage: "rectangle.badge.plus")
                    .labelStyle(.iconOnly)
            } else {
                Label("New card", systemImage: "rectangle.badge.plus")
            }
        }
        .help("New card")
        .accessibilityIdentifier("board.new-card")
    }

    private var boardSettingsButton: some View {
        Button {
            store.archivePolicyPresented = true
        } label: {
            Label("Board settings", systemImage: "gearshape")
        }
        .fixedSize()
        .help("Board settings")
        .accessibilityIdentifier("board.settings")
        .smokeTarget("board.settings")
    }

    private func allCardsButton(compact: Bool) -> some View {
        Button {
            store.labelFilter = ""
        } label: {
            HStack(spacing: 5) {
                if store.labelFilter.isEmpty {
                    Image(systemName: "checkmark")
                }
                Text("\(compact ? "All" : "All cards") · \(view.total)")
                    .lineLimit(1)
            }
        }
        .tint(store.labelFilter.isEmpty ? Color.accentColor : nil)
        .fixedSize()
        .accessibilityIdentifier("board.filter.all")
        .accessibilityValue(store.labelFilter.isEmpty ? "Selected" : "Not selected")
    }

    @ViewBuilder private var labelShelf: some View {
        if let board = store.selectedBoard, !board.labels.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(board.labels, id: \.id) { label in
                        BoardLabelShelfChip(
                            label: label, boardID: board.id,
                            count: Int(view.labelCounts[label.id, default: 0]),
                            selected: store.labelFilter == label.id
                        ) {
                            store.labelFilter = store.labelFilter == label.id ? "" : label.id
                        }
                    }
                }
            }
            .frame(minWidth: 74, maxWidth: .infinity, alignment: .leading)
        }
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
    }

    private var quickTaskButton: some View {
        Button {
            store.quickTaskForm.selectBoardContext(projectID: store.selectedProjectID, boardID: store.selectedBoardID)
            quickTaskPresented = true
        } label: {
            Label("Quick task", systemImage: "sparkles")
        }
        .buttonStyle(.borderedProminent)
        .help("Create a task from its story")
        .accessibilityIdentifier("board.quick-task")
        .smokeTarget("board.quick-task")
        .popover(isPresented: $quickTaskPresented, arrowEdge: .top) {
            QuickTaskPopover(isPresented: $quickTaskPresented, draft: store.quickTaskForm)
                .environment(store)
        }
    }
}

struct BoardLabelShelfChip: View {
    let label: Dieter_V1_Label
    let boardID: String
    let count: Int
    let selected: Bool
    let select: () -> Void

    private var color: Color { Color(hex: label.color) ?? DieterTheme.shell }

    var body: some View {
        Button(action: select) {
            HStack(spacing: 5) {
                if selected {
                    Image(systemName: "checkmark").foregroundStyle(color)
                } else {
                    Circle().fill(color).frame(width: 6, height: 6)
                }
                Text(label.name).lineLimit(1)
                Text("· \(count)").foregroundStyle(.secondary)
            }
            .draggable(BoardLabelDragPayload(labelID: label.id, boardID: boardID).encoded) {
                BoardLabelDragPreview(label: label)
            }
        }
        .buttonStyle(.bordered)
        .tint(selected ? color : nil)
        .fixedSize()
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
        .background(DieterTheme.elevated, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(color.opacity(0.48)))
        .shadow(color: Color.black.opacity(0.42), radius: 16, y: 7)
    }
}
