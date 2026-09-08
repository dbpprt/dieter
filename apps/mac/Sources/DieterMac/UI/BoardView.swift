import AppKit
import DieterAPI
import SwiftUI
import UniformTypeIdentifiers

struct BoardCardDragPayload: Sendable {
    let cardID: String
    let boardID: String
    let sourceLane: String

    var encoded: String { "board-card|\(boardID)|\(sourceLane)|\(cardID)" }

    init(cardID: String, boardID: String, sourceLane: String) {
        self.cardID = cardID
        self.boardID = boardID
        self.sourceLane = sourceLane
    }

    init?(_ encoded: String) {
        let values = encoded.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard values.count == 4, values[0] == "board-card", !values[1].isEmpty, !values[3].isEmpty else { return nil }
        boardID = values[1]
        sourceLane = values[2]
        cardID = values[3]
    }
}

struct BoardLabelDragPayload: Sendable {
    let labelID: String
    let boardID: String

    var encoded: String { "board-label|\(boardID)|\(labelID)" }

    init(labelID: String, boardID: String) {
        self.labelID = labelID
        self.boardID = boardID
    }

    init?(_ encoded: String) {
        let values = encoded.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard values.count == 3, values[0] == "board-label", !values[1].isEmpty, !values[2].isEmpty else { return nil }
        boardID = values[1]
        labelID = values[2]
    }
}

enum BoardLabelAssignment {
    static func adding(_ labelID: String, to ids: [String]) -> [String] {
        ids.contains(labelID) ? ids : ids + [labelID]
    }
}

enum BoardCardEditingPolicy {
    static func canEditDraft(_ card: Dieter_V1_Card) -> Bool {
        card.lane.caseInsensitiveCompare("todo") == .orderedSame &&
            card.mergedIntoCardID.isEmpty &&
            card.initialPromptSentAt.isEmpty &&
            !card.initialPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum BoardCardStartPolicy {
    static func runningLaneID(in board: Dieter_V1_Board?) -> String? {
        guard let board else { return nil }
        return board.lanes.first { $0.id.caseInsensitiveCompare("running") == .orderedSame }?.id
            ?? board.lanes.first { $0.name.caseInsensitiveCompare("running") == .orderedSame }?.id
    }

    static func canStart(
        _ card: Dieter_V1_Card,
        board: Dieter_V1_Board?,
        hasDraftAttachments: Bool = false
    ) -> Bool {
        card.scope == "board" &&
            card.lane.caseInsensitiveCompare("todo") == .orderedSame &&
            card.mergedIntoCardID.isEmpty &&
            card.initialPromptSentAt.isEmpty &&
            (!card.initialPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || hasDraftAttachments) &&
            runningLaneID(in: board) != nil
    }

    static func optimisticCard(
        _ card: Dieter_V1_Card,
        board: Dieter_V1_Board?,
        hasDraftAttachments: Bool = false
    ) -> Dieter_V1_Card? {
        guard canStart(card, board: board, hasDraftAttachments: hasDraftAttachments),
              let runningLaneID = runningLaneID(in: board) else { return nil }
        var card = card
        card.lane = runningLaneID
        card.runtime = "starting"
        return card
    }
}

enum BoardDropOrdering {
    static func position(before targetCardID: String, movingCardID: String, cards: [Dieter_V1_Card]) -> Int64? {
        let remaining = cards.filter { $0.id != movingCardID }.sorted { $0.position < $1.position }
        guard let index = remaining.firstIndex(where: { $0.id == targetCardID }) else { return nil }
        let upper = remaining[index].position
        guard index > 0 else { return upper - 1_024 }
        let lower = remaining[index - 1].position
        guard upper > lower + 1 else { return upper }
        return lower + ((upper - lower) / 2)
    }
}

enum BoardCardSortDirection {
    case descending
    case ascending

    var toggled: Self { self == .descending ? .ascending : .descending }
    var title: String { self == .descending ? "Newest first" : "Oldest first" }
    var systemImage: String { self == .descending ? "arrow.down" : "arrow.up" }
}

enum BoardCardOrdering {
    static func sorted(
        _ cards: [Dieter_V1_Card],
        direction: BoardCardSortDirection = .descending
    ) -> [Dieter_V1_Card] {
        cards.sorted { left, right in
            let leftDate = createdAt(left.createdAt)
            let rightDate = createdAt(right.createdAt)
            switch (leftDate, rightDate) {
            case let (leftDate?, rightDate?) where leftDate != rightDate:
                return direction == .descending ? leftDate > rightDate : leftDate < rightDate
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return direction == .descending ? left.id > right.id : left.id < right.id
            }
        }
    }

    private static func createdAt(_ value: String) -> Date? {
        DieterTimestamp.date(from: value)
    }
}

enum ConversationPaneSizing {
    static let minimumWidth: CGFloat = 320
    static let defaultWidth: CGFloat = 460
    static let maximumWidth: CGFloat = 720
    static let minimumBoardWidth: CGFloat = 520
    static let dividerWidth: CGFloat = 7
    static let maximumWorkspaceFraction: CGFloat = 0.42

    static func clamped(_ width: CGFloat) -> CGFloat {
        min(max(width, minimumWidth), maximumWidth)
    }

    static func resolvedWidth(_ preferredWidth: CGFloat, workspaceWidth: CGFloat) -> CGFloat {
        let availableMaximum = max(minimumWidth, workspaceWidth - minimumBoardWidth - dividerWidth)
        let proportionalMaximum = max(minimumWidth, workspaceWidth * maximumWorkspaceFraction)
        return min(clamped(preferredWidth), min(maximumWidth, availableMaximum, proportionalMaximum))
    }
}

enum KanbanLaneSizing {
    static let horizontalPadding: CGFloat = 14
    static let spacing: CGFloat = 9
    // Lanes never squeeze below a readable card width; the board falls back to
    // horizontal scrolling instead.
    static let minimumWidth: CGFloat = 264

    static func laneWidth(availableWidth: CGFloat, laneCount: Int) -> CGFloat {
        guard laneCount > 0 else { return 0 }
        let gaps = spacing * CGFloat(max(0, laneCount - 1))
        let fittedWidth = (availableWidth - (horizontalPadding * 2) - gaps) / CGFloat(laneCount)
        return max(minimumWidth, fittedWidth)
    }

    static func contentWidth(availableWidth: CGFloat, laneCount: Int) -> CGFloat {
        guard laneCount > 0 else { return availableWidth }
        return (horizontalPadding * 2) + (laneWidth(availableWidth: availableWidth, laneCount: laneCount) * CGFloat(laneCount)) + (spacing * CGFloat(max(0, laneCount - 1)))
    }
}

enum BoardPresentationState: Equatable {
    case loading
    case empty
    case loaded

    static func resolve(
        hasLoadedWorkspace: Bool,
        selectedBoardID: String,
        hasSelectedBoard: Bool
    ) -> Self {
        if hasSelectedBoard { return .loaded }
        if !hasLoadedWorkspace || !selectedBoardID.isEmpty { return .loading }
        return .empty
    }
}

private struct ConversationResizeDivider: View {
    let onChanged: (CGFloat) -> Void
    let onEnded: () -> Void
    @State private var hovering = false

    var body: some View {
        ZStack {
            Rectangle().fill(Color.clear)
            Rectangle()
                .fill(hovering ? DieterTheme.shell.opacity(0.62) : DieterTheme.paneSeparator)
                .frame(width: hovering ? 2 : 1)
        }
        .frame(width: ConversationPaneSizing.dividerWidth)
        .ignoresSafeArea(.container, edges: .top)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { onChanged($0.translation.width) }
                .onEnded { _ in onEnded() }
        )
        .onHover { isHovering in
            if isHovering, !hovering { NSCursor.resizeLeftRight.push() }
            if !isHovering, hovering { NSCursor.pop() }
            hovering = isHovering
        }
        .onDisappear {
            if hovering { NSCursor.pop() }
        }
        .accessibilityLabel("Resize conversation")
        .accessibilityIdentifier("board.conversation-divider")
    }
}

struct BoardView: View {
    @Environment(DieterStore.self) private var store
    @AppStorage("dieter.conversationPaneWidth") private var conversationPaneWidth = Double(ConversationPaneSizing.defaultWidth)
    @State private var conversationDragStartWidth: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            let width = ConversationPaneSizing.resolvedWidth(
                CGFloat(conversationPaneWidth),
                workspaceWidth: geometry.size.width
            )

            HStack(spacing: 0) {
                boardContent
                    .frame(maxWidth: .infinity)
                    .clipped()

                if store.selectedCardID != nil {
                    ConversationResizeDivider(
                        onChanged: { translation in
                            let startWidth = conversationDragStartWidth ?? width
                            if conversationDragStartWidth == nil { conversationDragStartWidth = startWidth }
                            let next = ConversationPaneSizing.resolvedWidth(
                                startWidth - translation,
                                workspaceWidth: geometry.size.width
                            )
                            if abs(Double(next) - conversationPaneWidth) > 0.5 {
                                conversationPaneWidth = Double(next)
                            }
                        },
                        onEnded: { conversationDragStartWidth = nil }
                    )

                    ConversationView(compact: true)
                        .frame(width: width)
                }
            }
        }
    }

    private var boardContent: some View {
        Group {
            switch BoardPresentationState.resolve(
                hasLoadedWorkspace: store.hasLoadedWorkspace,
                selectedBoardID: store.selectedBoardID,
                hasSelectedBoard: store.selectedBoard != nil
            ) {
            case .loading:
                VStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                    Text("Loading board…")
                        .font(DieterFont.meta)
                        .foregroundStyle(DieterTheme.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Loading board")
                .accessibilityIdentifier("board.loading")
            case .loaded:
                VStack(spacing: 0) {
                    BoardHeader()
                    if let board = store.selectedBoard {
                        KanbanView(board: board)
                    }
                }
            case .empty:
                VStack(spacing: 0) {
                    BoardHeader()
                    ContentUnavailableView(
                        "No board selected",
                        systemImage: "rectangle.split.3x1",
                        description: Text("Create or select a board for this project.")
                    )
                }
            }
        }
    }
}

struct BoardHeader: View {
    @Environment(DieterStore.self) private var store
    @State private var quickTaskPresented = false

    private var needsAttention: Int {
        store.boardCards.filter { ["waiting_for_user", "review"].contains($0.runtime) }.count
    }

    private var boardMetadata: String {
        let count = store.boardCards.count
        var parts = ["board", "\(count) conversation\(count == 1 ? "" : "s")"]
        if needsAttention > 0 { parts.append("\(needsAttention) needs you") }
        return parts.joined(separator: " · ")
    }

    private var retentionTitle: String {
        let value = store.selectedBoard?.doneArchivePolicy ?? "never"
        if value == "never" { return "Done: Never" }
        return "Done: " + value
            .replacingOccurrences(of: "after_", with: "")
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }

    var body: some View {
        @Bindable var store = store
        FluidPaneChrome(background: DieterTheme.background, spacing: 7) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 7) {
                        Text(store.selectedBoard?.name ?? "Board")
                            .font(DieterFont.paneTitle).lineLimit(1)
                        Menu {
                            Button("Create board…") { store.createBoardPresented = true }
                            Button("Rename board…") {
                                if let board = store.selectedBoard { store.presentRenameBoard(boardID: board.id) }
                            }
                            .disabled(store.selectedBoard == nil)
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8, weight: .bold)).foregroundStyle(DieterTheme.tertiary)
                                .frame(width: 16, height: 16)
                        }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    }
                    Text(boardMetadata)
                        .font(DieterFont.subtitle)
                        .foregroundStyle(DieterTheme.tertiary).lineLimit(1)
                }
                .layoutPriority(1)
                Spacer(minLength: 8)
                Button { store.projectContextPresented = true } label: { Image(systemName: "ellipsis") }
                    .buttonStyle(DieterIconButtonStyle()).help("Project context")
            }
        } secondary: {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 7) {
                Button {
                    store.labelFilter = ""
                } label: {
                    HStack(spacing: 6) {
                        if store.labelFilter.isEmpty { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)) }
                        Text("All cards · \(store.boardCards.count)").lineLimit(1)
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(store.labelFilter.isEmpty ? DieterTheme.text : DieterTheme.subtle)
                    .padding(.horizontal, 10).frame(height: 28)
                    .background(store.labelFilter.isEmpty ? DieterTheme.elevated : DieterTheme.surface, in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)

                if let board = store.selectedBoard, !board.labels.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 7) {
                            ForEach(board.labels, id: \.id) { label in
                                BoardLabelShelfChip(
                                    label: label,
                                    boardID: board.id,
                                    count: store.boardProjection.labelCounts[label.id, default: 0],
                                    selected: store.labelFilter == label.id
                                ) {
                                    store.labelFilter = store.labelFilter == label.id ? "" : label.id
                                }
                            }
                        }
                    }
                    .frame(minWidth: 74, maxWidth: .infinity, alignment: .leading)
                }

                Menu {
                    Button("All states") { store.runtimeFilter = "" }
                    ForEach(["running", "review", "waiting", "completed", "failed"], id: \.self) { runtime in
                        Button(runtime.capitalized) { store.runtimeFilter = runtime }
                    }
                } label: { DieterChipLabel(title: store.runtimeFilter.isEmpty ? "All states" : store.runtimeFilter.capitalized) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()

                Button { store.archivePolicyPresented = true } label: {
                    DieterChipLabel(title: "Board settings", symbol: "gearshape")
                }
                .buttonStyle(.plain)

                Button { store.labelsPresented = true } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "tag").font(.system(size: 10, weight: .semibold))
                        Text("Labels")
                    }
                    .font(.caption2.weight(.medium)).foregroundStyle(DieterTheme.subtle)
                    .padding(.horizontal, 9).frame(height: 28)
                    .background(DieterTheme.surface, in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .help("Manage board labels")

                Button { store.createConversationPresented = true } label: {
                    Label("New card", systemImage: "rectangle.badge.plus")
                }
                .buttonStyle(DieterSecondaryButtonStyle())
                .accessibilityIdentifier("board.new-card")

                quickTaskButton(compact: false)
                }

                HStack(spacing: 7) {
                    Button {
                        store.labelFilter = ""
                    } label: {
                        HStack(spacing: 6) {
                            if store.labelFilter.isEmpty { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)) }
                            Text("All · \(store.boardCards.count)").lineLimit(1)
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(store.labelFilter.isEmpty ? DieterTheme.text : DieterTheme.subtle)
                        .padding(.horizontal, 10).frame(height: 28)
                        .background(store.labelFilter.isEmpty ? DieterTheme.elevated : DieterTheme.surface, in: RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)

                    if let board = store.selectedBoard, !board.labels.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 7) {
                                ForEach(board.labels, id: \.id) { label in
                                    BoardLabelShelfChip(
                                        label: label,
                                        boardID: board.id,
                                        count: store.boardProjection.labelCounts[label.id, default: 0],
                                        selected: store.labelFilter == label.id
                                    ) {
                                        store.labelFilter = store.labelFilter == label.id ? "" : label.id
                                    }
                                }
                            }
                        }
                        .frame(minWidth: 74, maxWidth: .infinity, alignment: .leading)
                    }

                    Menu {
                        Button("All states") { store.runtimeFilter = "" }
                        ForEach(["running", "review", "waiting", "completed", "failed"], id: \.self) { runtime in
                            Button(runtime.capitalized) { store.runtimeFilter = runtime }
                        }
                        Divider()
                        Button("Board settings…") { store.archivePolicyPresented = true }
                        Button("Manage labels…") { store.labelsPresented = true }
                    } label: {
                        DieterChipLabel(
                            title: store.runtimeFilter.isEmpty ? "Filters" : store.runtimeFilter.capitalized,
                            symbol: "line.3.horizontal.decrease"
                        )
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()

                    Menu {
                        Button("New card…") { store.createConversationPresented = true }
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 28, height: 28)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("New card")
                    .accessibilityIdentifier("board.new-card")

                    quickTaskButton(compact: true)
                }
            }
        }
    }

    private func quickTaskButton(compact: Bool) -> some View {
        Button { quickTaskPresented = true } label: {
            Label(compact ? "Quick" : "Quick task", systemImage: "sparkles")
        }
        .buttonStyle(DieterPrimaryButtonStyle())
        .help("Create a task from its story")
        .accessibilityIdentifier("board.quick-task")
        .smokeTarget("board.quick-task")
        .popover(isPresented: $quickTaskPresented, arrowEdge: .top) {
            QuickTaskPopover(isPresented: $quickTaskPresented)
                .environment(store)
        }
    }
}

struct QuickTaskDraft {
    static func optimisticTitle(from story: String) -> String {
        let firstLine = story
            .split(whereSeparator: { $0.isNewline })
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard firstLine.count > 80 else { return firstLine }
        let end = firstLine.index(firstLine.startIndex, offsetBy: 80)
        let prefix = String(firstLine[..<end])
        guard let boundary = prefix.lastIndex(of: " "), prefix.distance(from: prefix.startIndex, to: boundary) >= 40 else {
            return prefix
        }
        return String(prefix[..<boundary])
    }
}

struct QuickTaskPopover: View {
    @Environment(DieterStore.self) private var store
    @Binding var isPresented: Bool
    @State private var story = ""
    @State private var submitting = false
    @State private var settingsPresented = false
    @State private var provider = ""
    @State private var model = ""
    @State private var effort = ""
    @State private var providerOptions: [String: String] = [:]
    @State private var attachments: [Dieter_V1_MessagePart] = []
    @State private var fileImporterPresented = false
    @State private var attachmentDropTargeted = false
    @State private var initialized = false
    @State private var sourceURL: String
    private let capturedBrowser: Bool

    init(isPresented: Binding<Bool>, initialAttachments: [Dieter_V1_MessagePart] = [], sourceURL: String = "", capturedBrowser: Bool = false) {
        _isPresented = isPresented
        _attachments = State(initialValue: initialAttachments)
        _sourceURL = State(initialValue: sourceURL)
        self.capturedBrowser = capturedBrowser
    }
    @FocusState private var storyFocused: Bool

    private var cleanStory: String { story.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var lane: Dieter_V1_Lane? { store.selectedBoard?.lanes.first }
    private var selection: ConversationCreationSelection? {
        guard !provider.isEmpty else { return nil }
        return ConversationCreationSelection(provider: provider, model: model, effort: effort, workspaceMode: preferences.workspaceMode)
    }
    private var preferences: ConversationCreationPreferences {
        ConversationCreationPreferences.load(from: DieterAppearance.applicationDefaults())
    }
    private var defaultsSummary: String {
        let laneName = lane?.name ?? "Todo"
        let workspace = preferences.workspaceMode.title
        guard let selection,
              let harness = store.harnessCatalog.harnesses.first(where: { $0.id == selection.provider }),
              let model = harness.models.first(where: { $0.id == selection.model }) else {
            return "\(laneName) · \(workspace) · Agent defaults"
        }
        let fastMode = ProviderOptionValues.normalized(for: harness, model: model.id, saved: providerOptions)["fast_mode"] == "true"
        return "\(laneName) · \(workspace) · \(harness.name) / \(model.name)" + (fastMode ? " · Fast" : "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: "sparkles")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DieterTheme.shell)
                    .frame(width: 30, height: 30)
                    .background(DieterTheme.shellDeep.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Quick task").font(.system(size: 15, weight: .semibold))
                    Text("Enter the story. GPT Spark writes a 4–6 word title.")
                        .font(.system(size: 11)).foregroundStyle(DieterTheme.tertiary)
                }
                Spacer()
                Button { settingsPresented.toggle() } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 14))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Task agent settings")
                .accessibilityLabel("Task agent settings")
                .accessibilityIdentifier("quick-task.settings")
                .disabled(submitting)
                .popover(isPresented: $settingsPresented, arrowEdge: .trailing) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Task agent").font(.headline)
                        HarnessFields(provider: $provider, model: $model, effort: $effort, providerOptions: $providerOptions)
                        HStack {
                            Spacer()
                            Button("Done") { settingsPresented = false }
                                .buttonStyle(DieterSecondaryButtonStyle())
                        }
                    }
                    .padding(16)
                    .frame(width: 310)
                    .background(DieterTheme.background)
                    .environment(store)
                }
            }

            TextField("What should the agent accomplish?", text: $story, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13)).lineSpacing(2).lineLimit(3...7)
                .focused($storyFocused)
                .padding(.horizontal, 12).padding(.vertical, 11)
                .frame(minHeight: 92, alignment: .topLeading)
                .background(DieterTheme.input, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(storyFocused ? DieterTheme.shellDeep : DieterTheme.strongBorder, lineWidth: storyFocused ? 1.5 : 1))
                .accessibilityIdentifier("quick-task.story")
                .smokeTarget("quick-task.story")
                .attachmentDropTarget(isTargeted: $attachmentDropTargeted) { providers in
                    Task {
                        do { attachments = try await store.attachmentParts(providers, appendingTo: attachments) }
                        catch { store.show(error) }
                    }
                }

            HStack(spacing: 8) {
                Button { fileImporterPresented = true } label: {
                    Label("Attach", systemImage: "paperclip")
                }
                .buttonStyle(DieterSecondaryButtonStyle())
                .accessibilityIdentifier("quick-task.attach")
                Text("Paste or drop screenshots · 4 files, 6 MB total")
                    .font(.caption2).foregroundStyle(DieterTheme.tertiary)
            }
            if !attachments.isEmpty {
                AttachmentPreviewStrip(attachments: $attachments)
                    .accessibilityIdentifier("quick-task.attachments")
                    .smokeTarget("quick-task.attachments")
            }

            if capturedBrowser {
                TextField("Page URL (optional)", text: $sourceURL)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("quick-task.source-url")
                    .smokeTarget("quick-task.source-url")
                if sourceURL.isEmpty {
                    Text("The browser URL couldn’t be read. You can paste it here.")
                        .font(.caption2).foregroundStyle(DieterTheme.tertiary)
                }
            }

            HStack(spacing: 7) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 10, weight: .semibold))
                Text(defaultsSummary).lineLimit(2)
            }
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(DieterTheme.tertiary)

            HStack(spacing: 9) {
                Button("Cancel") { isPresented = false }
                    .buttonStyle(DieterSecondaryButtonStyle())
                Spacer()
                Button {
                    Task { await submit() }
                } label: {
                    HStack(spacing: 7) {
                        if submitting { ProgressView().controlSize(.mini) }
                        else { Image(systemName: "sparkles") }
                        Text("Add task")
                    }
                }
                .buttonStyle(DieterPrimaryButtonStyle())
                .disabled(cleanStory.isEmpty || submitting || store.selectedProject == nil || store.selectedBoard == nil)
                .keyboardShortcut(.return, modifiers: [.command])
                .accessibilityIdentifier("quick-task.create")
            }
        }
        .padding(17)
        .frame(width: 390)
        .background(DieterTheme.background)
        .attachmentIntake(store: store, importerPresented: $fileImporterPresented, attachments: $attachments)
        .task {
            if !initialized {
                let initial = preferences.resolved(in: store.harnessCatalog.harnesses)
                provider = initial?.provider ?? ""
                model = initial?.model ?? ""
                effort = initial?.effort ?? ""
                let harness = store.harnessCatalog.harnesses.first { $0.id == provider }
                providerOptions = ProviderOptionValues.defaults(for: harness, model: model)
                initialized = true
            }
            await Task.yield()
            storyFocused = true
        }
        .onExitCommand { isPresented = false }
    }

    private func submit() async {
        let story = cleanStory
        guard !story.isEmpty else { return }
        submitting = true
        let resolved = selection
        let harness = resolved.flatMap { value in store.harnessCatalog.harnesses.first { $0.id == value.provider } }
        var workspace = ConversationWorkspaceDraft()
        workspace.mode = preferences.workspaceMode
        workspace.baseBranch = store.selectedProject?.baseBranch ?? ""
        await store.createConversation(
            title: QuickTaskDraft.optimisticTitle(from: story),
            prompt: story + (sourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : "\n\nPage URL: " + sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)),
            attachments: attachments,
            chat: false,
            provider: resolved?.provider ?? "",
            model: resolved?.model ?? "",
            effort: resolved?.effort ?? "",
            providerOptions: ProviderOptionValues.normalized(for: harness, model: resolved?.model ?? "", saved: providerOptions),
            deferred: lane?.id.lowercased() != "running",
            lane: lane?.id ?? "todo",
            workspace: workspace,
            autoGenerateTitle: true
        )
        submitting = false
        isPresented = false
    }
}

private struct BoardLabelShelfChip: View {
    let label: Dieter_V1_Label
    let boardID: String
    let count: Int
    let selected: Bool
    let select: () -> Void

    private var color: Color { Color(hex: label.color) ?? DieterTheme.shell }

    var body: some View {
        Button(action: select) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(label.name).lineLimit(1)
                Text("· \(count)").foregroundStyle(DieterTheme.tertiary)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(selected ? color : DieterTheme.subtle)
            .padding(.horizontal, 10).frame(height: 28)
            .background(color.opacity(selected ? 0.17 : 0.075), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(color.opacity(selected ? 0.5 : 0.2)))
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .draggable(BoardLabelDragPayload(labelID: label.id, boardID: boardID).encoded) {
                BoardLabelDragPreview(label: label)
            }
        }
        .buttonStyle(.plain)
        .help("Click to filter · Drag onto a card to assign")
        .accessibilityLabel("\(label.name), \(count) cards")
        .accessibilityHint("Click to filter. Drag onto a card to assign this label.")
    }
}

private struct BoardLabelDragPreview: View {
    let label: Dieter_V1_Label

    private var color: Color { Color(hex: label.color) ?? DieterTheme.shell }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "tag.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(color)
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

struct KanbanView: View {
    @Environment(DieterStore.self) private var store
    let board: Dieter_V1_Board
    @State private var laneSortDirections: [String: BoardCardSortDirection] = [:]

    private var lanes: [Dieter_V1_Lane] {
        if !board.lanes.isEmpty { return board.lanes }
        return ["backlog", "ready", "running", "review", "done"].map { id in
            var lane = Dieter_V1_Lane(); lane.id = id; lane.name = id.capitalized; return lane
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let laneWidth = KanbanLaneSizing.laneWidth(availableWidth: geometry.size.width, laneCount: lanes.count)
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: KanbanLaneSizing.spacing) {
                    ForEach(lanes, id: \.id) { lane in
                        let direction = laneSortDirections[lane.id] ?? .descending
                        LaneColumn(
                            lane: lane,
                            cards: BoardCardOrdering.sorted(
                                store.boardProjection.displayedCardsByLane[lane.id] ?? [],
                                direction: direction
                            ),
                            sortDirection: direction,
                            onToggleSort: { laneSortDirections[lane.id] = direction.toggled }
                        )
                            .frame(width: laneWidth)
                    }
                }
                .padding(.horizontal, KanbanLaneSizing.horizontalPadding).padding(.vertical, 12)
                .frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .topLeading)
            }
            .background(DieterTheme.background)
        }
    }
}

struct LaneColumn: View {
    @Environment(DieterStore.self) private var store
    let lane: Dieter_V1_Lane
    let cards: [Dieter_V1_Card]
    let sortDirection: BoardCardSortDirection
    let onToggleSort: () -> Void
    @State private var isDropTargeted = false
    @State private var pageIndex = 0

    private var page: LaneCardPage {
        LaneCardPage.resolve(total: cards.count, requestedPage: pageIndex)
    }

    private var visibleCards: ArraySlice<Dieter_V1_Card> {
        cards[page.lowerBound..<page.upperBound]
    }

    private var laneTint: Color {
        switch lane.id.lowercased() {
        case "running": DieterTheme.primary
        case "review": DieterTheme.amber
        case "done": DieterTheme.eyes
        default: DieterTheme.tertiary
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 7) {
                Circle().fill(laneTint).frame(width: 6, height: 6)
                Text(lane.name).font(.system(size: 12, weight: .semibold))
                Text("\(cards.count)").font(.system(size: 12)).foregroundStyle(DieterTheme.tertiary)
                Spacer()
                Button(action: onToggleSort) {
                    Image(systemName: sortDirection.systemImage)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DieterTheme.tertiary)
                        .frame(width: 20, height: 20)
                        .background(DieterTheme.raised, in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .help("\(sortDirection.title). Click to sort \(sortDirection.toggled.title.lowercased()).")
                .accessibilityLabel("\(lane.name) lane sorted \(sortDirection.title.lowercased())")
                .accessibilityHint("Sort \(sortDirection.toggled.title.lowercased())")
                .accessibilityIdentifier("lane-sort.\(lane.id)")
                Button { store.createConversationPresented = true } label: { Image(systemName: "plus").font(.system(size: 10, weight: .semibold)).foregroundStyle(DieterTheme.tertiary) }.buttonStyle(.plain)
            }.padding(.horizontal, 6).padding(.top, 2)
            ScrollView {
                // Board lanes are intentionally bounded and use an eager stack.
                // On macOS, lazy placement can enter an anchor-translation loop
                // when variable-height cards carry menus, sheets, and drop targets.
                VStack(spacing: 0) {
                    ForEach(visibleCards, id: \.id) { card in
                        LaneInsertionTarget(laneID: lane.id, beforeCardID: card.id, cards: cards)
                        BoardCardView(card: card)
                            .opacity(store.movingCardIDs.contains(card.id) ? 0.48 : 1)
                            .help("Drag to move \(card.title) to another lane")
                    }
                    LaneInsertionTarget(laneID: lane.id, beforeCardID: nil, cards: cards)
                    if cards.isEmpty {
                        VStack(spacing: 7) {
                            Image(systemName: isDropTargeted ? "arrow.down.circle.fill" : "arrow.down.circle").font(.system(size: 17))
                            Text(isDropTargeted ? "Release to move" : "Drop cards here")
                        }
                            .font(.caption).foregroundStyle(isDropTargeted ? DieterTheme.shell : DieterTheme.tertiary)
                            .frame(maxWidth: .infinity).padding(.vertical, 28)
                            .overlay(RoundedRectangle(cornerRadius: 9).stroke(isDropTargeted ? DieterTheme.shell.opacity(0.55) : DieterTheme.border, style: .init(dash: [5])))
                    }
                }
            }
            if page.pageCount > 1 {
                HStack(spacing: 8) {
                    Button { pageIndex = max(0, page.page - 1) } label: {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(!page.canGoBackward)
                    .accessibilityLabel("Previous \(lane.name) cards")
                    Text(page.rangeLabel)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(DieterTheme.tertiary)
                        .frame(maxWidth: .infinity)
                    Button { pageIndex = min(page.pageCount - 1, page.page + 1) } label: {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(!page.canGoForward)
                    .accessibilityLabel("Next \(lane.name) cards")
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 6)
            }
        }
        .padding(10)
        .background(isDropTargeted ? DieterTheme.shellDeep.opacity(0.08) : DieterTheme.surface.opacity(0.45), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(isDropTargeted ? DieterTheme.shell.opacity(0.32) : DieterTheme.border))
        .animation(.easeOut(duration: 0.14), value: isDropTargeted)
        .dropDestination(for: String.self) { values, _ in
            guard let value = values.first, let payload = BoardCardDragPayload(value),
                  payload.boardID == store.selectedBoardID,
                  let card = store.state.cards.first(where: { $0.id == payload.cardID }) else { return false }
            if payload.sourceLane == lane.id, cards.last?.id == payload.cardID { return true }
            Task { await store.move(card, lane: lane.id) }
            return true
        } isTargeted: { isDropTargeted = $0 }
        .onChange(of: cards.count) { _, _ in pageIndex = page.page }
        .onChange(of: sortDirection) { _, _ in pageIndex = 0 }
    }
}

private struct LaneInsertionTarget: View {
    @Environment(DieterStore.self) private var store
    let laneID: String
    let beforeCardID: String?
    let cards: [Dieter_V1_Card]
    @State private var targeted = false

    var body: some View {
        ZStack {
            Color.clear
            if targeted {
                HStack(spacing: 6) {
                    Circle().fill(DieterTheme.shell).frame(width: 5, height: 5)
                    Capsule().fill(DieterTheme.shell).frame(height: 2)
                }.padding(.horizontal, 2)
            }
        }
        .frame(height: beforeCardID == nil ? 12 : 9)
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { values, _ in
            guard let value = values.first, let payload = BoardCardDragPayload(value),
                  payload.boardID == store.selectedBoardID,
                  let card = store.state.cards.first(where: { $0.id == payload.cardID }) else { return false }
            if payload.sourceLane == laneID, beforeCardID == payload.cardID { return true }
            let position: Int64?
            if let beforeCardID {
                position = BoardDropOrdering.position(before: beforeCardID, movingCardID: payload.cardID, cards: cards)
            } else {
                position = nil
            }
            Task { await store.move(card, lane: laneID, position: position) }
            return true
        } isTargeted: { targeted = $0 }
        .animation(.easeOut(duration: 0.12), value: targeted)
    }
}

enum BoardAgentStatus: Equatable {
    case running, failed, idle

    static func resolve(_ card: Dieter_V1_Card) -> Self {
        let active = Set(["starting", "running", "active", "working", "streaming", "cancelling"])
        let status = card.runtime.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if active.contains(status) || card.activeSubagents.contains(where: { active.contains($0.status.lowercased()) }) {
            return .running
        }
        return ["failed", "error"].contains(status) ? .failed : .idle
    }

    var color: Color {
        switch self {
        case .running: .green
        case .failed: .orange
        case .idle: .white
        }
    }

    var label: String {
        switch self {
        case .running: "Agent running"
        case .failed: "Agent turn failed"
        case .idle: "No agent work in progress"
        }
    }
}

private struct BoardCardDragPreview: View {
    let card: Dieter_V1_Card

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.on.rectangle.angled").foregroundStyle(DieterTheme.shell)
            VStack(alignment: .leading, spacing: 3) {
                Text(card.title.isEmpty ? "Untitled card" : card.title).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                HStack(spacing: 6) {
                    Circle().fill(BoardAgentStatus.resolve(card).color).frame(width: 5, height: 5)
                    Text(card.runtime.capitalized).font(.system(size: 9, weight: .medium)).foregroundStyle(DieterTheme.tertiary)
                }
            }
            Spacer(minLength: 8)
        }
        .padding(12).frame(width: 240)
        .background(DieterTheme.elevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(DieterTheme.shell.opacity(0.4)))
        .shadow(color: Color.black.opacity(0.42), radius: 18, y: 8)
    }
}

/// Delay the single-click action until the double-click recognizer has failed.
/// Opening the conversation on the first mouse-up can otherwise remove the
/// card before the second click has a chance to open its editor.
private struct BoardCardClickStyle: PrimitiveButtonStyle {
    let edit: () -> Void

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .gesture(
                TapGesture(count: 2)
                    .exclusively(before: TapGesture(count: 1))
                    .onEnded { action in
                        switch action {
                        case .first: edit()
                        case .second: configuration.trigger()
                        }
                    }
            )
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(keys: [.return, .space]) { _ in
                configuration.trigger()
                return .handled
            }
            .accessibilityAction { configuration.trigger() }
            .accessibilityAction(named: "Edit card", edit)
    }
}

struct BoardCardView: View {
    @Environment(DieterStore.self) private var store
    let card: Dieter_V1_Card
    @State private var renamePresented = false
    @State private var editPresented = false
    @State private var renameText = ""
    @State private var hovering = false
    @State private var cardDrop = BoardCardDropState()
    private var labelDropTargeted: Bool { cardDrop.targeted && cardDrop.payload.flatMap(BoardLabelDragPayload.init) != nil }

    init(card: Dieter_V1_Card, dropState: BoardCardDropState = BoardCardDropState()) {
        self.card = card
        _cardDrop = State(initialValue: dropState)
    }

    var labels: [Dieter_V1_Label] { store.selectedBoard?.labels.filter { card.labelIds.contains($0.id) } ?? [] }
    private func canMergePayload(_ value: String) -> Bool {
        guard let payload = BoardCardDragPayload(value),
              let source = store.state.cards.first(where: { $0.id == payload.cardID }) else { return false }
        return BoardCardMergePolicy.canMerge(source, into: card)
    }

    private func performCardDrop(_ value: String, merge: Bool) -> Bool {
        if let payload = BoardLabelDragPayload(value) {
            guard payload.boardID == store.selectedBoardID,
                  store.selectedBoard?.labels.contains(where: { $0.id == payload.labelID }) == true else { return false }
            let ids = BoardLabelAssignment.adding(payload.labelID, to: card.labelIds)
            guard ids != card.labelIds else { return true }
            Task { await store.setLabels(card, ids: ids) }
            return true
        }
        guard let payload = BoardCardDragPayload(value),
              payload.boardID == store.selectedBoardID,
              let dragged = store.state.cards.first(where: { $0.id == payload.cardID }) else { return false }
        guard payload.cardID != card.id else { return true }
        if merge {
            Task { await store.merge(dragged, into: card) }
            return true
        }
        let laneCards = store.displayedCards.filter { $0.lane == card.lane }.sorted { $0.position < $1.position }
        let position = BoardDropOrdering.position(before: card.id, movingCardID: payload.cardID, cards: laneCards)
        Task { await store.move(dragged, lane: card.lane, position: position) }
        return true
    }

    private var starting: Bool { store.pendingCardStarts[card.id] != nil }
    private var canStart: Bool { BoardCardStartPolicy.canStart(card, board: store.selectedBoard) }
    private var showsRunAction: Bool { canStart || starting }
    private var runActionAccessibilityLabel: String {
        let title = card.title.isEmpty ? "card" : card.title
        return starting ? "Starting \(title)" : "Run \(title)"
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Button { Task { await store.openConversation(cardID: card.id) } } label: {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .top) {
                    Text(card.title.isEmpty ? "Untitled card" : card.title).font(.system(size: 13, weight: .semibold)).multilineTextAlignment(.leading).lineLimit(3)
                    Spacer(minLength: 4)
                    Circle().fill(BoardAgentStatus.resolve(card).color).frame(width: 6, height: 6).padding(.top, 5)
                        .help(BoardAgentStatus.resolve(card).label)
                        .accessibilityLabel(BoardAgentStatus.resolve(card).label)
                }
                if card.hasTokenUsage { TaskTokenUsageBadge(usage: card.tokenUsage) }
                if !card.summary.isEmpty { Text(card.summary).font(.system(size: 11)).foregroundStyle(DieterTheme.subtle).lineLimit(3).multilineTextAlignment(.leading) }
                if !labels.isEmpty {
                    FlowLabels(labels: labels)
                }
                HStack(spacing: 7) {
                    StatusPill(text: card.runtime, color: runtimeColor(card.runtime))
                    if !card.workspaceMode.isEmpty { WorkspaceSummaryBadge(card: card, compact: true) }
                    if !card.model.isEmpty { Text(card.model).font(.system(size: 10)).foregroundStyle(DieterTheme.tertiary).lineLimit(1) }
                    Spacer()
                    let age = BoardCardActivityText.compact(
                        updatedAt: card.updatedAt,
                        lastActivityAt: card.lastActivityAt,
                        relativeTo: .now
                    )
                    if !age.isEmpty {
                        Text(age)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(DieterTheme.tertiary)
                            .accessibilityLabel("Last activity \(age)")
                    }
                    if card.commentCount > 0 { Label("\(card.commentCount)", systemImage: "text.bubble").font(.system(size: 10)).foregroundStyle(DieterTheme.tertiary) }
                    if !card.activeSubagents.isEmpty { Label("\(card.activeSubagents.count)", systemImage: "person.2").font(.system(size: 10)).foregroundStyle(DieterTheme.shell) }
                    if showsRunAction { Color.clear.frame(width: 24, height: 24) }
                }
            }
            .padding(12)
            .padding(.bottom, card.mergedIntoCardID.isEmpty ? 0 : 28)
            .background(
                store.selectedCardID == card.id ? DieterTheme.elevated.opacity(0.82) : (hovering ? DieterTheme.raised.opacity(0.9) : DieterTheme.surface),
                in: RoundedRectangle(cornerRadius: DieterMetrics.cardRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DieterMetrics.cardRadius, style: .continuous)
                    .stroke(
                        labelDropTargeted ? DieterTheme.eyes.opacity(0.9) : (store.selectedCardID == card.id ? DieterTheme.shell.opacity(0.45) : DieterTheme.border),
                        lineWidth: labelDropTargeted ? 1.5 : 1
                    )
            )
            .overlay(alignment: .topTrailing) {
                if labelDropTargeted {
                    Image(systemName: "tag.fill")
                        .font(.system(size: 10, weight: .bold)).foregroundStyle(DieterTheme.eyes)
                        .padding(7)
                        .background(DieterTheme.background.opacity(0.9), in: Circle())
                        .padding(5)
                        .transition(.scale.combined(with: .opacity))
                } else if store.labelUpdatingCardIDs.contains(card.id) {
                    ProgressView().controlSize(.mini).padding(8)
                }
            }
            .scaleEffect(labelDropTargeted ? 1.012 : 1)
            .opacity(store.isPendingCard(card.id) ? 0.52 : 1)
            .overlay(alignment: .bottomTrailing) {
                if store.isPendingCard(card.id) {
                    Image(systemName: store.isFailedOutboxItem(card.id) ? "exclamationmark.circle.fill" : "clock")
                        .font(.caption2)
                        .foregroundStyle(store.isFailedOutboxItem(card.id) ? DieterTheme.coral : DieterTheme.tertiary)
                        .padding(7)
                }
            }
            .draggable(BoardCardDragPayload(cardID: card.id, boardID: card.boardID, sourceLane: card.lane).encoded) {
                BoardCardDragPreview(card: card)
            }
            .onDrop(of: [.text], delegate: BoardCardDropDelegate(state: cardDrop, eligible: canMergePayload, drop: performCardDrop))
            .overlay {
                if cardDrop.mergeReady {
                    VStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.merge")
                            .font(.system(size: 26, weight: .semibold))
                        Text("Release to merge request").font(.caption.weight(.semibold))
                        Text("Move source to Done").font(.caption2)
                    }
                    .foregroundStyle(DieterTheme.text)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(DieterTheme.background.opacity(0.95), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(DieterTheme.eyes, lineWidth: 2))
                    .allowsHitTesting(false)
                    .accessibilityLabel("Release to merge the initial request and move the source to Done")
                    .accessibilityIdentifier("card-merge.\(card.id)")
                }
            }
            .onDisappear { cardDrop.reset() }
            .animation(.easeOut(duration: 0.14), value: labelDropTargeted)
            }
            .buttonStyle(BoardCardClickStyle(edit: openEditor))
            if !card.mergedIntoCardID.isEmpty {
                Button {
                    Task { await store.openConversation(cardID: card.mergedIntoCardID) }
                } label: {
                    Label("Merged into task", systemImage: "arrow.triangle.merge").font(.caption2)
                }
                .buttonStyle(.plain)
                .padding(8)
                .background(DieterTheme.background, in: Capsule())
                .help("Open the task that received this request")
                .accessibilityIdentifier("card-merge-link.\(card.id)")
                .padding(6)
            }
            if showsRunAction && hovering {
                Button {
                    Task { await store.start(card) }
                } label: {
                    Group {
                        if starting {
                            ProgressView().controlSize(.mini).tint(.white).scaleEffect(0.75)
                        } else {
                            Image(systemName: "play.fill").font(.system(size: 8, weight: .bold))
                        }
                    }
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(DieterTheme.shellDeep, in: Circle())
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(starting)
                .help(starting ? "Starting the saved task" : "Run the saved task and move this card to Running")
                .accessibilityLabel(runActionAccessibilityLabel)
                .accessibilityIdentifier("card-run.\(card.id)")
                .padding(.trailing, 12).padding(.bottom, 12)
                .transition(.scale(scale: 0.85).combined(with: .opacity))
            }
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .contextMenu {
            if store.isFailedOutboxItem(card.id) {
                Button("Retry queued creation") { Task { await store.retryOutboxItem(card.id) } }
                Button("Discard queued creation", role: .destructive) { Task { await store.discardOutboxItem(card.id) } }
                Divider()
            }
            Button("Open conversation") { Task { await store.openConversation(cardID: card.id) } }
            if showsRunAction {
                Button(starting ? "Starting task…" : "Run task", systemImage: "play.fill") {
                    Task { await store.start(card) }
                }
                .disabled(starting)
            }
            if BoardCardEditingPolicy.canEditDraft(card) {
                Button("Edit card…") { editPresented = true }
            }
            Button("Rename…") { renameText = card.title; renamePresented = true }
            Menu("Move to") {
                ForEach(store.selectedBoard?.lanes ?? [], id: \.id) { lane in
                    Button(lane.name) { Task { await store.move(card, lane: lane.id) } }
                }
            }
            if let labels = store.selectedBoard?.labels, !labels.isEmpty {
                Menu("Labels") {
                    ForEach(labels, id: \.id) { label in
                        Button { var ids = card.labelIds; if let index = ids.firstIndex(of: label.id) { ids.remove(at: index) } else { ids.append(label.id) }; Task { await store.setLabels(card, ids: ids) } } label: { Label(label.name, systemImage: card.labelIds.contains(label.id) ? "checkmark.circle.fill" : "circle") }
                    }
                }
            }
            if ["running", "waiting", "review"].contains(card.runtime) { Button("Cancel turn", role: .destructive) { Task { await store.cancel(card) } } }
            Divider()
            Button("Archive", role: .destructive) { Task { await store.archive(card, archived: true) } }
        }
        .accessibilityIdentifier("card.\(card.id)")
        .accessibilityHint("Click to open chat. Double-click to edit.")
        .sheet(isPresented: $renamePresented) {
            VStack(alignment: .leading, spacing: 14) { Text("Rename card").font(.title2.weight(.bold)); TextField("Title", text: $renameText); HStack { Spacer(); Button("Cancel") { renamePresented = false }; Button("Rename") { Task { await store.rename(card, title: renameText); renamePresented = false } }.buttonStyle(.borderedProminent).disabled(renameText.trimmingCharacters(in: .whitespaces).isEmpty) } }.padding(22).frame(width: 440)
        }
        .sheet(isPresented: $editPresented) {
            EditCardSheet(card: card).environment(store)
        }
    }

    private func openEditor() {
        if BoardCardEditingPolicy.canEditDraft(card) {
            editPresented = true
        } else {
            renameText = card.title
            renamePresented = true
        }
    }
}

enum BoardCardActivityText {
    static func compact(
        updatedAt: String,
        lastActivityAt: String,
        relativeTo now: Date = Date()
    ) -> String {
        guard let activity = latest(updatedAt: updatedAt, lastActivityAt: lastActivityAt) else { return "" }
        let seconds = max(0, Int(now.timeIntervalSince(activity)))
        switch seconds {
        case ..<60: return "now"
        case ..<3_600: return "\(seconds / 60)min"
        case ..<86_400: return "\(seconds / 3_600)h"
        case ..<604_800: return "\(seconds / 86_400)d"
        default: return "\(seconds / 604_800)w"
        }
    }

    private static func latest(updatedAt: String, lastActivityAt: String) -> Date? {
        [updatedAt, lastActivityAt].compactMap(parse).max()
    }

    private static func parse(_ value: String) -> Date? {
        DieterTimestamp.date(from: value)
    }
}

struct FlowLabels: View {
    let labels: [Dieter_V1_Label]
    var body: some View {
        HStack(spacing: 4) {
            ForEach(labels.prefix(3), id: \.id) { label in
                HStack(spacing: 4) { Circle().fill(Color(hex: label.color) ?? DieterTheme.shellDeep).frame(width: 5, height: 5); Text(label.name) }
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(DieterTheme.subtle)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(DieterTheme.raised, in: Capsule())
            }
        }
    }
}

extension Color {
    init?(hex: String) {
        var value = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        if value.count == 3 { value = value.map { "\($0)\($0)" }.joined() }
        guard value.count == 6, let int = UInt64(value, radix: 16) else { return nil }
        self.init(red: Double((int >> 16) & 0xff) / 255, green: Double((int >> 8) & 0xff) / 255, blue: Double(int & 0xff) / 255)
    }
}
