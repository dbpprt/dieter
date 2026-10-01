import AppKit
import DieterAPI
import SwiftUI
import UniformTypeIdentifiers

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
    /// Remembers what was chosen through the shared core; set by the session.
    @ObservationIgnored var remember: (ClientRememberCreation) -> Void = { _ in }
    @ObservationIgnored private var adopting = false
    private var boards: [String: String] = [:]
    var story = ""
    var provider = "" { didSet { saveSelection() } }
    var model = "" { didSet { saveSelection() } }
    var effort = "" { didSet { saveSelection() } }
    var providerOptions: [String: String] = [:] { didSet { saveSelection() } }
    var attachments: [Dieter_V1_MessagePart] = []
    var initialized = false
    private(set) var attachmentImportID: UUID?
    private(set) var attachmentError: String?
    private(set) var intakeGeneration = UUID()
    private let filePicker = QuickTaskFilePicker()
    var rememberHostname = false
    var sourceURL = ""
    var draftProjectID = "" { didSet { saveDestination() } }
    var draftBoardID = "" {
        didSet {
            if !draftProjectID.isEmpty && !draftBoardID.isEmpty { boards[draftProjectID] = draftBoardID }
            saveDestination()
        }
    }

    init() {}

    /// Shows the choices the core remembers, without sending them back.
    func adopt(_ creation: ClientCreationSlice) {
        adopting = true
        defer { adopting = false }
        boards = creation.boards
        if draftProjectID != creation.projectID { draftProjectID = creation.projectID }
        let board = creation.boards[creation.projectID] ?? ""
        if draftBoardID != board { draftBoardID = board }
        if provider != creation.selection.provider { provider = creation.selection.provider }
        if model != creation.selection.model { model = creation.selection.model }
        if effort != creation.selection.effort { effort = creation.selection.effort }
        if providerOptions != creation.selection.providerOptions {
            providerOptions = creation.selection.providerOptions
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

    private func saveSelection() {
        guard !adopting else { return }
        remember(
            .with {
                $0.selection = .with {
                    $0.provider = provider
                    $0.model = model
                    $0.effort = effort
                    $0.providerOptions = providerOptions
                }
            })
    }

    private func saveDestination() {
        guard !adopting, !draftProjectID.isEmpty else { return }
        remember(
            .with {
                $0.projectID = draftProjectID
                $0.boardID = draftBoardID
            })
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
    var usesTitlebarSpace = false
    var active = true
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
    private let screenshotInspector: Bool
    private let screenshotInspectorWide: Bool

    init(
        isPresented: Binding<Bool>, draft: QuickTaskFormState? = nil,
        initialAttachments: [Dieter_V1_MessagePart] = [], sourceURL: String = "",
        capturedBrowser: Bool = false, chooseDestination: Bool = false, screenshotInspector: Bool = false,
        screenshotInspectorWide: Bool = true
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
        self.screenshotInspector = screenshotInspector
        self.screenshotInspectorWide = screenshotInspectorWide
    }
    @State private var storyFocused = false

    private var cleanStory: String { story.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var cannotSubmit: Bool {
        cleanStory.isEmpty || submitting || formDraft.attachmentImportID != nil
            || draftProjectID.isEmpty || draftBoardID.isEmpty
    }
    private var lane: Dieter_V1_Lane? {
        store.boards(for: draftProjectID).first { $0.id == draftBoardID }?.lanes.first
    }
    private var selection: ConversationCreationSelection? {
        guard !provider.isEmpty else { return nil }
        return ConversationCreationSelection(
            provider: provider, model: model, effort: effort, workspaceMode: preferences.workspaceMode)
    }
    private var preferences: ConversationCreationPreferences {
        store.creationPreferences
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
        if screenshotInspector {
            let layout =
                screenshotInspectorWide
                ? AnyLayout(HStackLayout(alignment: .top, spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            layout {
                taskForm
                ScreenshotMarkupInspector(attachments: $attachments)
                    .frame(
                        minWidth: screenshotInspectorWide ? 360 : 390,
                        idealWidth: screenshotInspectorWide ? 510 : 390,
                        maxWidth: screenshotInspectorWide ? .infinity : 390,
                        minHeight: screenshotInspectorWide ? 560 : 440
                    )
                    .padding(.top, screenshotInspectorWide ? 20 : 0)
                    .padding(.bottom, 20).padding(.trailing, screenshotInspectorWide ? 20 : 0)
            }
        } else {
            taskForm
        }
    }

    private var taskForm: some View {
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
                    LabeledContent("Run on") {
                        if draftProjectID.isEmpty {
                            Text("Choose a project")
                                .foregroundStyle(.tertiary)
                                .accessibilityIdentifier("quick-task.machine")
                                .smokeTarget("quick-task.machine")
                        } else {
                            ProjectCheckoutMenu(
                                projectID: draftProjectID,
                                accessibilityIdentifier: "quick-task.machine"
                            )
                        }
                    }
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

            ZStack(alignment: .topLeading) {
                QuickTaskStoryEditor(
                    text: $story,
                    focus: $storyFocused,
                    canPasteAttachment: { store.pasteboardAttachmentInput($0) != nil },
                    pasteAttachment: { pasteboard in
                        guard let input = store.pasteboardAttachmentInput(pasteboard) else { return false }
                        let generation = formDraft.intakeGeneration
                        Task {
                            do {
                                let parts = try await store.attachmentParts(input)
                                try formDraft.appendAttachments(parts, generation: generation)
                            } catch { store.show(error) }
                        }
                        return true
                    })
                if story.isEmpty {
                    Text("What should the agent accomplish?")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                        .allowsHitTesting(false)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
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
                .buttonStyle(DieterGlassButtonStyle())
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
                            .buttonStyle(DieterGlassButtonStyle())
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
                    .buttonStyle(DieterGlassButtonStyle())
                Spacer()
                Button {
                    Task { await submit(runImmediately: false) }
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
                .buttonStyle(DieterGlassButtonStyle())
                .disabled(cannotSubmit)
                .keyboardShortcut(.return, modifiers: [.command])
                .accessibilityIdentifier("quick-task.create")
                .smokeTarget("quick-task.create")
                Button {
                    Task { await submit(runImmediately: true) }
                } label: {
                    Label("Run task", systemImage: "play.fill")
                }
                .buttonStyle(DieterGlassButtonStyle(prominent: true))
                .disabled(cannotSubmit)
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .help("Create this task and start the agent immediately")
                .accessibilityIdentifier("quick-task.run")
                .smokeTarget("quick-task.run")
            }
        }
        .padding(20)
        .frame(width: 430)
        .fixedSize(horizontal: false, vertical: true)
        .smokeTarget("quick-task.content")
        .task {
            if !initialized {
                // A capture's own form starts from what the core remembers
                // and remembers through the session, like the menu bar's.
                if formDraft !== store.quickTaskForm {
                    formDraft.adopt(store.creationMemory)
                    formDraft.remember = store.quickTaskForm.remember
                }
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

    private func submit(runImmediately: Bool) async {
        let story = cleanStory
        guard !cannotSubmit else { return }
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
        let accepted = await store.createConversation(
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
            deferred: !runImmediately,
            lane: runImmediately ? "running" : (lane?.id ?? "todo"),
            workspace: workspace,
            autoGenerateTitle: true
        )
        submitting = false
        guard accepted else {
            submissionError = "The task could not be saved. Your draft is still here; try again."
            return
        }
        formDraft.reset()
        isPresented = false
    }
}
