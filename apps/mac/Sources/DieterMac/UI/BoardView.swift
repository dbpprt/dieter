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
        guard values.count == 4, values[0] == "board-card", !values[1].isEmpty, !values[3].isEmpty
        else { return nil }
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
        guard values.count == 3, values[0] == "board-label", !values[1].isEmpty, !values[2].isEmpty
        else { return nil }
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
        card.lane.caseInsensitiveCompare("todo") == .orderedSame && card.mergedIntoCardID.isEmpty
            && card.initialPromptSentAt.isEmpty
            && !card.initialPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
        card.scope == "board" && card.lane.caseInsensitiveCompare("todo") == .orderedSame
            && card.mergedIntoCardID.isEmpty && card.initialPromptSentAt.isEmpty
            && (!card.initialPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || hasDraftAttachments)
            && runningLaneID(in: board) != nil
    }

    static func optimisticCard(
        _ card: Dieter_V1_Card,
        board: Dieter_V1_Board?,
        hasDraftAttachments: Bool = false
    ) -> Dieter_V1_Card? {
        guard canStart(card, board: board, hasDraftAttachments: hasDraftAttachments),
            let runningLaneID = runningLaneID(in: board)
        else { return nil }
        var card = card
        card.lane = runningLaneID
        card.runtime = "starting"
        return card
    }
}

enum BoardDropOrdering {
    static func position(before targetCardID: String, movingCardID: String, cards: [Dieter_V1_Card])
        -> Int64?
    {
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
            case (let leftDate?, let rightDate?) where leftDate != rightDate:
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
        return (horizontalPadding * 2)
            + (laneWidth(availableWidth: availableWidth, laneCount: laneCount) * CGFloat(laneCount))
            + (spacing * CGFloat(max(0, laneCount - 1)))
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

struct BoardView: View {
    @Environment(DieterStore.self) private var store
    var usesTitlebarSpace = false
    @State private var conversationMaximized = false

    var body: some View {
        BoardConversationOverlay(
            board: AnyView(
                boardContent.environment(store)
                    .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                    .background(DieterTheme.surface)
                    .smokeTarget("board.canvas")
                    .dieterThemeRoot(
                        palette: store.themeSelection.palette, appearance: store.themeSelection.appearance)),
            conversation: AnyView(
                ConversationView(
                    compact: true,
                    maximized: conversationMaximized,
                    onToggleMaximize: { conversationMaximized.toggle() }
                )
                .ignoresSafeArea(.container, edges: usesTitlebarSpace ? .top : [])
                .background(DieterTheme.surface)
                .environment(store)
                .environment(store.conversationContext)
                .dieterThemeRoot(
                    palette: store.themeSelection.palette, appearance: store.themeSelection.appearance)),
            presented: store.selectedCardID != nil,
            maximized: conversationMaximized,
            onRequestMaximize: { conversationMaximized = true }
        )
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        // The board host still uses its native safe-area constraints. Only the
        // conversation occupies the otherwise empty toolbar space beside the
        // sidebar; a hidden sidebar keeps room for the window controls.
        .ignoresSafeArea(
            .container, edges: usesTitlebarSpace && store.selectedCardID != nil ? .top : []
        )
        .background(DieterTheme.surface)
        .onChange(of: store.selectedCardID) { _, cardID in
            if cardID == nil { conversationMaximized = false }
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

    private var stateFilterTitle: String {
        store.runtimeFilter.isEmpty ? "All states" : store.runtimeFilter.capitalized
    }

    var body: some View {
        FluidPaneChrome(background: .clear, spacing: 7) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.selectedBoard?.name ?? "Board")
                        .font(DieterFont.paneTitle).lineLimit(1)
                    Text(boardMetadata)
                        .font(DieterFont.subtitle)
                        .foregroundStyle(DieterTheme.tertiary).lineLimit(1)
                }
                .layoutPriority(1)
                Spacer(minLength: 8)
            }
        } secondary: {
            HStack(spacing: 8) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        if store.selectedBoard?.labels.isEmpty == false {
                            allCardsButton(compact: false)
                        }
                        labelShelf
                        Menu {
                            stateFilterOptions
                        } label: {
                            Text(stateFilterTitle)
                        }
                        .menuStyle(.button)
                        .tint(store.runtimeFilter.isEmpty ? nil : Color.accentColor)
                        .fixedSize()
                        .accessibilityIdentifier("board.filter.state")

                        Button {
                            store.archivePolicyPresented = true
                        } label: {
                            Label("Board settings", systemImage: "gearshape")
                        }
                        .accessibilityIdentifier("board.settings")
                        .smokeTarget("board.settings")

                        Button {
                            store.labelsPresented = true
                        } label: {
                            Label("Labels", systemImage: "tag")
                        }
                        .help("Manage board labels")

                        Button {
                            store.createConversationPresented = true
                        } label: {
                            Label("New card", systemImage: "rectangle.badge.plus")
                        }
                        .accessibilityIdentifier("board.new-card")
                    }

                    HStack(spacing: 8) {
                        if store.selectedBoard?.labels.isEmpty == false {
                            allCardsButton(compact: true)
                        }
                        labelShelf
                        Menu {
                            stateFilterOptions
                            Divider()
                            Button("Board settings…") { store.archivePolicyPresented = true }
                            Button("Manage labels…") { store.labelsPresented = true }
                        } label: {
                            Label(
                                store.runtimeFilter.isEmpty ? "Filters" : stateFilterTitle,
                                systemImage: "line.3.horizontal.decrease")
                        }
                        .menuStyle(.button)
                        .tint(store.runtimeFilter.isEmpty ? nil : Color.accentColor)
                        .fixedSize()
                        .accessibilityIdentifier("board.filter.state")

                        Menu {
                            Button("New card…") { store.createConversationPresented = true }
                        } label: {
                            Label("New card", systemImage: "rectangle.badge.plus")
                                .labelStyle(.iconOnly)
                        }
                        .menuStyle(.button)
                        .fixedSize()
                        .help("New card")
                        .accessibilityIdentifier("board.new-card")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                quickTaskButton.fixedSize()
            }
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

    private func allCardsButton(compact: Bool) -> some View {
        Button {
            store.labelFilter = ""
        } label: {
            HStack(spacing: 5) {
                if store.labelFilter.isEmpty {
                    Image(systemName: "checkmark")
                }
                Text("\(compact ? "All" : "All cards") · \(store.boardCards.count)")
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
    }

    private var stateFilterOptions: some View {
        Picker(
            "State", selection: Binding(get: { store.runtimeFilter }, set: { store.runtimeFilter = $0 })
        ) {
            Text("All states").tag("")
            ForEach(["running", "review", "waiting", "completed", "failed"], id: \.self) { runtime in
                Text(runtime.capitalized).tag(runtime)
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

struct QuickTaskDraft {
    static func optimisticTitle(from story: String) -> String {
        let firstLine =
            story
            .split(whereSeparator: { $0.isNewline })
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard firstLine.count > 80 else { return firstLine }
        let end = firstLine.index(firstLine.startIndex, offsetBy: 80)
        let prefix = String(firstLine[..<end])
        guard let boundary = prefix.lastIndex(of: " "),
            prefix.distance(from: prefix.startIndex, to: boundary) >= 40
        else {
            return prefix
        }
        return String(prefix[..<boundary])
    }
}

@MainActor @Observable
final class QuickTaskFormState {
    private struct Choices: Codable {
        var project: String
        var boards: [String: String]
        var provider: String
        var model: String
        var effort: String
        var options: [String: String]
    }
    private let defaults: UserDefaults
    private static let key = "quickTask.lastChoices"
    private var boards: [String: String] = [:]
    var story = ""
    var provider = "" { didSet { saveChoices() } }
    var model = "" { didSet { saveChoices() } }
    var effort = "" { didSet { saveChoices() } }
    var providerOptions: [String: String] = [:] { didSet { saveChoices() } }
    var attachments: [Dieter_V1_MessagePart] = []
    var initialized = false
    private(set) var attachmentImportID: UUID?
    private(set) var attachmentError: String?
    private(set) var intakeGeneration = UUID()
    private let filePicker = QuickTaskFilePicker()
    var rememberHostname = false
    var sourceURL = ""
    var draftProjectID = "" { didSet { saveChoices() } }
    var draftBoardID = "" {
        didSet {
            if !draftProjectID.isEmpty && !draftBoardID.isEmpty { boards[draftProjectID] = draftBoardID }
            saveChoices()
        }
    }

    init(defaults: UserDefaults = DieterAppearance.applicationDefaults()) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
            let saved = try? JSONDecoder().decode(Choices.self, from: data)
        {
            boards = saved.boards
            draftProjectID = saved.project
            draftBoardID = saved.boards[saved.project] ?? ""
            provider = saved.provider
            model = saved.model
            effort = saved.effort
            providerOptions = saved.options
        }
    }

    func selectProject(_ id: String, boardIDs: [String]) {
        draftProjectID = id
        let remembered = boards[id] ?? ""
        draftBoardID = boardIDs.contains(remembered) ? remembered : (boardIDs.first ?? "")
    }

    func selectBoardContext(projectID: String, boardID: String) {
        draftProjectID = projectID
        draftBoardID = boardID
    }

    func appendAttachments(_ parts: [Dieter_V1_MessagePart], generation: UUID) throws {
        guard intakeGeneration == generation else { return }
        attachments = try AttachmentLoader.validate(parts, appendingTo: attachments)
    }

    func importFiles(
        pick: (@MainActor () async -> [URL]?)? = nil,
        load: @MainActor ([URL]) async throws -> [Dieter_V1_MessagePart],
        restorePresentation: @MainActor () -> Void
    ) async {
        guard attachmentImportID == nil else { return }
        let request = UUID()
        let generation = intakeGeneration
        attachmentImportID = request
        attachmentError = nil
        defer {
            if attachmentImportID == request {
                attachmentImportID = nil
                restorePresentation()
            }
        }
        let urls: [URL]?
        if let pick { urls = await pick() } else { urls = await filePicker.selectFiles() }
        guard attachmentImportID == request, intakeGeneration == generation, let urls, !urls.isEmpty else { return }
        do {
            let parts = try await load(urls)
            guard attachmentImportID == request, intakeGeneration == generation else { return }
            try appendAttachments(parts, generation: generation)
        } catch {
            if attachmentImportID == request, intakeGeneration == generation {
                attachmentError = error.localizedDescription
            }
        }
    }

    private func saveChoices() {
        let choices = Choices(
            project: draftProjectID, boards: boards, provider: provider, model: model, effort: effort,
            options: providerOptions)
        if let data = try? JSONEncoder().encode(choices) { defaults.set(data, forKey: Self.key) }
    }

    func reset() {
        intakeGeneration = UUID()
        attachmentImportID = nil
        attachmentError = nil
        filePicker.cancel()
        story = ""
        attachments = []
        rememberHostname = false
        sourceURL = ""
    }
}

struct QuickTaskPopover: View {
    @Environment(DieterStore.self) private var store
    @Binding var isPresented: Bool
    @Binding private var story: String
    @Binding private var provider: String
    @Binding private var model: String
    @Binding private var effort: String
    @Binding private var providerOptions: [String: String]
    @Binding private var attachments: [Dieter_V1_MessagePart]
    @Binding private var initialized: Bool
    @Binding private var rememberHostname: Bool
    @Binding private var sourceURL: String
    @Binding private var draftProjectID: String
    @Binding private var draftBoardID: String
    @State private var submitting = false
    @State private var settingsPresented = false
    @State private var attachmentDropTargeted = false
    @State private var submissionError: String?
    private let formDraft: QuickTaskFormState
    private let capturedBrowser: Bool
    private let chooseDestination: Bool

    init(
        isPresented: Binding<Bool>, draft: QuickTaskFormState? = nil,
        initialAttachments: [Dieter_V1_MessagePart] = [], sourceURL: String = "",
        capturedBrowser: Bool = false, chooseDestination: Bool = false
    ) {
        _isPresented = isPresented
        let state = draft ?? QuickTaskFormState()
        if draft == nil {
            state.attachments = initialAttachments
            state.sourceURL = sourceURL
        }
        formDraft = state
        let bindings = Bindable(state)
        _story = bindings.story
        _provider = bindings.provider
        _model = bindings.model
        _effort = bindings.effort
        _providerOptions = bindings.providerOptions
        _attachments = bindings.attachments
        _initialized = bindings.initialized
        _rememberHostname = bindings.rememberHostname
        _sourceURL = bindings.sourceURL
        _draftProjectID = bindings.draftProjectID
        _draftBoardID = bindings.draftBoardID
        self.capturedBrowser = capturedBrowser
        self.chooseDestination = chooseDestination
    }
    @FocusState private var storyFocused: Bool

    private var cleanStory: String { story.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var lane: Dieter_V1_Lane? {
        store.boards(for: draftProjectID).first { $0.id == draftBoardID }?.lanes.first
    }
    private var selection: ConversationCreationSelection? {
        guard !provider.isEmpty else { return nil }
        return ConversationCreationSelection(
            provider: provider, model: model, effort: effort, workspaceMode: preferences.workspaceMode)
    }
    private var preferences: ConversationCreationPreferences {
        ConversationCreationPreferences.load(from: DieterAppearance.applicationDefaults())
    }
    private var defaultsSummary: String {
        let laneName = lane?.name ?? "Todo"
        let workspace = preferences.workspaceMode.title
        guard let selection,
            let harness = store.harnessCatalog.harnesses.first(where: { $0.id == selection.provider }),
            let model = harness.models.first(where: { $0.id == selection.model })
        else {
            return "\(laneName) · \(workspace) · Agent defaults"
        }
        let fastMode =
            ProviderOptionValues.normalized(for: harness, model: model.id, saved: providerOptions)[
                "fast_mode"] == "true"
        return "\(laneName) · \(workspace) · \(harness.name) / \(model.name)"
            + (fastMode ? " · Fast" : "")
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
                    Text("Quick task").font(.system(size: 18, weight: .semibold)).smokeTarget(
                        "quick-task.title"
                    ).smokeTarget("quick-task.title")
                    Text("Describe the task. A short title is created automatically.")
                        .font(.system(size: 11)).foregroundStyle(DieterTheme.tertiary)
                }
                Spacer()

            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Picker(
                        "Project",
                        selection: Binding(
                            get: { draftProjectID },
                            set: { id in
                                formDraft.selectProject(id, boardIDs: store.boards(for: id).map(\.id))
                            })
                    ) {
                        Text("Choose project").tag("")
                        ForEach(store.projects.filter { !$0.archived }, id: \.id) { Text($0.name).tag($0.id) }
                    }.accessibilityIdentifier("quick-task.project")
                    Picker("Board", selection: $draftBoardID) {
                        Text("Choose board").tag("")
                        ForEach(store.boards(for: draftProjectID), id: \.id) { Text($0.name).tag($0.id) }
                    }.accessibilityIdentifier("quick-task.board")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            } label: {
                Text("Save to").font(.subheadline.weight(.medium))
            }
            .disabled(submitting)
            if let error = submissionError ?? formDraft.attachmentError {
                Text(error).font(.caption).foregroundStyle(.orange)
            }

            TextField("What should the agent accomplish?", text: $story, axis: .vertical)
                .textFieldStyle(.plain)
                .padding(12)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                .font(.system(size: 13)).lineSpacing(2).lineLimit(4...7)
                .focused($storyFocused)
                .overlay {
                    if attachmentDropTargeted {
                        RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 2)
                    }
                }
                .accessibilityIdentifier("quick-task.story")
                .smokeTarget("quick-task.story")
                .attachmentDropTarget(isTargeted: $attachmentDropTargeted) { providers in
                    let generation = formDraft.intakeGeneration
                    Task {
                        do {
                            let parts = try await store.attachmentParts(providers)
                            try formDraft.appendAttachments(parts, generation: generation)
                        } catch { store.show(error) }
                    }
                }

            HStack(spacing: 8) {
                Button {
                    Task {
                        await formDraft.importFiles(
                            load: { try await store.attachmentParts($0) },
                            restorePresentation: { isPresented = true })
                    }
                } label: {
                    Label("Attach", systemImage: "paperclip")
                }
                .buttonStyle(.glass)
                .disabled(submitting || formDraft.attachmentImportID != nil)
                .accessibilityIdentifier("quick-task.attach")
                Text("Paste or drop screenshots · 4 files, 6 MB total")
                    .font(.caption2).foregroundStyle(DieterTheme.tertiary)
            }
            if !attachments.isEmpty {
                AttachmentPreviewStrip(attachments: $attachments)
                    .accessibilityIdentifier("quick-task.attachments")
                    .smokeTarget("quick-task.attachments")
            }

            Group {
                TextField("Page URL (optional)", text: $sourceURL)
                    .textFieldStyle(.plain)
                    .padding(10)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityIdentifier("quick-task.source-url")
                    .smokeTarget("quick-task.source-url")
                if let host = CaptureBrowserContext.hostname(sourceURL) {
                    Toggle("Remember \(host) for this board", isOn: $rememberHostname)
                        .font(.caption)
                        .accessibilityIdentifier("quick-task.remember-hostname")
                }
                if capturedBrowser && sourceURL.isEmpty {
                    Text("The browser URL couldn’t be read. You can paste it here.")
                        .font(.caption2).foregroundStyle(DieterTheme.tertiary)
                }
            }

            Button {
                settingsPresented.toggle()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 11, weight: .medium))
                    Text(defaultsSummary).lineLimit(2)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Change task settings")
            .accessibilityLabel("Task settings")
            .accessibilityValue(defaultsSummary)
            .accessibilityIdentifier("quick-task.settings")
            .disabled(submitting)
            .popover(isPresented: $settingsPresented, arrowEdge: .trailing) {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Task settings").font(.headline)
                    Form {
                        HarnessFields(
                            catalog: store.harnessCatalog,
                            provider: $provider, model: $model, effort: $effort, providerOptions: $providerOptions)
                    }
                    .formStyle(.columns)
                    .pickerStyle(.menu)
                    .toggleStyle(.switch)
                    .controlSize(.regular)
                    Divider()
                    HStack {
                        Spacer()
                        Button("Done") { settingsPresented = false }
                            .buttonStyle(.glass)
                            .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(20)
                .frame(width: 360)
                .environment(store)
            }

            Divider()
            HStack(spacing: 9) {
                Button("Cancel") { isPresented = false }
                    .smokeTarget("quick-task.cancel")
                    .buttonStyle(.glass)
                Spacer()
                Button {
                    Task { await submit() }
                } label: {
                    HStack(spacing: 7) {
                        if submitting {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "sparkles")
                        }
                        Text("Add task")
                    }
                }
                .buttonStyle(.glassProminent)
                .disabled(
                    cleanStory.isEmpty || submitting || formDraft.attachmentImportID != nil
                        || draftProjectID.isEmpty || draftBoardID.isEmpty
                )
                .keyboardShortcut(.return, modifiers: [.command])
                .accessibilityIdentifier("quick-task.create")
                .smokeTarget("quick-task.create")
            }
        }
        .padding(20)
        .frame(width: 430)
        .fixedSize(horizontal: false, vertical: true)
        .smokeTarget("quick-task.content")
        .attachmentPasteCatcher { pasteboard in
            guard let input = store.pasteboardAttachmentInput(pasteboard) else { return false }
            let generation = formDraft.intakeGeneration
            Task {
                do {
                    let parts = try await store.attachmentParts(input)
                    try formDraft.appendAttachments(parts, generation: generation)
                } catch { store.show(error) }
            }
            return true
        }
        .task {
            if !initialized {
                if !chooseDestination && (draftProjectID.isEmpty || capturedBrowser) {
                    draftProjectID = store.selectedProjectID
                    draftBoardID = store.selectedBoardID
                }
                if provider.isEmpty {
                    let initial = preferences.resolved(in: store.harnessCatalog.harnesses)
                    provider = initial?.provider ?? ""
                    model = initial?.model ?? ""
                    effort = initial?.effort ?? ""
                    let harness = store.harnessCatalog.harnesses.first { $0.id == provider }
                    providerOptions = ProviderOptionValues.defaults(for: harness, model: model)
                }
                initialized = true
            }
            if !draftProjectID.isEmpty {
                formDraft.selectProject(
                    draftProjectID, boardIDs: store.boards(for: draftProjectID).map(\.id))
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
        submissionError = nil
        await store.selectProject(draftProjectID)
        guard store.selectedProjectID == draftProjectID, store.phase.isConnected else {
            submissionError = "This project is unavailable. Choose another destination or try again."
            submitting = false
            return
        }
        await store.selectBoard(draftBoardID)
        guard store.selectedBoard?.id == draftBoardID else {
            submissionError = "This board is unavailable. Choose another board."
            submitting = false
            return
        }
        if rememberHostname, let host = CaptureBrowserContext.hostname(sourceURL) {
            do { try await store.updateBoardHostnames([host], append: true) } catch {
                submissionError = error.localizedDescription
                submitting = false
                return
            }
        }
        let resolved = selection
        let harness = resolved.flatMap { value in
            store.harnessCatalog.harnesses.first { $0.id == value.provider }
        }
        var workspace = ConversationWorkspaceDraft()
        workspace.mode = preferences.workspaceMode
        workspace.baseBranch = store.selectedProject?.baseBranch ?? ""
        await store.createConversation(
            title: QuickTaskDraft.optimisticTitle(from: story),
            prompt: story
                + (sourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "" : "\n\nPage URL: " + sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)),
            attachments: attachments,
            chat: false,
            provider: resolved?.provider ?? "",
            model: resolved?.model ?? "",
            effort: resolved?.effort ?? "",
            providerOptions: ProviderOptionValues.normalized(
                for: harness, model: resolved?.model ?? "", saved: providerOptions),
            deferred: true,
            lane: lane?.id ?? "todo",
            workspace: workspace,
            autoGenerateTitle: true
        )
        submitting = false
        formDraft.reset()
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

private struct BoardLabelDragPreview: View {
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

struct KanbanView: View {
    @Environment(DieterStore.self) private var store
    let board: Dieter_V1_Board
    @State private var laneSortDirections: [String: BoardCardSortDirection] = [:]

    private var lanes: [Dieter_V1_Lane] {
        if !board.lanes.isEmpty { return board.lanes }
        return ["backlog", "ready", "running", "review", "done"].map { id in
            var lane = Dieter_V1_Lane()
            lane.id = id
            lane.name = id.capitalized
            return lane
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let laneWidth = KanbanLaneSizing.laneWidth(
                availableWidth: geometry.size.width, laneCount: lanes.count)
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
                        .frame(width: laneWidth, height: max(0, geometry.size.height - 24))
                    }
                }
                .padding(.horizontal, KanbanLaneSizing.horizontalPadding).padding(.vertical, 12)
                .frame(
                    minWidth: geometry.size.width, alignment: .topLeading
                )
                .frame(height: geometry.size.height, alignment: .top)
            }
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
                        .smokeTarget("lane-sort.\(lane.id).\(sortDirection.systemImage)")
                        .id(sortDirection.systemImage)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .quickHelp("Sort \(sortDirection.toggled.title.lowercased())")
                .accessibilityLabel("\(lane.name) lane sorted \(sortDirection.title.lowercased())")
                .accessibilityHint("Sort \(sortDirection.toggled.title.lowercased())")
                .accessibilityIdentifier("lane-sort.\(lane.id)")
                .smokeTarget("lane-sort.\(lane.id)")
                Button {
                    store.createConversationPresented = true
                } label: {
                    Image(systemName: "plus").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DieterTheme.tertiary)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .quickHelp("New card")
                .accessibilityLabel("New card")
            }.padding(.horizontal, 6).padding(.top, 2)
            if cards.isEmpty {
                VStack(spacing: 7) {
                    Image(systemName: isDropTargeted ? "arrow.down.circle.fill" : "arrow.down.circle").font(
                        .system(size: 17))
                    Text(isDropTargeted ? "Release to move" : "Drop cards here")
                }
                .font(.caption).foregroundStyle(isDropTargeted ? DieterTheme.shell : DieterTheme.tertiary)
                .frame(maxWidth: .infinity).padding(.vertical, 28)
                .overlay(
                    RoundedRectangle(cornerRadius: 9).stroke(DieterTheme.border, style: .init(dash: [5])))
                Spacer(minLength: 0)
            } else {
                BoardLaneList(laneID: lane.id, cards: cards, sortDirection: sortDirection)
            }
        }
        .padding(10)
        .background(
            isDropTargeted ? DieterTheme.shellDeep.opacity(0.08) : DieterTheme.background.opacity(0.35),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(
                isDropTargeted ? DieterTheme.shell.opacity(0.32) : DieterTheme.border)
        )
        .animation(.easeOut(duration: 0.14), value: isDropTargeted)
        .dropDestination(for: String.self) { values, _ in
            guard let value = values.first, let payload = BoardCardDragPayload(value),
                payload.boardID == store.selectedBoardID,
                let card = store.state.cards.first(where: { $0.id == payload.cardID })
            else { return false }
            if payload.sourceLane == lane.id, cards.last?.id == payload.cardID { return true }
            Task { await store.move(card, lane: lane.id) }
            return true
        } isTargeted: {
            isDropTargeted = $0
        }
    }
}

struct LaneInsertionTarget: View {
    static let beforeCardHeight: CGFloat = 9

    @Environment(DieterStore.self) private var store
    let laneID: String
    let beforeCardID: String?
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
        .frame(height: beforeCardID == nil ? 12 : Self.beforeCardHeight)
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { values, _ in
            guard let value = values.first, let payload = BoardCardDragPayload(value),
                payload.boardID == store.selectedBoardID,
                let card = store.state.cards.first(where: { $0.id == payload.cardID })
            else { return false }
            if payload.sourceLane == laneID, beforeCardID == payload.cardID { return true }
            let position: Int64?
            if let beforeCardID {
                position = BoardDropOrdering.position(
                    before: beforeCardID, movingCardID: payload.cardID,
                    cards: store.boardProjection.displayedCardsByLane[laneID] ?? [])
            } else {
                position = nil
            }
            Task { await store.move(card, lane: laneID, position: position) }
            return true
        } isTargeted: {
            targeted = $0
        }
        .animation(.easeOut(duration: 0.12), value: targeted)
    }
}

enum BoardAgentStatus: Equatable {
    case running, failed, idle

    static func resolve(_ card: Dieter_V1_Card) -> Self {
        let active = Set(["starting", "running", "active", "working", "streaming", "cancelling"])
        let status = card.runtime.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if active.contains(status)
            || card.activeSubagents.contains(where: { active.contains($0.status.lowercased()) })
        {
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
                Text(card.title.isEmpty ? "Untitled card" : card.title).font(
                    .system(size: 12, weight: .semibold)
                )
                .lineLimit(2)
                HStack(spacing: 6) {
                    Circle().fill(BoardAgentStatus.resolve(card).color).frame(width: 5, height: 5)
                    Text(card.runtime.capitalized).font(.system(size: 9, weight: .medium)).foregroundStyle(
                        DieterTheme.tertiary)
                }
            }
            Spacer(minLength: 8)
        }
        .padding(12).frame(width: 240)
        .background(DieterTheme.elevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(DieterTheme.shell.opacity(0.4))
        )
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
    private var labelDropTargeted: Bool {
        cardDrop.targeted && cardDrop.payload.flatMap(BoardLabelDragPayload.init) != nil
    }

    init(card: Dieter_V1_Card, dropState: BoardCardDropState = BoardCardDropState()) {
        self.card = card
        _cardDrop = State(initialValue: dropState)
    }

    var labels: [Dieter_V1_Label] {
        store.selectedBoard?.labels.filter { card.labelIds.contains($0.id) } ?? []
    }
    private func canMergePayload(_ value: String) -> Bool {
        guard let payload = BoardCardDragPayload(value),
            let source = store.state.cards.first(where: { $0.id == payload.cardID })
        else { return false }
        return BoardCardMergePolicy.canMerge(source, into: card)
    }

    private func performCardDrop(_ value: String, merge: Bool) -> Bool {
        if let payload = BoardLabelDragPayload(value) {
            guard payload.boardID == store.selectedBoardID,
                store.selectedBoard?.labels.contains(where: { $0.id == payload.labelID }) == true
            else { return false }
            let ids = BoardLabelAssignment.adding(payload.labelID, to: card.labelIds)
            guard ids != card.labelIds else { return true }
            Task { await store.setLabels(card, ids: ids) }
            return true
        }
        guard let payload = BoardCardDragPayload(value),
            payload.boardID == store.selectedBoardID,
            let dragged = store.state.cards.first(where: { $0.id == payload.cardID })
        else { return false }
        guard payload.cardID != card.id else { return true }
        if merge {
            Task { await store.merge(dragged, into: card) }
            return true
        }
        let laneCards = store.displayedCards.filter { $0.lane == card.lane }.sorted {
            $0.position < $1.position
        }
        let position = BoardDropOrdering.position(
            before: card.id, movingCardID: payload.cardID, cards: laneCards)
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

    private var metadataHelp: String {
        let harness = store.cachedHarnessCatalog(forProjectID: card.projectID)?.harnesses.first {
            $0.id == card.provider
        }
        var details = [BoardAgentStatus.resolve(card).label]
        if !card.provider.isEmpty { details.append("Provider: \(harness?.name ?? card.provider)") }
        if !card.model.isEmpty {
            let name = harness?.models.first { $0.id == card.model }?.name ?? card.model
            details.append("Model: \(name)")
        }
        let workspace = card.workspace
        let mode = workspace.mode.isEmpty ? card.workspaceMode : workspace.mode
        if !mode.isEmpty {
            details.append("Workspace: \(ConversationWorkspaceMode.projectMode(mode).title)")
        }
        let branch = workspace.branch.isEmpty ? card.workspaceBranch : workspace.branch
        if !branch.isEmpty { details.append("Branch: \(branch)") }
        if workspace.changedFiles > 0 { details.append("\(workspace.changedFiles) changed files") }
        if workspace.state == "conflicted" { details.append("Workspace has conflicts") }
        if card.pullRequest.number > 0 { details.append("PR #\(card.pullRequest.number)") }
        if card.hasTokenUsage { details.append(TaskTokenUsagePresentation.label(card.tokenUsage)) }
        return details.joined(separator: "\n")
    }

    private var accessibilityDetails: String {
        var details = [metadataHelp]
        if !card.summary.isEmpty { details.append(card.summary) }
        if !labels.isEmpty { details.append("Labels: \(labels.map(\.name).joined(separator: ", "))") }
        let age = BoardCardActivityText.compact(
            updatedAt: card.updatedAt, lastActivityAt: card.lastActivityAt, relativeTo: .now)
        if !age.isEmpty { details.append("Last activity \(age)") }
        if card.commentCount > 0 { details.append("\(card.commentCount) comments") }
        if !card.activeSubagents.isEmpty { details.append("\(card.activeSubagents.count) active subagents") }
        return details.joined(separator: ". ")
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Button {
                Task { await store.openConversation(cardID: card.id) }
            } label: {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(alignment: .top) {
                        Text(card.title.isEmpty ? "Untitled card" : card.title).font(
                            .system(size: 13, weight: .semibold)
                        ).multilineTextAlignment(.leading).lineLimit(3)
                        Spacer(minLength: 4)
                        Circle().fill(BoardAgentStatus.resolve(card).color).frame(width: 6, height: 6).padding(
                            .top, 5
                        )
                        .accessibilityLabel(BoardAgentStatus.resolve(card).label)
                    }
                    if !card.summary.isEmpty {
                        Text(card.summary).font(.system(size: 11)).foregroundStyle(DieterTheme.subtle)
                            .lineLimit(3).multilineTextAlignment(.leading)
                    }
                    if !labels.isEmpty {
                        FlowLabels(labels: labels)
                    }
                    HStack(spacing: 7) {
                        StatusPill(text: card.runtime, color: runtimeColor(card.runtime))
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
                        if card.commentCount > 0 {
                            Label("\(card.commentCount)", systemImage: "text.bubble").font(.system(size: 10))
                                .foregroundStyle(DieterTheme.tertiary)
                        }
                        if !card.activeSubagents.isEmpty {
                            Label("\(card.activeSubagents.count)", systemImage: "person.2").font(
                                .system(size: 10)
                            ).foregroundStyle(DieterTheme.shell)
                        }
                        if showsRunAction { Color.clear.frame(width: 24, height: 24) }
                    }
                }
                .padding(12)
                .padding(.bottom, card.mergedIntoCardID.isEmpty ? 0 : 28)
                .background(
                    store.selectedCardID == card.id
                        ? DieterTheme.elevated.opacity(0.82)
                        : (hovering ? DieterTheme.raised.opacity(0.9) : DieterTheme.surface),
                    in: RoundedRectangle(cornerRadius: DieterMetrics.cardRadius, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DieterMetrics.cardRadius, style: .continuous)
                        .stroke(
                            labelDropTargeted
                                ? DieterTheme.eyes.opacity(0.9)
                                : (store.selectedCardID == card.id
                                    ? DieterTheme.shell.opacity(0.45) : DieterTheme.border),
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
                        Image(
                            systemName: store.isFailedOutboxItem(card.id)
                                ? "exclamationmark.circle.fill" : "clock"
                        )
                        .font(.caption2)
                        .foregroundStyle(
                            store.isFailedOutboxItem(card.id) ? DieterTheme.coral : DieterTheme.tertiary
                        )
                        .padding(7)
                    }
                }
                .draggable(
                    BoardCardDragPayload(cardID: card.id, boardID: card.boardID, sourceLane: card.lane)
                        .encoded
                ) {
                    BoardCardDragPreview(card: card)
                }
                .onDrop(
                    of: [.text],
                    delegate: BoardCardDropDelegate(
                        state: cardDrop, eligible: canMergePayload, drop: performCardDrop)
                )
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
                        .background(
                            DieterTheme.background.opacity(0.95), in: RoundedRectangle(cornerRadius: 12)
                        )
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
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(card.title.isEmpty ? "Untitled card" : card.title)
            .accessibilityValue(accessibilityDetails)
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("card.open.\(card.id)")
            if !card.mergedIntoCardID.isEmpty {
                Button {
                    Task { await store.openConversation(cardID: card.mergedIntoCardID) }
                } label: {
                    Label("Merged into task", systemImage: "arrow.triangle.merge").font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 4)
                .quickHelp("Open merged task")
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
                .quickHelp(starting ? "Starting task" : "Run task")
                .accessibilityLabel(runActionAccessibilityLabel)
                .accessibilityIdentifier("card-run.\(card.id)")
                .padding(.trailing, 12).padding(.bottom, 12)
                .transition(.scale(scale: 0.85).combined(with: .opacity))
            }
        }
        .onHover { hovering = $0 }
        .quickHelp(metadataHelp, maximumWidth: 320)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .contextMenu {
            if store.isFailedOutboxItem(card.id) {
                Button("Retry queued creation") { Task { await store.retryOutboxItem(card.id) } }
                Button("Discard queued creation", role: .destructive) {
                    Task { await store.discardOutboxItem(card.id) }
                }
                Divider()
            }
            Button("Open conversation") { Task { await store.openConversation(cardID: card.id) } }
            if showsRunAction {
                Button(starting ? "Starting task…" : "Run task", systemImage: "play.fill") {
                    Task { await store.start(card) }
                }
                .disabled(starting)
            }
            Group {
                if BoardCardEditingPolicy.canEditDraft(card) { Button("Edit card…") { editPresented = true } }
                Button("Rename…") {
                    renameText = card.title
                    renamePresented = true
                }
                Menu("Move to") {
                    ForEach(store.selectedBoard?.lanes ?? [], id: \.id) { lane in
                        Button(lane.name) { Task { await store.move(card, lane: lane.id) } }
                    }
                }
                if let labels = store.selectedBoard?.labels, !labels.isEmpty {
                    Menu("Labels") {
                        ForEach(labels, id: \.id) { label in
                            Button {
                                var ids = card.labelIds
                                if let index = ids.firstIndex(of: label.id) {
                                    ids.remove(at: index)
                                } else {
                                    ids.append(label.id)
                                }
                                Task { await store.setLabels(card, ids: ids) }
                            } label: {
                                Label(
                                    label.name,
                                    systemImage: card.labelIds.contains(label.id) ? "checkmark.circle.fill" : "circle"
                                )
                            }
                        }
                    }
                }
                if ["running", "waiting", "review"].contains(card.runtime) {
                    Button("Cancel turn", role: .destructive) { Task { await store.cancel(card) } }
                }
                Divider()
                Button("Archive", role: .destructive) { Task { await store.archive(card, archived: true) } }
            }.disabled(!store.projectIsAvailable(card.projectID))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("card.\(card.id)")
        .accessibilityHint("Click to open chat. Double-click to edit.")
        .smokeTarget("card.\(card.id)")
        .sheet(isPresented: $renamePresented) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Rename card").font(.title2.weight(.bold))
                TextField("Title", text: $renameText)
                HStack {
                    Spacer()
                    Button("Cancel") { renamePresented = false }
                    Button("Rename") {
                        Task {
                            await store.rename(card, title: renameText)
                            renamePresented = false
                        }
                    }.buttonStyle(.borderedProminent).disabled(
                        renameText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }.padding(22).frame(width: 440)
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
        guard let activity = latest(updatedAt: updatedAt, lastActivityAt: lastActivityAt) else {
            return ""
        }
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
                HStack(spacing: 4) {
                    Circle().fill(Color(hex: label.color) ?? DieterTheme.shellDeep).frame(width: 5, height: 5)
                    Text(label.name)
                }
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
        self.init(
            red: Double((int >> 16) & 0xff) / 255, green: Double((int >> 8) & 0xff) / 255,
            blue: Double(int & 0xff) / 255)
    }
}
