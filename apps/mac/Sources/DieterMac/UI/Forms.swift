import AppKit
import DieterAPI
import SwiftUI
import UniformTypeIdentifiers

struct NewConversationSheet: View {
    @Environment(DieterStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var prompt = ""
    @State private var provider = ""
    @State private var model = ""
    @State private var effort = ""
    @State private var providerOptions: [String: String] = [:]
    @State private var lane = ""
    @State private var selectedLabelIDs: Set<String> = []
    @State private var attachments: [Dieter_V1_MessagePart] = []
    @State private var fileImporterPresented = false
    @State private var attachmentDropTargeted = false
    @State private var submitting = false
    @FocusState private var focusedField: Field?

    private enum Field { case title, prompt }

    private var harness: Dieter_V1_Harness? { store.harnessCatalog.harnesses.first { $0.id == provider } }
    private var selectedModel: Dieter_V1_HarnessModel? { harness?.models.first { $0.id == model } }
    private var selectedLane: Dieter_V1_Lane? { store.selectedBoard?.lanes.first { $0.id == lane } }
    private var deferred: Bool { lane.lowercased() != "running" }
    private var canSubmit: Bool {
        !submitting && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            (!prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("BOARD  /  AGENT WORKSPACE")
                        .font(DieterFont.sectionLabel).tracking(1.4)
                        .foregroundStyle(DieterTheme.tertiary)
                    Text("New conversation").font(.system(size: 20, weight: .semibold))
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 12, weight: .bold)) }
                    .buttonStyle(DieterIconButtonStyle()).help("Close")
            }
            .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 15)

            ScrollView {
                VStack(alignment: .leading, spacing: 17) {
                    newCardLabel("Conversation title")
                    TextField("What should this agent accomplish?", text: $title)
                        .textFieldStyle(.plain).font(.system(size: 15, weight: .medium))
                        .focused($focusedField, equals: .title)
                        .padding(.horizontal, 14).frame(height: 46)
                        .background(DieterTheme.input, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(focusedField == .title ? DieterTheme.shellDeep.opacity(0.85) : DieterTheme.strongBorder, lineWidth: focusedField == .title ? 2 : 1))
                        .accessibilityIdentifier("new-card.title")

                    newCardLabel("Initial task")
                    TextField("Give the agent a concrete outcome, context, and acceptance criteria…", text: $prompt, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14)).lineSpacing(3).lineLimit(1...7)
                        .focused($focusedField, equals: .prompt)
                        .padding(.horizontal, 13).padding(.vertical, 14)
                        .frame(height: 135, alignment: .topLeading)
                        .background(
                            attachmentDropTargeted ? DieterTheme.shellDeep.opacity(0.12) : DieterTheme.input,
                            in: RoundedRectangle(cornerRadius: 10)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10).stroke(
                                attachmentDropTargeted
                                    ? DieterTheme.shell
                                    : (focusedField == .prompt ? DieterTheme.shellDeep.opacity(0.72) : DieterTheme.strongBorder),
                                lineWidth: attachmentDropTargeted || focusedField == .prompt ? 1.5 : 1
                            )
                        )
                        .accessibilityIdentifier("new-card.prompt")
                        .attachmentDropTarget(isTargeted: $attachmentDropTargeted) { providers in
                            Task {
                                do { attachments = try await store.attachmentParts(providers, appendingTo: attachments) }
                                catch { store.show(error) }
                            }
                        }

                    HStack(spacing: 9) {
                        Button { fileImporterPresented = true } label: {
                            Label("Attach images or files", systemImage: "paperclip")
                        }
                        .buttonStyle(DieterSecondaryButtonStyle())
                        Text("or drop files above · paste an image with ⌘V · 4 files, 6 MB total")
                            .font(.caption2).foregroundStyle(DieterTheme.tertiary)
                    }
                    if !attachments.isEmpty {
                        AttachmentPreviewStrip(attachments: $attachments)
                    }

                    if let labels = store.selectedBoard?.labels, !labels.isEmpty {
                        newCardLabel("Labels")
                        DieterFlowLayout(horizontalSpacing: 10, verticalSpacing: 8) {
                            ForEach(labels, id: \.id) { label in
                                let selected = selectedLabelIDs.contains(label.id)
                                let tint = Color(hex: label.color) ?? DieterTheme.shell
                                Button {
                                    if selected { selectedLabelIDs.remove(label.id) } else { selectedLabelIDs.insert(label.id) }
                                } label: {
                                    HStack(spacing: 7) {
                                        Image(systemName: selected ? "checkmark.square.fill" : "square")
                                            .foregroundStyle(selected ? tint : DieterTheme.tertiary)
                                        Circle().fill(tint).frame(width: 6, height: 6)
                                        Text(label.name)
                                    }
                                    .font(.caption.weight(.medium)).foregroundStyle(selected ? DieterTheme.text : DieterTheme.subtle)
                                    .padding(.horizontal, 9).frame(height: 28)
                                    .background(tint.opacity(selected ? 0.17 : 0.08), in: Capsule())
                                }.buttonStyle(.plain)
                            }
                        }
                    }

                    HStack(alignment: .top, spacing: 11) {
                        newCardMenu(title: "Start in", value: laneTitle, symbol: "arrow.right.circle") {
                            ForEach(store.selectedBoard?.lanes ?? [], id: \.id) { item in
                                Button(item.name) { lane = item.id }
                            }
                        }
                        newCardMenu(title: "Provider", value: harness?.name ?? "Server default", symbol: "cpu") {
                            ForEach(store.harnessCatalog.harnesses, id: \.id) { item in
                                Button(item.name) {
                                    provider = item.id; model = item.defaultModel
                                    effort = item.models.first(where: { $0.id == item.defaultModel })?.defaultEffort ?? ""
                                    providerOptions = ProviderOptionValues.defaults(for: item)
                                }
                            }
                        }
                        newCardMenu(title: "Model", value: selectedModel?.name ?? "Agent default", symbol: "terminal") {
                            ForEach(harness?.models ?? [], id: \.id) { item in
                                Button(item.name) { model = item.id; effort = item.defaultEffort }
                            }
                        }
                        newCardMenu(title: "Reasoning", value: effort.isEmpty ? "Default" : effort.capitalized, symbol: "sparkles") {
                            ForEach(selectedModel?.efforts ?? [], id: \.self) { value in
                                Button(value.capitalized) { effort = value }
                            }
                        }
                    }

                    if !(harness?.options ?? []).isEmpty {
                        HStack(spacing: 7) {
                            ProviderOptionChips(options: harness?.options ?? [], values: $providerOptions)
                            Spacer()
                        }
                    }

                    HStack(spacing: 10) {
                        Image(systemName: "lock").foregroundStyle(DieterTheme.shell)
                        Text("Dieter persists one local harness session and transcript for this card on \(store.endpoint.name).")
                            .font(.caption).foregroundStyle(DieterTheme.shell)
                        Spacer()
                    }
                    .padding(.horizontal, 13).frame(minHeight: 42)
                    .background(DieterTheme.shellDeep.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(DieterTheme.shellDeep.opacity(0.28)))
                }
                .padding(.horizontal, 24).padding(.bottom, 18)
            }

            Divider().overlay(DieterTheme.border)
            HStack(spacing: 10) {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(DieterSecondaryButtonStyle())
                Button {
                    Task { await submit() }
                } label: {
                    HStack(spacing: 7) {
                        if submitting { ProgressView().controlSize(.mini) } else { Image(systemName: "sparkles") }
                        Text(deferred ? "Save to \(selectedLane?.name ?? "board")" : "Start in \(selectedLane?.name ?? "Running")")
                    }
                }
                .buttonStyle(DieterPrimaryButtonStyle()).disabled(!canSubmit)
                .accessibilityIdentifier("new-card.create")
            }
            .padding(.horizontal, 24).padding(.vertical, 14)
        }
        .frame(width: 700, height: 760)
        .background(DieterTheme.background)
        .fileImporter(isPresented: $fileImporterPresented, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            do { attachments = try store.attachmentParts(try result.get(), appendingTo: attachments) }
            catch { store.show(error) }
        }
        .onPasteCommand(of: [.image, .fileURL]) { providers in
            Task {
                do { attachments = try await store.attachmentParts(providers, appendingTo: attachments) }
                catch { store.show(error) }
            }
        }
        .attachmentPasteCatcher { pasteboard in
            do {
                guard let parts = try store.pasteboardAttachmentParts(pasteboard, appendingTo: attachments) else { return false }
                attachments = parts
                return true
            } catch {
                store.show(error)
                return true
            }
        }
        .task {
            chooseDefaults()
            await Task.yield()
            focusedField = .title
        }
    }

    private func chooseDefaults() {
        if lane.isEmpty { lane = store.selectedBoard?.lanes.first?.id ?? "todo" }
        guard provider.isEmpty, let harness = store.harnessCatalog.harnesses.first else { return }
        provider = harness.id; model = harness.defaultModel; effort = harness.models.first(where: { $0.id == model })?.defaultEffort ?? harness.effort.options.first?.id ?? ""
        providerOptions = ProviderOptionValues.defaults(for: harness)
    }

    private var laneTitle: String {
        let title = selectedLane?.name ?? "Todo"
        return deferred ? "\(title) · draft" : "\(title) · starts agent"
    }

    private func newCardLabel(_ title: String) -> some View {
        Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(DieterTheme.subtle)
            .padding(.bottom, -10)
    }

    private func newCardMenu<Content: View>(
        title: String,
        value: String,
        symbol: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(DieterTheme.subtle)
            Menu(content: content) {
                HStack(spacing: 7) {
                    Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(DieterTheme.shell)
                    Text(value).lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold)).foregroundStyle(DieterTheme.tertiary)
                }
                .font(.system(size: 11, weight: .medium)).foregroundStyle(DieterTheme.subtle)
                .padding(.horizontal, 10).frame(height: 38)
                .background(DieterTheme.input, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(DieterTheme.strongBorder))
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden)
        }
        .frame(maxWidth: .infinity)
    }

    private func submit() async {
        guard canSubmit else { return }
        submitting = true
        await store.createConversation(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
            attachments: attachments,
            chat: false,
            provider: provider,
            model: model,
            effort: effort,
            providerOptions: providerOptions,
            deferred: deferred,
            lane: lane,
            labelIDs: Array(selectedLabelIDs).sorted()
        )
        submitting = false
    }
}

struct HarnessFields: View {
    @Environment(DieterStore.self) private var store
    @Binding var provider: String
    @Binding var model: String
    @Binding var effort: String
    @Binding var providerOptions: [String: String]

    private var harness: Dieter_V1_Harness? { store.harnessCatalog.harnesses.first { $0.id == provider } }
    private var selectedModel: Dieter_V1_HarnessModel? { harness?.models.first { $0.id == model } }

    var body: some View {
        Picker("Agent", selection: $provider) {
            Text("Server default").tag("")
            ForEach(store.harnessCatalog.harnesses, id: \.id) { Text($0.name).tag($0.id) }
        }.onChange(of: provider) { _, _ in
            model = harness?.defaultModel ?? ""; effort = selectedModel?.defaultEffort ?? ""
            providerOptions = ProviderOptionValues.defaults(for: harness)
        }
        Picker("Model", selection: $model) {
            Text("Agent default").tag("")
            ForEach(harness?.models ?? [], id: \.id) { Text($0.name).tag($0.id) }
        }.onChange(of: model) { _, _ in effort = selectedModel?.defaultEffort ?? "" }
        if let efforts = selectedModel?.efforts, !efforts.isEmpty {
            Picker("Reasoning effort", selection: $effort) {
                ForEach(efforts, id: \.self) { Text($0.capitalized).tag($0) }
            }
        }
        ProviderOptionFields(options: harness?.options ?? [], values: $providerOptions)
    }
}

enum ProviderOptionValues {
    static func defaults(for harness: Dieter_V1_Harness?) -> [String: String] {
        Dictionary((harness?.options ?? []).map { ($0.id, $0.defaultValue) }, uniquingKeysWith: { first, _ in first })
    }
}

struct ProviderOptionFields: View {
    let options: [Dieter_V1_ProviderOption]
    @Binding var values: [String: String]

    var body: some View {
        ForEach(options, id: \Dieter_V1_ProviderOption.id) { option in
            ProviderOptionField(option: option, values: $values)
        }
    }
}

private struct ProviderOptionField: View {
    let option: Dieter_V1_ProviderOption
    @Binding var values: [String: String]

    private var value: Binding<String> {
        Binding(get: { values[option.id, default: option.defaultValue] }, set: { values[option.id] = $0 })
    }

    private var booleanValue: Binding<Bool> {
        Binding(get: { value.wrappedValue.lowercased() == "true" }, set: { value.wrappedValue = $0 ? "true" : "false" })
    }

    @ViewBuilder var body: some View {
        if ["boolean", "bool"].contains(option.type.lowercased()) {
            Toggle(option.name, isOn: booleanValue).help(option.description_p)
        } else if ["enum", "select"].contains(option.type.lowercased()) {
            Picker(option.name, selection: value) {
                ForEach(option.choices, id: \Dieter_V1_ProviderOptionChoice.value) { choice in
                    Text(choice.name.isEmpty ? choice.value : choice.name).tag(choice.value)
                }
            }.help(option.description_p)
        } else {
            TextField(option.name, text: value).help(option.description_p)
        }
    }
}

struct ProviderOptionChips: View {
    let options: [Dieter_V1_ProviderOption]
    @Binding var values: [String: String]

    var body: some View {
        ForEach(options, id: \Dieter_V1_ProviderOption.id) { option in
            ProviderOptionChip(option: option, values: $values)
        }
    }
}

private struct ProviderOptionChip: View {
    let option: Dieter_V1_ProviderOption
    @Binding var values: [String: String]

    private var currentValue: String { values[option.id, default: option.defaultValue] }

    @ViewBuilder var body: some View {
        if ["boolean", "bool"].contains(option.type.lowercased()) {
            let enabled = currentValue.lowercased() == "true"
            Button { values[option.id] = enabled ? "false" : "true" } label: {
                DieterChipLabel(
                    title: option.name,
                    symbol: enabled ? "checkmark.circle.fill" : "circle",
                    showsDisclosure: false
                )
            }.buttonStyle(.plain).help(option.description_p)
        } else if ["enum", "select"].contains(option.type.lowercased()) {
            Menu {
                ForEach(option.choices, id: \Dieter_V1_ProviderOptionChoice.value) { choice in
                    Button(choice.name.isEmpty ? choice.value : choice.name) { values[option.id] = choice.value }
                }
            } label: {
                DieterChipLabel(title: option.choices.first(where: { $0.value == currentValue })?.name ?? option.name, symbol: "slider.horizontal.3")
            }.menuStyle(.borderlessButton).fixedSize().help(option.description_p)
        } else {
            TextField(option.name, text: Binding(get: { currentValue }, set: { values[option.id] = $0 }))
                .textFieldStyle(.roundedBorder).frame(width: 130).help(option.description_p)
        }
    }
}

struct NewProjectSheet: View {
    @Environment(DieterStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var machineID = ""
    @State private var path = ""
    @State private var name = ""
    @State private var summary = ""
    @State private var prompt = ""
    @State private var boardName = "Main"
    @State private var workflow = BoardWorkflow.review.rawValue
    @State private var browserPresented = false

    private var availableMachines: [DieterEndpoint] {
        store.machines.isEmpty ? [store.endpoint] : store.machines
    }

    private var selectedMachine: DieterEndpoint? {
        availableMachines.first { $0.id == machineID }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("NEW WORKSPACE")
                        .font(DieterFont.sectionLabel).tracking(1.4)
                        .foregroundStyle(DieterTheme.tertiary)
                    Text("Add a Git project").font(.system(size: 20, weight: .semibold))
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 12, weight: .bold)) }
                    .buttonStyle(DieterIconButtonStyle()).help("Close")
            }
            .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 15)

            ScrollView {
                VStack(alignment: .leading, spacing: 17) {
                    projectLabel("Project host")
                    Menu {
                        ForEach(availableMachines) { machine in
                            Button {
                                if machine.online { machineID = machine.id }
                            } label: {
                                if machine.id == machineID { Label(machine.name, systemImage: "checkmark") }
                                else { Text(machine.online ? machine.name : "\(machine.name) · Offline") }
                            }
                        }
                    } label: {
                        HStack(spacing: 9) {
                            Circle().fill(selectedMachine?.online == true ? DieterTheme.eyes : DieterTheme.tertiary).frame(width: 7, height: 7)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(selectedMachine?.name ?? "Choose a project host").font(.system(size: 13, weight: .semibold))
                                Text(selectedMachine?.online == true ? "Online · repository and agents run here" : "Offline")
                                    .font(.caption2).foregroundStyle(DieterTheme.tertiary)
                            }
                            Spacer()
                            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(DieterTheme.tertiary)
                        }
                        .foregroundStyle(DieterTheme.subtle).padding(.horizontal, 13).frame(height: 48)
                        .background(DieterTheme.input, in: RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(DieterTheme.strongBorder))
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden)
                    Text("The repository path and every agent process belong to this host. This placement choice does not filter the combined workspace.")
                        .font(.caption2).foregroundStyle(DieterTheme.tertiary)

                    projectLabel("Git working tree")
                    HStack {
                        projectTextField("/path/on/\(selectedMachine?.name ?? "machine")/repository", text: $path)
                        Button { browserPresented = true } label: {
                            Label("Browse…", systemImage: "folder")
                        }
                        .buttonStyle(DieterSecondaryButtonStyle())
                        .accessibilityIdentifier("new-project.browse")
                        .disabled(machineID.isEmpty || selectedMachine?.online != true)
                    }
                    Text("The path is resolved and validated by the project host; no local macOS file panel is used.")
                        .font(.caption2).foregroundStyle(DieterTheme.tertiary)

                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 7) {
                            projectLabel("Project name")
                            projectTextField("Directory name by default", text: $name)
                        }
                        VStack(alignment: .leading, spacing: 7) {
                            projectLabel("Summary")
                            projectTextField("What is this repository?", text: $summary)
                        }
                    }

                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 7) {
                            projectLabel("First board")
                            projectTextField("Main", text: $boardName)
                        }
                        VStack(alignment: .leading, spacing: 7) {
                            projectLabel("Workflow")
                            Menu {
                                ForEach(BoardWorkflow.allCases) { option in
                                    Button(option.title) { workflow = option.rawValue }
                                }
                            } label: {
                                HStack {
                                    Text(BoardWorkflow(rawValue: workflow)?.title ?? "With review")
                                    Spacer()
                                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(DieterTheme.tertiary)
                                }
                                .font(.system(size: 13, weight: .medium)).foregroundStyle(DieterTheme.subtle)
                                .padding(.horizontal, 12).frame(height: 40)
                                .background(DieterTheme.input, in: RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(DieterTheme.strongBorder))
                            }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden)
                        }
                    }
                    Text(BoardWorkflow(rawValue: workflow)?.laneDescription ?? "")
                        .font(.caption2).foregroundStyle(DieterTheme.tertiary)

                    projectLabel("Project instructions")
                    TextField("How should agents work in this project?", text: $prompt, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13)).lineSpacing(3).lineLimit(1...5)
                        .padding(.horizontal, 12).padding(.vertical, 13)
                        .frame(height: 105)
                        .background(DieterTheme.input, in: RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(DieterTheme.strongBorder))
                    Text("Stored centrally and included in every new card conversation for this project.")
                        .font(.caption2).foregroundStyle(DieterTheme.tertiary)
                }
                .padding(.horizontal, 24).padding(.bottom, 18)
            }

            Divider().overlay(DieterTheme.border)
            HStack(spacing: 10) {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(DieterSecondaryButtonStyle())
                Button {
                    Task {
                        await store.createProject(
                            path: path,
                            name: name,
                            summary: summary,
                            prompt: prompt,
                            boardName: boardName,
                            workflow: workflow,
                            machineID: machineID
                        )
                    }
                } label: {
                    Label("Add to \(selectedMachine?.name ?? "machine")", systemImage: "plus")
                }
                .buttonStyle(DieterPrimaryButtonStyle())
                .disabled(path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || boardName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedMachine?.online != true)
            }
            .padding(.horizontal, 24).padding(.vertical, 14)
        }
        .frame(width: 680, height: 720)
        .background(DieterTheme.background)
        .task {
            if machineID.isEmpty {
                machineID = availableMachines.first(where: { $0.id == store.endpoint.id })?.id ?? availableMachines.first(where: \.online)?.id ?? ""
            }
        }
        .onChange(of: machineID) { _, _ in path = "" }
        .onChange(of: path) { oldValue, newValue in
            if name.isEmpty || name == URL(fileURLWithPath: oldValue).lastPathComponent {
                name = URL(fileURLWithPath: newValue).lastPathComponent
            }
        }
        .sheet(isPresented: $browserPresented) {
            RemoteDirectoryBrowserSheet(machineID: machineID, selection: $path)
                .environment(store)
        }
    }

    private func projectLabel(_ value: String) -> some View {
        Text(value).font(.system(size: 12, weight: .semibold)).foregroundStyle(DieterTheme.subtle)
    }

    private func projectTextField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain).font(.system(size: 13))
            .padding(.horizontal, 12).frame(height: 40)
            .background(DieterTheme.input, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(DieterTheme.strongBorder))
    }
}

private struct RemoteDirectoryBrowserSheet: View {
    @Environment(DieterStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let machineID: String
    @Binding var selection: String
    @State private var listing: Dieter_V1_DirectoryListing?
    @State private var pathField = ""
    @State private var loading = false
    @State private var showHidden = false
    @State private var errorMessage = ""

    private var machine: DieterEndpoint? { store.machines.first { $0.id == machineID } ?? (store.endpoint.id == machineID ? store.endpoint : nil) }
    private var entries: [Dieter_V1_DirectoryEntry] {
        (listing?.entries ?? []).filter { showHidden || !$0.hidden }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                Image(systemName: "externaldrive.connected.to.line.below")
                    .font(.system(size: 18, weight: .semibold)).foregroundStyle(DieterTheme.shell)
                    .frame(width: 36, height: 36).background(DieterTheme.elevated, in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Choose a Git repository").font(.system(size: 17, weight: .bold))
                    Text("Browsing \(machine?.name ?? "remote machine") · rendered locally")
                        .font(.caption).foregroundStyle(DieterTheme.tertiary)
                }
                Spacer()
                if loading { ProgressView().controlSize(.small) }
            }
            .padding(18)

            Divider().overlay(DieterTheme.border)

            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("LOCATIONS").font(DieterFont.sectionLabel).tracking(0.8).foregroundStyle(DieterTheme.tertiary)
                        .padding(.horizontal, 9).padding(.bottom, 3)
                    ForEach(listing?.locations ?? [], id: \.path) { location in
                        Button { Task { await load(location.path) } } label: {
                            HStack(spacing: 8) {
                                Image(systemName: locationSymbol(location.kind)).frame(width: 15)
                                Text(location.name).lineLimit(1)
                                Spacer()
                            }
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(DieterTheme.subtle)
                            .padding(.horizontal, 9).frame(height: 30)
                            .background(listing?.path == location.path ? DieterTheme.raised : .clear, in: RoundedRectangle(cornerRadius: 7))
                        }.buttonStyle(.plain)
                    }
                    Spacer()
                    Toggle("Show hidden folders", isOn: $showHidden).toggleStyle(.checkbox).font(.caption).foregroundStyle(DieterTheme.subtle)
                }
                .padding(12).frame(width: 165).background(DieterTheme.sidebar)

                Divider().overlay(DieterTheme.border)

                VStack(spacing: 10) {
                    HStack(spacing: 7) {
                        Button { if let parent = listing?.parent, !parent.isEmpty { Task { await load(parent) } } } label: {
                            Image(systemName: "chevron.left")
                        }
                        .buttonStyle(DieterIconButtonStyle()).disabled(listing?.parent.isEmpty != false || loading)
                        TextField("Path on \(machine?.name ?? "machine")", text: $pathField)
                            .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
                            .padding(.horizontal, 10).frame(height: 30)
                            .background(DieterTheme.input, in: RoundedRectangle(cornerRadius: 7))
                            .overlay(RoundedRectangle(cornerRadius: 7).stroke(DieterTheme.strongBorder))
                            .onSubmit { Task { await load(pathField) } }
                        Button("Go") { Task { await load(pathField) } }.buttonStyle(DieterSecondaryButtonStyle()).disabled(loading)
                    }

                    if !errorMessage.isEmpty {
                        HStack(spacing: 7) {
                            Image(systemName: "exclamationmark.triangle.fill")
                            Text(errorMessage).lineLimit(2)
                            Spacer()
                        }
                        .font(.caption).foregroundStyle(DieterTheme.coral)
                    }

                    ScrollView {
                        LazyVStack(spacing: 3) {
                            if entries.isEmpty, !loading {
                                ContentUnavailableView("No folders", systemImage: "folder", description: Text("This directory has no visible subfolders."))
                                    .padding(.top, 45)
                            }
                            ForEach(entries, id: \.path) { entry in
                                Button { Task { await load(entry.path) } } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: entry.gitRepository ? "folder.badge.gearshape" : "folder.fill")
                                            .foregroundStyle(entry.gitRepository ? DieterTheme.eyes : DieterTheme.shell)
                                            .frame(width: 19)
                                        Text(entry.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                        Spacer()
                                        if entry.gitRepository {
                                            Text("Git repository").font(.caption2.weight(.semibold)).foregroundStyle(DieterTheme.eyes)
                                                .padding(.horizontal, 7).padding(.vertical, 3).background(DieterTheme.eyes.opacity(0.1), in: Capsule())
                                        }
                                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(DieterTheme.tertiary)
                                    }
                                    .foregroundStyle(DieterTheme.subtle).padding(.horizontal, 11).frame(height: 36)
                                    .background(DieterTheme.surface.opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(14)
            }
            .frame(maxHeight: .infinity)

            Divider().overlay(DieterTheme.border)
            HStack {
                if listing?.gitRepository == true {
                    Label("\(listing?.name ?? "Folder") is a Git working tree", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(DieterTheme.eyes)
                } else {
                    Text("Open a folder containing a .git working tree to select it.").font(.caption).foregroundStyle(DieterTheme.tertiary)
                }
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(DieterSecondaryButtonStyle())
                Button("Use this repository") {
                    selection = listing?.path ?? ""
                    dismiss()
                }
                .buttonStyle(DieterPrimaryButtonStyle()).disabled(listing?.gitRepository != true)
            }
            .padding(14)
        }
        .frame(width: 720, height: 560)
        .background(DieterTheme.background)
        .task { await load(selection) }
    }

    private func load(_ path: String) async {
        loading = true
        errorMessage = ""
        do {
            let value = try await store.listProjectDirectories(path: path, machineID: machineID)
            listing = value
            pathField = value.path
        } catch {
            errorMessage = error.localizedDescription
        }
        loading = false
    }

    private func locationSymbol(_ kind: String) -> String {
        switch kind {
        case "home": "house.fill"
        case "code": "chevron.left.forwardslash.chevron.right"
        case "computer": "desktopcomputer"
        default: "folder"
        }
    }
}

struct NewBoardSheet: View {
    @Environment(DieterStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var description = ""
    @State private var workflow = BoardWorkflow.review.rawValue
    @State private var doneArchivePolicy = DoneArchivePolicy.never.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Create board").font(.title2.weight(.bold))
            if let project = store.selectedProject {
                Text(project.name).font(.caption.weight(.semibold)).foregroundStyle(DieterTheme.shell)
            }
            TextField("Board name", text: $name)
            TextField("Description", text: $description)
            Picker("Workflow", selection: $workflow) {
                ForEach(BoardWorkflow.allCases) { option in Text(option.title).tag(option.rawValue) }
            }
            .pickerStyle(.segmented)
            Text(BoardWorkflow(rawValue: workflow)?.laneDescription ?? "")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Archive Done conversations", selection: $doneArchivePolicy) {
                ForEach(DoneArchivePolicy.allCases) { option in Text(option.title).tag(option.rawValue) }
            }
            HStack { Spacer(); Button("Cancel") { dismiss() }; Button("Create") { Task { await store.createBoard(name: name, workflow: workflow, description: description, doneArchivePolicy: doneArchivePolicy) } }.buttonStyle(.borderedProminent).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.padding(24).frame(width: 540)
    }
}

struct RenameBoardSheet: View {
    @Environment(DieterStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    private var normalizedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Rename board").font(.title2.weight(.bold))
            if let board = store.renameBoardTarget {
                Text("Choose a new name for \(board.name). Cards, labels, and conversations stay on this board.")
                    .foregroundStyle(.secondary)
                TextField("Board name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { rename(board.id) }
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }
                    Button("Rename") { rename(board.id) }
                        .buttonStyle(.borderedProminent)
                        .disabled(normalizedName.isEmpty || normalizedName == board.name)
                }
            } else {
                ContentUnavailableView("Board unavailable", systemImage: "rectangle.split.3x1")
            }
        }
        .padding(24).frame(width: 480)
        .onAppear { name = store.renameBoardTarget?.name ?? "" }
    }

    private func rename(_ boardID: String) {
        guard !normalizedName.isEmpty else { return }
        Task { await store.renameBoard(id: boardID, name: normalizedName) }
    }
}

struct RenameMachineSheet: View {
    @Environment(DieterStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let machine: DieterEndpoint
    @State private var name = ""
    @State private var saving = false

    private var normalized: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename machine").font(.title2.weight(.bold))
            Text("This display name is stored on the gateway and appears on every signed-in client.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("Machine name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { save() }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Rename") { save() }.buttonStyle(.borderedProminent)
                    .disabled(saving || normalized.isEmpty || normalized == machine.name)
            }
        }
        .padding(24).frame(width: 460)
        .onAppear { name = machine.name }
    }

    private func save() {
        guard !normalized.isEmpty else { return }
        saving = true
        Task {
            await store.renameMachine(machine, name: normalized)
            saving = false
            dismiss()
        }
    }
}

struct ProjectContextSheet: View {
    @Environment(DieterStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var summary = ""
    @State private var prompt = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Project") { TextField("Name", text: $name); TextField("Short summary", text: $summary) }
                Section("Persistent context") { TextEditor(text: $prompt).font(.body.monospaced()).frame(height: 260); Text("This context is owned by Dieter and supplied to new work without writing into the repository.").font(.caption).foregroundStyle(.secondary) }
            }.formStyle(.grouped).navigationTitle("Project context")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("Save") { Task { await store.updateProject(name: name, summary: summary, prompt: prompt) } } } }
        }.frame(width: 650, height: 600).onAppear { name = store.selectedProject?.name ?? ""; summary = store.selectedProject?.summary ?? ""; prompt = store.selectedProject?.prompt ?? "" }
    }
}

struct LabelsSheet: View {
    @Environment(DieterStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var color = "#7c5cff"
    @State private var instructions = ""
    @State private var pendingDelete: Dieter_V1_Label?
    @State private var creating = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Board labels").font(.title2.weight(.bold))
                    Text("Labels can add agent instructions to every card that carries them.")
                        .font(.caption).foregroundStyle(DieterTheme.tertiary)
                }
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding(20)
            .background(DieterTheme.sidebar)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if (store.selectedBoard?.labels ?? []).isEmpty {
                        ContentUnavailableView(
                            "No labels yet",
                            systemImage: "tag",
                            description: Text("Create one below, then assign it to cards from the board.")
                        )
                        .frame(maxWidth: .infinity).padding(.vertical, 16)
                    }

                    ForEach(store.selectedBoard?.labels ?? [], id: \.id) { label in
                        BoardLabelEditorRow(label: label, requestDelete: { pendingDelete = label })
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("NEW LABEL").font(DieterFont.sectionLabel).tracking(0.8).foregroundStyle(DieterTheme.tertiary)
                        HStack(spacing: 9) {
                            Circle().fill(Color(hex: color) ?? DieterTheme.shellDeep).frame(width: 10, height: 10)
                            TextField("Label name", text: $name)
                            TextField("#7c5cff", text: $color).font(.body.monospaced()).frame(width: 120)
                        }
                        TextField("Optional prompt added when this label is assigned…", text: $instructions, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(1...4)
                            .padding(12).frame(height: 76)
                            .background(DieterTheme.input, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(DieterTheme.border))
                        HStack {
                            Text("The instruction is composed with global, project, and board prompts.")
                                .font(.caption2).foregroundStyle(DieterTheme.tertiary)
                            Spacer()
                            Button("Create label") { Task { await createLabel() } }
                                .buttonStyle(.borderedProminent)
                                .disabled(creating || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || Color(hex: color) == nil)
                        }
                    }
                    .padding(14).dieterSurface(radius: 10)
                }
                .padding(18)
            }
            .background(DieterTheme.background)
        }
        .frame(width: 650, height: 620)
        .confirmationDialog(
            "Remove \(pendingDelete?.name ?? "label")?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
        ) {
            Button("Remove label", role: .destructive) {
                guard let label = pendingDelete else { return }
                pendingDelete = nil
                Task { await store.deleteLabel(id: label.id) }
            }
        } message: {
            Text("This removes the label from the board and every card. The label's agent instructions are removed too.")
        }
    }

    private func createLabel() async {
        creating = true
        await store.createLabel(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            color: color,
            instructions: instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        name = ""
        instructions = ""
        creating = false
    }
}

private struct BoardLabelEditorRow: View {
    @Environment(DieterStore.self) private var store
    let label: Dieter_V1_Label
    let requestDelete: () -> Void
    @State private var name: String
    @State private var color: String
    @State private var instructions: String
    @State private var saving = false

    init(label: Dieter_V1_Label, requestDelete: @escaping () -> Void) {
        self.label = label
        self.requestDelete = requestDelete
        _name = State(initialValue: label.name)
        _color = State(initialValue: label.color)
        _instructions = State(initialValue: label.instructions)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Circle().fill(Color(hex: color) ?? DieterTheme.shellDeep).frame(width: 10, height: 10)
                TextField("Label name", text: $name)
                TextField("#7c5cff", text: $color).font(.body.monospaced()).frame(width: 120)
                Button(role: .destructive, action: requestDelete) { Image(systemName: "trash") }
                    .buttonStyle(.plain).help("Remove \(label.name)")
            }
            Text("AGENT INSTRUCTIONS").font(DieterFont.sectionLabel).tracking(0.8).foregroundStyle(DieterTheme.tertiary)
            TextField("Optional prompt added when this label is assigned…", text: $instructions, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1...4)
                .padding(12).frame(height: 76)
                .background(DieterTheme.input, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(DieterTheme.border))
            HStack {
                Text("Applied only to cards carrying this label").font(.caption2).foregroundStyle(DieterTheme.tertiary)
                Spacer()
                Button(saving ? "Saving…" : "Save changes") { Task { await save() } }
                    .disabled(saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || Color(hex: color) == nil)
            }
        }
        .padding(14).dieterSurface(radius: 10)
    }

    private func save() async {
        saving = true
        await store.updateLabel(
            id: label.id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            color: color,
            instructions: instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        saving = false
    }
}

struct ArchivePolicySheet: View {
    @Environment(DieterStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var policy = "never"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Done retention").font(.title2.weight(.bold))
            Text("Automatically archive cards that remain in Done. Scheduled occurrence history stays authoritative.").foregroundStyle(.secondary)
            Picker("Archive done cards", selection: $policy) {
                ForEach(DoneArchivePolicy.allCases) { option in Text(option.title).tag(option.rawValue) }
            }.pickerStyle(.radioGroup)
            HStack { Spacer(); Button("Cancel") { dismiss() }; Button("Save") { Task { await store.setArchivePolicy(policy) } }.buttonStyle(.borderedProminent) }
        }.padding(24).frame(width: 500).onAppear { policy = store.selectedBoard?.doneArchivePolicy ?? "never" }
    }
}

enum BoardWorkflow: String, CaseIterable, Identifiable {
    case review
    case direct

    var id: String { rawValue }
    var title: String { self == .review ? "With review" : "Direct to done" }
    var laneDescription: String {
        self == .review ? "Todo → Running → Review → Done" : "Todo → Running → Done"
    }
}

enum DoneArchivePolicy: String, CaseIterable, Identifiable {
    case never
    case immediately
    case afterOneDay = "after_1_day"
    case afterSevenDays = "after_7_days"
    case afterThirtyDays = "after_30_days"
    case afterNinetyDays = "after_90_days"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .never: "Never"
        case .immediately: "Immediately"
        case .afterOneDay: "After 1 day"
        case .afterSevenDays: "After 7 days"
        case .afterThirtyDays: "After 30 days"
        case .afterNinetyDays: "After 90 days"
        }
    }
}
