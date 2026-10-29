import AppKit
import DieterAPI
import DieterClientAPI
import DieterCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor @Observable
final class QuickTaskFormState {
    /// Remembers what was chosen through the shared core; set by the session.
    @ObservationIgnored var remember: (ClientRememberCreation) -> Void = { _ in }
    @ObservationIgnored private var adopting = false
    var story = ""
    var attachments: [Dieter_V1_MessagePart] = []
    var initialized = false
    private(set) var attachmentImportID: UUID?
    private(set) var attachmentError: String?
    private(set) var intakeGeneration = UUID()
    private let filePicker = QuickTaskFilePicker()
    var rememberHostname = false
    var sourceURL = ""
    var draftProjectID = "" { didSet { saveDestination() } }
    var draftBoardID = "" { didSet { saveDestination() } }

    init() {}

    /// Shows the destination the core remembers, without sending it back.
    func adopt(_ creation: ClientCreationSlice) {
        adopting = true
        defer { adopting = false }
        if draftProjectID != creation.projectID { draftProjectID = creation.projectID }
        let board = creation.boards[creation.projectID] ?? ""
        if draftBoardID != board { draftBoardID = board }
    }

    /// Chooses a project and the board the core preselects in it.
    func selectProject(_ id: String, in creation: ClientCreationSlice) {
        draftProjectID = id
        draftBoardID = creation.boards[id] ?? ""
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
    @Binding private var attachments: [Dieter_V1_MessagePart]
    @Binding private var initialized: Bool
    @Binding private var draftProjectID: String
    @Binding private var draftBoardID: String
    @State private var submitting = false
    @State private var attachmentDropTargeted = false
    @State private var submissionError: String?
    @State private var form = CreationFormModel(chat: false)
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
        _attachments = bindings.attachments
        _initialized = bindings.initialized
        _draftProjectID = bindings.draftProjectID
        _draftBoardID = bindings.draftBoardID
        self.capturedBrowser = capturedBrowser
        self.chooseDestination = chooseDestination
        self.screenshotInspector = screenshotInspector
        self.screenshotInspectorWide = screenshotInspectorWide
    }
    @State private var storyFocused = false

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

    /// The form around the story. Typing, and the core's preview of each
    /// keystroke, redraw only the story field, the settings line, and the
    /// buttons; the destination pickers and attachments stay put.
    private var taskForm: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: "sparkles")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DieterTheme.shell)
                    .frame(width: 30, height: 30)
                    .background(DieterTheme.tileSelected, in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Quick task").font(.system(size: 18, weight: .semibold)).e2eTarget(
                        "quick-task.title"
                    ).e2eTarget("quick-task.title")
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
                            set: { id in formDraft.selectProject(id, in: store.creationMemory) })
                    ) {
                        Text("Choose project").tag("")
                        ForEach(store.projects.filter { !$0.archived }, id: \.id) { Text($0.name).tag($0.id) }
                    }.accessibilityIdentifier("quick-task.project").e2eTarget("quick-task.project")
                    Picker("Board", selection: $draftBoardID) {
                        Text("Choose board").tag("")
                        ForEach(store.boards(for: draftProjectID), id: \.id) { Text($0.name).tag($0.id) }
                    }.accessibilityIdentifier("quick-task.board").e2eTarget("quick-task.board")
                    LabeledContent("Run on") {
                        if draftProjectID.isEmpty {
                            Text("Choose a project")
                                .foregroundStyle(.tertiary)
                                .accessibilityIdentifier("quick-task.machine")
                                .e2eTarget("quick-task.machine")
                        } else {
                            ProjectCheckoutMenu(
                                projectID: draftProjectID,
                                accessibilityIdentifier: "quick-task.machine",
                                size: 28
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

            QuickTaskStoryField(formDraft: formDraft, focus: $storyFocused)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .dieterInset(radius: 10)
                .overlay {
                    if attachmentDropTargeted {
                        RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 2)
                    }
                }
                .accessibilityIdentifier("quick-task.story")
                .e2eTarget("quick-task.story")
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
                .buttonStyle(DieterBarButtonStyle(size: 28))
                .disabled(submitting || formDraft.attachmentImportID != nil)
                .accessibilityIdentifier("quick-task.attach")
                Text("Paste or drop screenshots · \(CreationCopy.attachmentLimits)")
                    .font(.caption2).foregroundStyle(DieterTheme.tertiary)
            }
            if !attachments.isEmpty {
                AttachmentPreviewStrip(attachments: $attachments)
                    .accessibilityIdentifier("quick-task.attachments")
                    .e2eTarget("quick-task.attachments")
            }

            QuickTaskSourceFields(formDraft: formDraft, capturedBrowser: capturedBrowser)

            QuickTaskSettingsButton(form: form, disabled: submitting)

            Divider()
            QuickTaskSubmitBar(
                form: form, formDraft: formDraft, submitting: submitting,
                cancel: { isPresented = false },
                submit: { runImmediately in Task { await submit(runImmediately: runImmediately) } })
        }
        .padding(20)
        .frame(width: 430)
        .fixedSize(horizontal: false, vertical: true)
        .e2eTarget("quick-task.content")
        .background { QuickTaskPreviewBinder(formDraft: formDraft, form: form) }
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
                initialized = true
            }
            form.attach(store.core)
            await Task.yield()
            storyFocused = true
        }
        .onExitCommand { isPresented = false }
    }

    private func submit(runImmediately: Bool) async {
        guard !form.cannotSubmit(submitting: submitting, importing: formDraft.attachmentImportID != nil) else {
            return
        }
        submitting = true
        submissionError = nil
        await store.selectProject(draftProjectID)
        guard store.selectedProjectID == draftProjectID, store.phase.isConnected else {
            submissionError = "This project is unavailable. Choose another destination or try again."
            submitting = false
            return
        }
        store.selectBoard(draftBoardID)
        guard store.selectedBoard?.id == draftBoardID else {
            submissionError = "This board is unavailable. Choose another board."
            submitting = false
            return
        }
        if formDraft.rememberHostname, let host = CaptureBrowserContext.hostname(formDraft.sourceURL) {
            do { try await store.updateBoardHostnames([host], append: true) } catch {
                submissionError = error.localizedDescription
                submitting = false
                return
            }
        }
        form.intent.lane = runImmediately ? form.runningLane?.id ?? "" : ""
        form.attachments = attachments
        let accepted = await form.create(using: store)
        submitting = false
        guard accepted else {
            submissionError = "The task could not be saved. Your draft is still here; try again."
            return
        }
        formDraft.reset()
        isPresented = false
    }
}

extension CreationFormModel {
    /// The start lane where the agent starts at once.
    fileprivate var runningLane: Dieter_V1_Lane? {
        preview.startLanes.first { ClientBoardLaneKind(laneID: $0.id, name: $0.name) == .running }
    }

    /// Nothing can be created until the core previewed the form without a
    /// problem, nor while a task is on its way or files are still importing.
    fileprivate func cannotSubmit(submitting: Bool, importing: Bool) -> Bool {
        !previewed || !preview.problem.isEmpty || submitting || importing
    }
}

/// The story editor and its placeholder; only they follow the story.
private struct QuickTaskStoryField: View {
    @Environment(DieterStore.self) private var store
    @Bindable var formDraft: QuickTaskFormState
    @Binding var focus: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            QuickTaskStoryEditor(
                text: $formDraft.story,
                focus: $focus,
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
            if formDraft.story.isEmpty {
                Text("What should the agent accomplish?")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                    .allowsHitTesting(false)
            }
        }
    }
}

/// The page a capture came from, and whether its board remembers the host.
private struct QuickTaskSourceFields: View {
    @Bindable var formDraft: QuickTaskFormState
    let capturedBrowser: Bool

    var body: some View {
        Group {
            TextField("Page URL (optional)", text: $formDraft.sourceURL)
                .textFieldStyle(.plain)
                .padding(10)
                .dieterInset(radius: 8)
                .accessibilityIdentifier("quick-task.source-url")
                .e2eTarget("quick-task.source-url")
            if let host = CaptureBrowserContext.hostname(formDraft.sourceURL) {
                Toggle("Remember \(host) for this board", isOn: $formDraft.rememberHostname)
                    .font(.caption)
                    .accessibilityIdentifier("quick-task.remember-hostname")
            }
            if capturedBrowser && formDraft.sourceURL.isEmpty {
                Text("The browser URL couldn’t be read. You can paste it here.")
                    .font(.caption2).foregroundStyle(DieterTheme.tertiary)
            }
        }
    }
}

/// The task settings the core's preview summarizes, and their popover.
private struct QuickTaskSettingsButton: View {
    @Environment(DieterStore.self) private var store
    let form: CreationFormModel
    let disabled: Bool
    @State private var presented = false

    var body: some View {
        Button {
            presented.toggle()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 11, weight: .medium))
                Text(form.preview.summary).lineLimit(2)
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
        .accessibilityValue(form.preview.summary)
        .accessibilityIdentifier("quick-task.settings")
        .disabled(disabled)
        .popover(isPresented: $presented, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Task settings").font(.headline)
                Form {
                    AgentPickerFields(controls: form.preview.agent) { choice in
                        Task { await form.refresh(choice: choice) }
                    }
                }
                .formStyle(.columns)
                .pickerStyle(.menu)
                .toggleStyle(.switch)
                .controlSize(.regular)
                Divider()
                HStack {
                    Spacer()
                    Button("Done") { presented = false }
                        .buttonStyle(DieterBarButtonStyle())
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 360)
            .environment(store)
        }
    }
}

/// Cancel, and the two ways to create the task, as the core's preview allows them.
private struct QuickTaskSubmitBar: View {
    let form: CreationFormModel
    let formDraft: QuickTaskFormState
    let submitting: Bool
    let cancel: () -> Void
    let submit: (_ runImmediately: Bool) -> Void

    var body: some View {
        let blocked = form.cannotSubmit(submitting: submitting, importing: formDraft.attachmentImportID != nil)
        HStack(spacing: 9) {
            Button("Cancel") { cancel() }
                .e2eTarget("quick-task.cancel")
                .buttonStyle(DieterBarButtonStyle())
            Spacer()
            Button {
                submit(false)
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
            .buttonStyle(DieterBarButtonStyle())
            .disabled(blocked)
            .keyboardShortcut(.return, modifiers: [.command])
            .accessibilityIdentifier("quick-task.create")
            .e2eTarget("quick-task.create")
            Button {
                submit(true)
            } label: {
                Label("Run task", systemImage: "play.fill")
            }
            .buttonStyle(DieterBarButtonStyle(prominent: true))
            .disabled(blocked || form.runningLane == nil)
            .keyboardShortcut(.return, modifiers: [.command, .shift])
            .help("Create this task and start the agent immediately")
            .accessibilityIdentifier("quick-task.run")
            .e2eTarget("quick-task.run")
        }
    }
}

/// Binds the form's choices to the core's preview. It follows the story and
/// the destination, so each keystroke previews without redrawing the form.
private struct QuickTaskPreviewBinder: View {
    @Environment(DieterStore.self) private var store
    let formDraft: QuickTaskFormState
    let form: CreationFormModel

    /// The task's prompt: the story, then the page it came from.
    private var prompt: String {
        let url = formDraft.sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return formDraft.story.trimmingCharacters(in: .whitespacesAndNewlines)
            + (url.isEmpty ? "" : "\n\nPage URL: " + url)
    }

    var body: some View {
        Color.clear
            .accessibilityHidden(true)
            .background { CreationCheckoutBinder(projectID: formDraft.draftProjectID, form: form) }
            .onChange(
                of: QuickTaskDestination(
                    projectID: formDraft.draftProjectID, boardID: formDraft.draftBoardID, prompt: prompt),
                initial: true
            ) { _, destination in
                form.intent.projectID = destination.projectID
                form.intent.boardID = destination.boardID
                form.intent.prompt = destination.prompt
            }
            .onChange(of: formDraft.attachments.count, initial: true) { _, _ in
                form.attachments = formDraft.attachments
            }
            .task(id: QuickTaskPreviewKey(intent: form.intent, attachments: formDraft.attachments.count)) {
                form.attach(store.core)
                await form.refresh()
            }
    }
}

/// Where a quick task goes and what it asks; the checkout follows the project.
private struct QuickTaskDestination: Equatable {
    let projectID: String
    let boardID: String
    let prompt: String
}

/// What a quick task's preview depends on.
private struct QuickTaskPreviewKey: Equatable {
    let intent: ClientCreationIntent
    let attachments: Int
}
