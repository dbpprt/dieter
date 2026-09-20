import DieterAPI
import DieterCore

#if os(iOS)
    import PhotosUI
    import SwiftUI
    import UniformTypeIdentifiers
    import UIKit

    struct IOSCreateTaskView: View {
        @Environment(\.dismiss) private var dismiss
        @Bindable var store: IOSStore
        let chat: Bool
        let created: (String) -> Void
        @State private var projectID: String
        @State private var boardID: String
        @State private var checkoutID = ""
        @State private var creationHarnesses: [Dieter_V1_Harness] = []
        @State private var catalogCheckoutID = ""
        @State private var title = ""
        @State private var prompt = ""
        @State private var provider = ""
        @State private var model = ""
        @State private var effort = ""
        @State private var providerOptions: [String: String] = [:]
        @State private var selectedLabelIDs: Set<String> = []
        @State private var attachments: [Dieter_V1_MessagePart]
        @State private var photoItems: [PhotosPickerItem] = []
        @State private var fileImporterPresented = false
        @State private var attachmentError: String?
        @State private var submitting = false
        @State private var runRequested = false
        private enum Field: Hashable { case title, prompt }
        @FocusState private var focusedField: Field?

        init(
            store: IOSStore, initialProjectID: String, initialBoardID: String?, chat: Bool,
            initialAttachments: [Dieter_V1_MessagePart] = [],
            created: @escaping (String) -> Void
        ) {
            self.store = store
            self.chat = chat
            self.created = created
            _projectID = State(initialValue: initialProjectID)
            _boardID = State(initialValue: initialBoardID ?? "")
            _attachments = State(initialValue: initialAttachments)
        }

        private var checkouts: [Dieter_V1_Checkout] { store.projects.first { $0.id == projectID }?.checkouts.filter { !$0.detached } ?? [] }
        private var boards: [Dieter_V1_Board] { store.boards.filter { $0.projectID == projectID } }
        private var selectedBoard: Dieter_V1_Board? { boards.first { $0.id == boardID } }
        private var labels: [Dieter_V1_Label] { chat ? [] : selectedBoard?.labels ?? [] }
        private var harness: Dieter_V1_Harness? { creationHarnesses.first { $0.id == provider } }
        private var selectedModel: Dieter_V1_HarnessModel? { harness?.models.first { $0.id == model } }
        private var fastModeOption: Dieter_V1_ProviderOption? {
            IOSCreateTaskProviderOptions.fastModeOption(for: harness, model: model)
        }
        private var efforts: [String] {
            guard let selectedModel else { return [] }
            return selectedModel.efforts.isEmpty ? (harness?.effort.options.map(\.id) ?? []) : selectedModel.efforts
        }
        private var canSubmit: Bool {
            !submitting && store.phase.isConnected && !projectID.isEmpty && (chat || !boardID.isEmpty)
                && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !provider.isEmpty && !model.isEmpty && !checkoutID.isEmpty && catalogCheckoutID == checkoutID
        }
        private var hasModifiedProviderOptions: Bool {
            providerOptions
                != IOSCreateTaskProviderOptions.normalized(for: harness, model: model, saved: [:])
        }

        var body: some View {
            NavigationStack {
                Form {
                    Section("Task") {
                        TextField("Title (optional)", text: $title)
                            .focused($focusedField, equals: .title)
                            .submitLabel(.next)
                            .onSubmit { focusedField = .prompt }
                            .accessibilityIdentifier("ios.create.title")
                        IOSAttachmentTextEditor(
                            text: $prompt,
                            isFocused: Binding(
                                get: { focusedField == .prompt },
                                set: { focusedField = $0 ? .prompt : nil }
                            ),
                            placeholder: "What should the agent do?",
                            minimumLines: 6,
                            maximumLines: 12,
                            accessibilityIdentifier: "ios.create.prompt",
                            keyboardDoneAccessibilityIdentifier: "ios.create.keyboard-done",
                            pastedImages: appendPastedImages,
                            pasteFailed: showAttachmentError
                        )
                    }
                    Section("Attachments") {
                        ForEach(Array(attachments.enumerated()), id: \.offset) { index, part in
                            attachmentRow(part, index: index)
                        }
                        HStack(spacing: 20) {
                            PhotosPicker(
                                selection: $photoItems,
                                maxSelectionCount: max(
                                    1, IOSAttachmentLoader.maximumCount - attachments.count),
                                matching: .images
                            ) {
                                Label("Photos", systemImage: "photo.on.rectangle")
                            }
                            .disabled(attachments.count >= IOSAttachmentLoader.maximumCount)
                            .accessibilityIdentifier("ios.create.attach-photos")
                            Button {
                                focusedField = nil
                                fileImporterPresented = true
                            } label: {
                                Label("Files", systemImage: "folder")
                            }
                            .disabled(attachments.count >= IOSAttachmentLoader.maximumCount)
                            .accessibilityIdentifier("ios.create.attach-files")
                        }
                        Text("Up to 4 files, 5 MB each and 6 MB total.")
                            .font(.caption).foregroundStyle(.secondary)
                        if let attachmentError {
                            Text(attachmentError).font(.caption).foregroundStyle(.red)
                                .accessibilityIdentifier("ios.create.attachment-error")
                        }
                    }
                    Section("Destination") {
                        Picker("Project", selection: $projectID) {
                            ForEach(store.projects, id: \.id) { Text($0.name).tag($0.id) }
                        }
                        .accessibilityIdentifier("ios.create.project")
                        if !chat {
                            Picker("Board", selection: $boardID) {
                                ForEach(boards, id: \.id) { Text($0.name).tag($0.id) }
                            }
                            .accessibilityIdentifier("ios.create.board")
                        }
                        Picker("Machine & checkout", selection: $checkoutID) {
                            Text("Choose a checkout").tag("")
                            ForEach(checkouts, id: \.id) { checkout in
                                let machine = store.machines.first { $0.daemonID == checkout.daemonID }
                                Text("\(machine?.name ?? checkout.daemonID) · \(checkout.name.isEmpty ? checkout.id : checkout.name)\(machine?.online == true ? "" : " · Offline")").tag(checkout.id)
                            }
                        }
                        .accessibilityIdentifier("ios.create.checkout")
                    }
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
                    Section("Agent") {
                        Picker("Provider", selection: $provider) {
                            ForEach(creationHarnesses, id: \.id) { Text($0.name).tag($0.id) }
                        }
                        .accessibilityIdentifier("ios.create.provider")
                        .accessibilityValue(harness?.name ?? provider)
                        Picker("Model", selection: $model) {
                            ForEach(harness?.models ?? [], id: \.id) { Text($0.name).tag($0.id) }
                        }
                        .accessibilityIdentifier("ios.create.model")
                        .accessibilityValue(selectedModel?.name ?? model)
                        if !efforts.isEmpty {
                            Picker("Reasoning", selection: $effort) {
                                ForEach(efforts, id: \.self) { value in
                                    Text(harness?.effort.options.first { $0.id == value }?.name ?? value.capitalized)
                                        .tag(value)
                                }
                            }
                            .accessibilityIdentifier("ios.create.effort")
                        }
                        if let fastModeOption {
                            Toggle(
                                fastModeOption.name.isEmpty ? "Fast mode" : fastModeOption.name,
                                isOn: fastModeSelection
                            )
                            .accessibilityIdentifier("ios.create.fast-mode")
                        }
                    }
                    if !store.phase.isConnected {
                        Section { Text("Reconnect to create this task.").foregroundStyle(.secondary) }
                    }
                }
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
                .safeAreaInset(edge: .bottom) {
                    HStack(spacing: 12) {
                        Button {
                            submit(run: false)
                        } label: {
                            HStack {
                                if submitting && !runRequested { ProgressView() }
                                Text("Add task").frame(maxWidth: .infinity)
                            }
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("ios.create.add")
                        Button {
                            submit(run: true)
                        } label: {
                            HStack {
                                if submitting && runRequested { ProgressView().tint(.white) }
                                Label("Run task", systemImage: "play.fill").frame(maxWidth: .infinity)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("ios.create.run")
                    }
                    .controlSize(.large)
                    .disabled(!canSubmit)
                    .padding().background(.bar)
                }
            }
            .interactiveDismissDisabled(
                submitting || !prompt.isEmpty || !title.isEmpty || !selectedLabelIDs.isEmpty || !attachments.isEmpty
                    || hasModifiedProviderOptions
            )
            .fileImporter(
                isPresented: $fileImporterPresented,
                allowedContentTypes: [.item],
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls):
                    Task {
                        do {
                            attachments = try await IOSAttachmentLoader().parts(
                                urls: urls, appendingTo: attachments)
                            attachmentError = nil
                        } catch {
                            attachmentError = error.localizedDescription
                        }
                    }
                case .failure(let error):
                    if (error as NSError).code != NSUserCancelledError {
                        attachmentError = error.localizedDescription
                    }
                }
            }
            .onChange(of: photoItems) { _, items in
                guard !items.isEmpty else { return }
                photoItems = []
                focusedField = nil
                Task {
                    do {
                        attachments = try await IOSAttachmentLoader().parts(
                            photoItems: items, appendingTo: attachments)
                        attachmentError = nil
                    } catch {
                        showAttachmentError(error)
                    }
                }
            }
            .task {
                if projectID.isEmpty { projectID = store.projects.first?.id ?? "" }
                if !boards.contains(where: { $0.id == boardID }) { boardID = boards.first?.id ?? "" }
                if checkouts.count == 1 { checkoutID = checkouts[0].id }
            }
            .task(id: checkoutID) {
                catalogCheckoutID = ""; creationHarnesses = []
                guard !checkoutID.isEmpty else { return }
                let requested = checkoutID
                do {
                    let catalog = try await store.creationHarnesses(projectID: projectID, checkoutID: requested)
                    guard !Task.isCancelled, checkoutID == requested else { return }
                    creationHarnesses = catalog; catalogCheckoutID = requested
                    provider = catalog.first?.id ?? ""; resetModel()
                } catch { if !Task.isCancelled { store.errorMessage = error.localizedDescription } }
            }
            .onChange(of: projectID) { _, _ in
                focusedField = nil
                selectedLabelIDs.removeAll()
                boardID = boards.first?.id ?? ""
                checkoutID = checkouts.count == 1 ? checkouts[0].id : ""
            }
            .onChange(of: boardID) { _, _ in
                focusedField = nil
                selectedLabelIDs.removeAll()
            }
            .onChange(of: labels.map(\.id)) { _, availableIDs in
                selectedLabelIDs.formIntersection(availableIDs)
            }
            .onChange(of: provider) { _, _ in
                focusedField = nil; resetModel()
            }
            .onChange(of: model) { _, _ in
                focusedField = nil
                resetEffort()
                providerOptions = IOSCreateTaskProviderOptions.normalized(
                    for: harness, model: model, saved: providerOptions)
            }
            .onChange(of: effort) { _, _ in focusedField = nil }
        }

        private func resetModel() {
            let preferred = harness?.defaultModel ?? ""
            model =
                harness?.models.contains(where: { $0.id == preferred }) == true
                ? preferred : harness?.models.first?.id ?? ""
            resetEffort()
            providerOptions = IOSCreateTaskProviderOptions.normalized(for: harness, model: model, saved: [:])
        }

        private func resetEffort() {
            let preferred = selectedModel?.defaultEffort ?? ""
            effort = efforts.contains(preferred) ? preferred : efforts.first ?? ""
        }

        private func appendPastedImages(_ payloads: [IOSAttachmentPayload]) {
            Task {
                do {
                    attachments = try await IOSAttachmentLoader().parts(
                        payloads: payloads,
                        appendingTo: attachments)
                    attachmentError = nil
                } catch {
                    showAttachmentError(error)
                }
            }
        }

        private func showAttachmentError(_ error: Error) {
            attachmentError = error.localizedDescription
        }

        private func labelSelection(_ id: String) -> Binding<Bool> {
            Binding(
                get: { selectedLabelIDs.contains(id) },
                set: { selected in
                    if selected {
                        selectedLabelIDs.insert(id)
                    } else {
                        selectedLabelIDs.remove(id)
                    }
                })
        }

        private var fastModeSelection: Binding<Bool> {
            Binding(
                get: { providerOptions["fast_mode", default: fastModeOption?.defaultValue ?? "false"] == "true" },
                set: { providerOptions["fast_mode"] = $0 ? "true" : "false" })
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
                    Text(ByteCountFormatter.string(fromByteCount: Int64(part.data.count), countStyle: .file))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("Remove", systemImage: "xmark.circle.fill", role: .destructive) {
                    guard attachments.indices.contains(index), attachments[index] == part else { return }
                    attachments.remove(at: index)
                    attachmentError = nil
                }
                .labelStyle(.iconOnly)
                .accessibilityIdentifier("ios.create.attachment.remove.\(index)")
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("ios.create.attachment.\(index)")
        }

        private func submit(run: Bool) {
            guard canSubmit else { return }
            focusedField = nil
            submitting = true
            runRequested = run
            let labelIDs = IOSCreateTaskLabels.normalized(selected: selectedLabelIDs, available: labels)
            let providerOptions = IOSCreateTaskProviderOptions.normalized(
                for: harness, model: model, saved: providerOptions)
            Task {
                let id = await store.createTask(
                    projectID: projectID, checkoutID: checkoutID, boardID: chat ? nil : boardID, title: title, prompt: prompt,
                    provider: provider, model: model, effort: effort, labelIDs: labelIDs,
                    providerOptions: providerOptions, attachments: attachments, run: run)
                submitting = false
                if let id { created(id); dismiss() }
            }
        }
    }

#endif

enum IOSCreateTaskLabels {
    static func normalized(selected: Set<String>, available: [Dieter_V1_Label]) -> [String] {
        let availableIDs = Set(available.lazy.map(\.id))
        return selected.intersection(availableIDs).sorted()
    }
}

enum IOSCreateTaskProviderOptions {
    static func fastModeOption(
        for harness: Dieter_V1_Harness?, model: String
    ) -> Dieter_V1_ProviderOption? {
        ProviderOptionValues.options(for: harness, model: model).first { $0.id == "fast_mode" }
    }

    static func normalized(
        for harness: Dieter_V1_Harness?, model: String, saved: [String: String]
    ) -> [String: String] {
        guard fastModeOption(for: harness, model: model) != nil else { return [:] }
        let values = ProviderOptionValues.normalized(for: harness, model: model, saved: saved)
        guard let fastMode = values["fast_mode"] else { return [:] }
        return ["fast_mode": fastMode]
    }

    static func identity(_ values: [String: String]) -> [String] {
        values.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
    }
}
