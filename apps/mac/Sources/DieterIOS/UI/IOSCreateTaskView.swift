#if os(iOS)
    import DieterAPI
    import DieterShared
    import PhotosUI
    import SharedCore
    import SwiftUI
    import UIKit
    import UniformTypeIdentifiers

    /// A new task or chat on the shared core's creation form: the core fills
    /// in the defaults, says why it cannot be created yet, words the title
    /// and destination, and resolves the agent pickers against the
    /// destination machine's catalog. The new conversation opens.
    struct IOSCreateTaskView: View {
        @Environment(\.dismiss) private var dismiss
        @Environment(IOSAppModel.self) private var app
        @Environment(IOSWorkspaceNavigation.self) private var navigation
        let request: IOSCreateRequest
        @State private var form: CreationFormModel
        @State private var prepared = false
        @State private var photoItems: [PhotosPickerItem] = []
        @State private var fileImporterPresented = false
        @State private var attachmentError: String?
        @State private var submittingLane: String?
        private enum Field: Hashable { case title, prompt }
        @FocusState private var focusedField: Field?

        init(request: IOSCreateRequest) {
            self.request = request
            _form = State(
                initialValue: CreationFormModel(
                    chat: request.chat, scope: "ios-creation-\(UUID().uuidString.lowercased())"))
        }

        private var chat: Bool { request.chat }
        private var preview: ClientCreationPreview { form.preview }
        /// The choices with the core's defaults applied.
        private var resolved: ClientCreationIntent { preview.intent }
        private var projectID: String { form.intent.projectID.isEmpty ? resolved.projectID : form.intent.projectID }
        private var boardID: String { form.intent.boardID.isEmpty ? resolved.boardID : form.intent.boardID }
        private var board: Dieter_V1_Board? { app.board(boardID) }
        private var checkouts: [Dieter_V1_Checkout] {
            app.project(projectID)?.checkouts.filter { !$0.detached } ?? []
        }
        private var labels: [Dieter_V1_Label] { chat ? [] : board?.labels ?? [] }
        private var submitting: Bool { submittingLane != nil }
        private var canSubmit: Bool { !submitting && form.previewed && preview.problem.isEmpty }
        private var edited: Bool {
            !form.intent.title.isEmpty || !form.intent.prompt.isEmpty || !form.intent.labelIds.isEmpty
                || !form.attachments.isEmpty
        }

        var body: some View {
            NavigationStack {
                Form {
                    taskSection
                    attachmentsSection
                    destinationSection
                    labelsSection
                    agentSection
                }
                .accessibilityIdentifier("ios.create.form")
                .scrollDismissesKeyboard(.interactively)
                .disabled(submitting)
                .navigationTitle(chat ? "New chat" : "New task")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                            .disabled(submitting)
                            .accessibilityIdentifier("ios.create.cancel")
                    }
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Done") { focusedField = nil }
                            .fontWeight(.semibold)
                            .accessibilityIdentifier("ios.create.keyboard-done")
                    }
                }
                .safeAreaInset(edge: .bottom) { submissionBar }
            }
            .interactiveDismissDisabled(submitting || edited)
            .task { prepare() }
            .task(id: PreviewKey(prepared: prepared, intent: form.intent, attachments: form.attachments.count)) {
                guard prepared else { return }
                await form.refresh()
            }
            .fileImporter(
                isPresented: $fileImporterPresented, allowedContentTypes: [.item], allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls):
                    intake { try await IOSAttachmentLoader().parts(urls: urls, appendingTo: $0) }
                case .failure(let error):
                    if (error as NSError).code != NSUserCancelledError { attachmentError = error.localizedDescription }
                }
            }
            .onChange(of: photoItems) { _, items in
                guard !items.isEmpty else { return }
                photoItems = []
                focusedField = nil
                intake { try await IOSAttachmentLoader().parts(photoItems: items, appendingTo: $0) }
            }
        }

        /// What a preview depends on: the choices and how many files are attached.
        private struct PreviewKey: Equatable {
            let prepared: Bool
            let intent: ClientCreationIntent
            let attachments: Int
        }

        private func prepare() {
            guard !prepared else { return }
            form.attach(app.core)
            form.intent.projectID = request.projectID
            form.intent.boardID = chat ? "" : request.boardID
            form.attachments = request.attachments
            prepared = true
        }

        // MARK: - Sections

        private var taskSection: some View {
            Section("Task") {
                TextField(
                    "Title", text: $form.intent.title,
                    prompt: Text(preview.title.isEmpty ? "Title (optional)" : preview.title)
                )
                .focused($focusedField, equals: .title)
                .submitLabel(.next)
                .onSubmit { focusedField = .prompt }
                .accessibilityIdentifier("ios.create.title")
                IOSAttachmentTextEditor(
                    text: $form.intent.prompt,
                    isFocused: Binding(
                        get: { focusedField == .prompt },
                        set: { focusedField = $0 ? .prompt : nil }
                    ),
                    placeholder: chat ? "Ask anything" : "What should the agent do?",
                    minimumLines: 6,
                    maximumLines: 12,
                    accessibilityIdentifier: "ios.create.prompt",
                    keyboardDoneAccessibilityIdentifier: "ios.create.keyboard-done",
                    pastedImages: { payloads in
                        intake { try await IOSAttachmentLoader().parts(payloads: payloads, appendingTo: $0) }
                    },
                    pasteFailed: { attachmentError = $0.localizedDescription }
                )
            }
        }

        private var attachmentsSection: some View {
            let slots = IOSAttachmentLoader.remainingSlots(after: form.attachments)
            return Section("Attachments") {
                ForEach(Array(form.attachments.enumerated()), id: \.offset) { index, part in
                    attachmentRow(part, index: index)
                }
                HStack(spacing: 20) {
                    PhotosPicker(selection: $photoItems, maxSelectionCount: max(1, slots), matching: .images) {
                        Label("Photos", systemImage: "photo.on.rectangle")
                    }
                    .disabled(slots == 0)
                    .accessibilityIdentifier("ios.create.attach-photos")
                    Button {
                        focusedField = nil
                        fileImporterPresented = true
                    } label: {
                        Label("Files", systemImage: "folder")
                    }
                    .disabled(slots == 0)
                    .accessibilityIdentifier("ios.create.attach-files")
                }
                .buttonStyle(.borderless)
                Text(IOSAttachmentLoader.limits)
                    .font(.caption).foregroundStyle(.secondary)
                if let attachmentError {
                    Text(attachmentError).font(.caption).foregroundStyle(.red)
                        .accessibilityIdentifier("ios.create.attachment-error")
                }
            }
        }

        private var destinationSection: some View {
            Section {
                Picker(
                    "Project",
                    selection: Binding(
                        get: { projectID },
                        set: { id in
                            focusedField = nil
                            form.intent.projectID = id
                            form.intent.boardID = ""
                            form.intent.checkoutID = ""
                            form.intent.labelIds = []
                        })
                ) {
                    if projectID.isEmpty { Text("Choose a project").tag("") }
                    ForEach(app.workspace.projects, id: \.id) { Text($0.name).tag($0.id) }
                }
                .accessibilityIdentifier("ios.create.project")
                if !chat {
                    Picker(
                        "Board",
                        selection: Binding(
                            get: { boardID },
                            set: { id in
                                focusedField = nil
                                form.intent.boardID = id
                                form.intent.labelIds = []
                            })
                    ) {
                        if boardID.isEmpty { Text("Choose a board").tag("") }
                        ForEach(app.boards(in: projectID), id: \.id) { Text($0.name).tag($0.id) }
                    }
                    .accessibilityIdentifier("ios.create.board")
                    if !preview.startLanes.isEmpty {
                        Picker("Start in", selection: Binding(get: { form.lane }, set: { form.intent.lane = $0 })) {
                            ForEach(preview.startLanes, id: \.id) { Text($0.name).tag($0.id) }
                        }
                        .accessibilityIdentifier("ios.create.lane")
                    }
                }
                Picker(
                    "Machine & checkout",
                    selection: Binding(get: { resolved.checkoutID }, set: pickCheckout)
                ) {
                    if resolved.checkoutID.isEmpty { Text("Choose a checkout").tag("") }
                    ForEach(checkouts, id: \.id) { checkout in
                        Text(
                            [app.machine(checkout.daemonID)?.name ?? checkout.daemonID, checkout.name]
                                .filter { !$0.isEmpty }.joined(separator: " · ")
                        )
                        .tag(checkout.id)
                    }
                }
                .accessibilityIdentifier("ios.create.checkout")
                Picker(
                    "Workspace",
                    selection: Binding(
                        get: { resolved.workspaceMode },
                        set: { form.intent.workspaceMode = $0 })
                ) {
                    ForEach(SharedRules.shared.workspaceModes(), id: \.self) { mode in
                        Text(SharedRules.shared.workspaceModeChoiceTitle(mode: mode)).tag(mode)
                    }
                }
                .accessibilityIdentifier("ios.create.workspace-mode")
            } header: {
                Text("Destination")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if !preview.workspaceDetail.isEmpty { Text(preview.workspaceDetail) }
                    if !preview.destinationStatus.isEmpty {
                        Text(preview.destinationStatus).accessibilityIdentifier("ios.create.destination-status")
                    }
                }
            }
        }

        @ViewBuilder
        private var labelsSection: some View {
            if !labels.isEmpty {
                Section("Labels") {
                    ForEach(labels, id: \.id) { label in
                        Toggle(isOn: labelSelection(label.id)) {
                            Label(label.name, systemImage: "tag.fill")
                        }
                        .accessibilityIdentifier("ios.create.label.\(label.id)")
                    }
                }
            }
        }

        private var agentSection: some View {
            Section {
                if preview.catalog == .none {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(preview.destinationStatus.isEmpty ? "Loading agent models…" : preview.destinationStatus)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("ios.create.harness-loading")
                } else {
                    IOSAgentPickers(controls: preview.agent, identifierPrefix: "ios.create") { choice in
                        focusedField = nil
                        Task { await form.refresh(choice: choice) }
                    }
                }
            } header: {
                Text("Agent")
            } footer: {
                if !preview.offlineHint.isEmpty {
                    Label(preview.offlineHint, systemImage: "exclamationmark.triangle")
                        .accessibilityIdentifier("ios.create.offline-hint")
                }
            }
        }

        private var submissionBar: some View {
            VStack(spacing: 8) {
                if form.previewed {
                    Text(preview.problem.isEmpty ? preview.summary : preview.problem)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("ios.create.status")
                }
                HStack(spacing: 12) {
                    if chat {
                        submitButton(lane: "", title: "Start chat", systemImage: "paperplane.fill", prominent: true)
                    } else {
                        ForEach(preview.startLanes, id: \.id) { lane in
                            if SharedRules.shared.opensAfterCreate(chat: false, lane: lane.id) {
                                submitButton(
                                    lane: lane.id, title: "Run task", systemImage: "play.fill", prominent: true)
                            } else {
                                submitButton(
                                    lane: lane.id, title: "Add to \(lane.name)", systemImage: nil, prominent: false)
                            }
                        }
                    }
                }
                .controlSize(.large)
                .disabled(!canSubmit)
            }
            .padding()
            .background(.bar)
        }

        @ViewBuilder
        private func submitButton(lane: String, title: String, systemImage: String?, prominent: Bool) -> some View {
            let starts = chat || SharedRules.shared.opensAfterCreate(chat: false, lane: lane)
            let button = Button {
                submit(lane: lane)
            } label: {
                HStack {
                    if submittingLane == lane { ProgressView().tint(prominent ? .white : nil) }
                    if let systemImage {
                        Label(title, systemImage: systemImage)
                    } else {
                        Text(title)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .accessibilityIdentifier(starts ? "ios.create.run" : "ios.create.add")
            if prominent {
                button.buttonStyle(.borderedProminent)
            } else {
                button.buttonStyle(.bordered)
            }
        }

        private func attachmentRow(_ part: Dieter_V1_MessagePart, index: Int) -> some View {
            HStack(spacing: 12) {
                if part.mediaType.hasPrefix("image/"), let image = UIImage(data: part.data) {
                    Image(uiImage: image)
                        .resizable().scaledToFill()
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                } else {
                    Image(systemName: "doc.fill")
                        .font(.title2).foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(part.filename).lineLimit(1)
                    Text(
                        SharedRules.shared.attachmentDetails(
                            filename: part.filename, mediaType: part.mediaType, bytes: Int64(part.data.count))
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("Remove", systemImage: "xmark.circle.fill", role: .destructive) {
                    guard form.attachments.indices.contains(index), form.attachments[index] == part else { return }
                    form.attachments.remove(at: index)
                    attachmentError = nil
                }
                .labelStyle(.iconOnly)
                .accessibilityIdentifier("ios.create.attachment.remove.\(index)")
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("ios.create.attachment.\(index)")
        }

        // MARK: - Choices

        private func labelSelection(_ id: String) -> Binding<Bool> {
            Binding(
                get: { form.intent.labelIds.contains(id) },
                set: { selected in
                    form.intent.labelIds.removeAll { $0 == id }
                    if selected { form.intent.labelIds = (form.intent.labelIds + [id]).sorted() }
                })
        }

        /// New conversations in the project run on the picked checkout; the core remembers it.
        private func pickCheckout(_ id: String) {
            focusedField = nil
            form.intent.checkoutID = id
            guard !id.isEmpty else { return }
            let project = projectID
            Task {
                await app.perform {
                    $0.rememberCreation = .with {
                        $0.projectID = project
                        $0.checkoutID = id
                    }
                }
            }
        }

        /// Reads picked or pasted files into the form, within the core's limits.
        private func intake(
            _ read: @escaping @Sendable ([Dieter_V1_MessagePart]) async throws -> [Dieter_V1_MessagePart]
        ) {
            let existing = form.attachments
            Task { @MainActor in
                do {
                    let parts = try await read(existing)
                    let added = Array(parts.dropFirst(existing.count))
                    form.attachments = try IOSAttachmentLoader.appending(added, to: form.attachments)
                    attachmentError = nil
                } catch {
                    attachmentError = error.localizedDescription
                }
            }
        }

        private func submit(lane: String) {
            guard canSubmit else { return }
            focusedField = nil
            if !chat { form.intent.lane = lane }
            submittingLane = lane
            Task {
                var created: Dieter_V1_Card?
                _ = await form.create { intent, chat, submissionID in
                    created = await app.createConversation(intent, chat: chat, submissionID: submissionID)
                    return created != nil
                }
                submittingLane = nil
                guard let created else { return }
                dismiss()
                navigation.openConversation(created.id)
            }
        }
    }
#endif
