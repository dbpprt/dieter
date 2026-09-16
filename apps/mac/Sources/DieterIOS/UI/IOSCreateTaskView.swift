#if os(iOS)
    import DieterAPI
    import SwiftUI

    struct IOSCreateTaskView: View {
        @Environment(\.dismiss) private var dismiss
        @Bindable var store: IOSStore
        let chat: Bool
        let created: (String) -> Void
        @State private var projectID: String
        @State private var boardID: String
        @State private var title = ""
        @State private var prompt = ""
        @State private var provider = ""
        @State private var model = ""
        @State private var effort = ""
        @State private var submitting = false
        @State private var runRequested = false
        private enum Field: Hashable { case title, prompt }
        @FocusState private var focusedField: Field?

        init(
            store: IOSStore, initialProjectID: String, initialBoardID: String?, chat: Bool,
            created: @escaping (String) -> Void
        ) {
            self.store = store
            self.chat = chat
            self.created = created
            _projectID = State(initialValue: initialProjectID)
            _boardID = State(initialValue: initialBoardID ?? "")
        }

        private var boards: [Dieter_V1_Board] { store.boards.filter { $0.projectID == projectID } }
        private var harness: Dieter_V1_Harness? { store.harnesses.first { $0.id == provider } }
        private var selectedModel: Dieter_V1_HarnessModel? { harness?.models.first { $0.id == model } }
        private var efforts: [String] {
            guard let selectedModel else { return [] }
            return selectedModel.efforts.isEmpty ? (harness?.effort.options.map(\.id) ?? []) : selectedModel.efforts
        }
        private var canSubmit: Bool {
            !submitting && store.phase.isConnected && !projectID.isEmpty && (chat || !boardID.isEmpty)
                && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !provider.isEmpty && !model.isEmpty
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
                        TextField("What should the agent do?", text: $prompt, axis: .vertical)
                            .lineLimit(6...12)
                            .focused($focusedField, equals: .prompt)
                            .accessibilityIdentifier("ios.create.prompt")
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
                        if let name = store.selectedMachine?.name {
                            LabeledContent("Machine", value: name)
                        }
                    }
                    Section("Agent") {
                        Picker("Provider", selection: $provider) {
                            ForEach(store.harnesses, id: \.id) { Text($0.name).tag($0.id) }
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
            .interactiveDismissDisabled(submitting || !prompt.isEmpty || !title.isEmpty)
            .task {
                if projectID.isEmpty { projectID = store.projects.first?.id ?? "" }
                if !boards.contains(where: { $0.id == boardID }) { boardID = boards.first?.id ?? "" }
                if provider.isEmpty { provider = store.harnesses.first?.id ?? ""; resetModel() }
            }
            .onChange(of: projectID) { _, _ in
                focusedField = nil; boardID = boards.first?.id ?? ""
            }
            .onChange(of: boardID) { _, _ in focusedField = nil }
            .onChange(of: provider) { _, _ in
                focusedField = nil; resetModel()
            }
            .onChange(of: model) { _, _ in
                focusedField = nil; resetEffort()
            }
            .onChange(of: effort) { _, _ in focusedField = nil }
        }

        private func resetModel() {
            let preferred = harness?.defaultModel ?? ""
            model =
                harness?.models.contains(where: { $0.id == preferred }) == true
                ? preferred : harness?.models.first?.id ?? ""
            resetEffort()
        }

        private func resetEffort() {
            let preferred = selectedModel?.defaultEffort ?? ""
            effort = efforts.contains(preferred) ? preferred : efforts.first ?? ""
        }

        private func submit(run: Bool) {
            guard canSubmit else { return }
            focusedField = nil
            submitting = true
            runRequested = run
            Task {
                let id = await store.createTask(
                    projectID: projectID, boardID: chat ? nil : boardID, title: title, prompt: prompt,
                    provider: provider, model: model, effort: effort, run: run)
                submitting = false
                if let id { created(id); dismiss() }
            }
        }
    }
#endif
