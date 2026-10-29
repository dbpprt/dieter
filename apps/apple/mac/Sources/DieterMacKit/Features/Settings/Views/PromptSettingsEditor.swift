import DieterAPI
import DieterCore
import SwiftUI

struct PromptSettingsEditor: View {
    @Environment(DieterStore.self) private var store
    @State private var settings = Dieter_V1_PromptSettings()
    @State private var globalKind = "Context"
    @State private var projectTemplate = ""
    @State private var boardTemplate = ""
    @State private var projectInherits = true
    @State private var boardInherits = true
    @State private var labelInstructions: [String: String] = [:]
    @State private var previewLabelIDs: Set<String> = []
    @State private var preview: Dieter_V1_PromptPreview?
    @State private var loading = true
    @State private var saving = false
    /// The machine whose global templates show; each machine's agents use its own.
    @State private var machineID = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("GLOBAL TEMPLATES").promptSectionLabel()
                        Picker(
                            "Machine",
                            selection: Binding(
                                get: { machineID },
                                set: { value in
                                    machineID = value
                                    Task { await loadGlobal() }
                                })
                        ) {
                            ForEach(store.machines.filter(store.machineIsAvailable)) { machine in
                                Text(machine.name).tag(machine.daemonID ?? "")
                            }
                        }
                        .labelsHidden().frame(width: 180)
                        .accessibilityIdentifier("settings.prompts.machine")
                        Spacer()
                        DieterSegmentedPicker(
                            "Template", selection: $globalKind, options: ["Context", "Board", "Chat"], fillsWidth: true,
                            optionTitle: { $0 == "Context" ? "Context" : "\($0) skill" }
                        )
                        .frame(width: 300)
                    }
                    TextEditor(text: globalTemplate)
                        .font(.system(size: 11, design: .monospaced)).scrollContentBackground(.hidden)
                        .padding(9).frame(minHeight: 150)
                        .background(DieterTheme.input, in: RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(DieterTheme.strongBorder))
                    if !settings.variables.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                Text("Variables").font(.caption2).foregroundStyle(DieterTheme.tertiary)
                                ForEach(settings.variables, id: \.self) {
                                    Text($0).font(.caption2.monospaced()).padding(.horizontal, 7).frame(height: 22)
                                        .background(DieterTheme.raised, in: Capsule())
                                }
                            }
                        }
                    }
                    HStack {
                        Spacer();
                        Button("Save global templates") { Task { await saveGlobal() } }
                            .buttonStyle(DieterBarButtonStyle(prominent: true, size: 28))
                            .disabled(saving || machineID.isEmpty)
                    }
                }.promptPanel()

                HStack(alignment: .top, spacing: 12) {
                    scopedEditor(
                        title: "Project override",
                        subtitle: store.selectedProject?.name ?? "Select a project",
                        inherits: $projectInherits,
                        template: $projectTemplate,
                        disabled: store.selectedProject == nil,
                        save: { Task { await saveProject() } }
                    )
                    scopedEditor(
                        title: "Board override",
                        subtitle: store.selectedBoard?.name ?? "Select a board",
                        inherits: $boardInherits,
                        template: $boardTemplate,
                        disabled: store.selectedBoard == nil,
                        save: { Task { await saveBoard() } }
                    )
                }

                if let board = store.selectedBoard, !board.labels.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("LABEL INSTRUCTIONS").promptSectionLabel()
                            Spacer()
                            Text("Included only when a card carries the label").font(.caption2).foregroundStyle(
                                DieterTheme.tertiary)
                        }
                        ForEach(board.labels, id: \.id) { label in
                            HStack(spacing: 9) {
                                Circle().fill(Color(hex: label.color) ?? DieterTheme.shellDeep).frame(
                                    width: 8, height: 8)
                                Text(label.name).font(.caption.weight(.semibold)).frame(width: 90, alignment: .leading)
                                TextField(
                                    "Optional agent instructions",
                                    text: Binding(
                                        get: { labelInstructions[label.id, default: label.instructions] },
                                        set: { labelInstructions[label.id] = $0 }
                                    )
                                )
                                .textFieldStyle(.roundedBorder)
                                Button("Save") { Task { await saveLabel(label) } }
                                    .buttonStyle(DieterBarButtonStyle(size: 28)).disabled(saving)
                                Button {
                                    togglePreviewLabel(label.id)
                                } label: {
                                    Image(
                                        systemName: previewLabelIDs.contains(label.id)
                                            ? "checkmark.square.fill" : "square")
                                }.buttonStyle(.plain).help("Include this label in the preview")
                            }
                        }
                    }.promptPanel()
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("PREVIEW").promptSectionLabel()
                        Spacer()
                        if let preview {
                            Text("\(preview.estimatedTokens) estimated tokens · \(preview.source)").font(.caption2)
                                .foregroundStyle(DieterTheme.tertiary)
                        }
                        Button("Refresh preview") { Task { await loadPreview() } }
                            .buttonStyle(DieterBarButtonStyle(size: 28)).disabled(store.selectedProject == nil)
                    }
                    if let preview {
                        Text(preview.instructions).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                            .background(DieterTheme.input, in: RoundedRectangle(cornerRadius: 9))
                    } else {
                        Text("Choose a project and refresh to inspect the exact resolved agent instructions.")
                            .font(.caption).foregroundStyle(DieterTheme.tertiary).padding(.vertical, 10)
                    }
                }.promptPanel()
            }
            .padding(18)
        }
        .overlay { if loading { ProgressView().controlSize(.small) } }
        .task { await load() }
        .onChange(of: store.selectedProjectID) { _, _ in syncScopedTemplates() }
        .onChange(of: store.selectedBoardID) { _, _ in syncScopedTemplates() }
    }

    private var globalTemplate: Binding<String> {
        Binding(
            get: {
                switch globalKind {
                case "Board": settings.boardSkillTemplate
                case "Chat": settings.chatSkillTemplate
                default: settings.promptTemplate
                }
            },
            set: {
                switch globalKind {
                case "Board": settings.boardSkillTemplate = $0
                case "Chat": settings.chatSkillTemplate = $0
                default: settings.promptTemplate = $0
                }
            }
        )
    }

    private func scopedEditor(
        title: String, subtitle: String, inherits: Binding<Bool>, template: Binding<String>, disabled: Bool,
        save: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).promptSectionLabel()
            Text(subtitle).font(.caption.weight(.semibold)).lineLimit(1)
            Toggle("Inherit parent template", isOn: inherits)
                .font(.caption).disabled(disabled)
            TextEditor(text: template).font(.system(size: 10, design: .monospaced)).scrollContentBackground(.hidden)
                .padding(7).frame(height: 90).disabled(disabled || inherits.wrappedValue)
                .background(
                    DieterTheme.input.opacity(inherits.wrappedValue ? 0.45 : 1), in: RoundedRectangle(cornerRadius: 8))
            // A scoped template replaces the whole prompt, so the daemon checks its placeholders.
            let problem =
                inherits.wrappedValue ? "" : SharedRules.shared.promptTemplateProblem(template: template.wrappedValue)
            if !problem.isEmpty {
                Text(problem).font(.caption2).foregroundStyle(DieterTheme.coral)
            }
            HStack {
                Spacer()
                Button("Save", action: save).buttonStyle(DieterBarButtonStyle(size: 28))
                    .disabled(disabled || saving || !problem.isEmpty)
            }
        }.promptPanel().frame(maxWidth: .infinity)
    }

    private func load() async {
        loading = true
        if machineID.isEmpty { machineID = defaultMachineID }
        await loadGlobal()
        syncScopedTemplates()
        await loadPreview()
        loading = false
    }

    /// The selected project's machine, whose templates the preview resolves,
    /// else this Mac's, else any that can take work.
    private var defaultMachineID: String {
        let available = store.machines.filter(store.machineIsAvailable)
        let preferred = [store.projectMachine(forProjectID: store.selectedProjectID), store.localMachine]
            .compactMap { $0 }.first { available.contains($0) }
        return (preferred ?? available.first)?.daemonID ?? ""
    }

    private func loadGlobal() async {
        guard !machineID.isEmpty else { settings = Dieter_V1_PromptSettings(); return }
        do { settings = try await store.loadPromptSettings(daemonID: machineID) } catch { store.show(error) }
    }

    private func syncScopedTemplates() {
        projectTemplate = store.selectedProject?.promptTemplate ?? ""
        projectInherits = projectTemplate.isEmpty
        boardTemplate = store.selectedBoard?.promptTemplate ?? ""
        boardInherits = boardTemplate.isEmpty
        labelInstructions = Dictionary(
            uniqueKeysWithValues: (store.selectedBoard?.labels ?? []).map { ($0.id, $0.instructions) })
        previewLabelIDs = previewLabelIDs.intersection(Set(store.selectedBoard?.labels.map(\.id) ?? []))
    }

    private func saveGlobal() async {
        saving = true; defer { saving = false }
        do {
            settings = try await store.updatePromptSettings(settings, daemonID: machineID)
            await loadPreview()
        } catch { store.show(error) }
    }

    private func saveProject() async {
        guard store.selectedProject != nil else { return }
        saving = true; defer { saving = false }
        do {
            _ = try await store.setSelectedProjectPromptTemplate(inherit: projectInherits, template: projectTemplate)
            syncScopedTemplates()
            await loadPreview()
        } catch { store.show(error) }
    }

    private func saveBoard() async {
        guard store.selectedBoard != nil else { return }
        saving = true; defer { saving = false }
        do {
            _ = try await store.setSelectedBoardPromptTemplate(inherit: boardInherits, template: boardTemplate)
            syncScopedTemplates()
            await loadPreview()
        } catch { store.show(error) }
    }

    private func saveLabel(_ label: Dieter_V1_Label) async {
        guard store.selectedBoard != nil else { return }
        saving = true; defer { saving = false }
        do {
            _ = try await store.updatePromptInstructions(
                for: label,
                instructions: labelInstructions[label.id, default: label.instructions]
            )
            syncScopedTemplates()
            await loadPreview()
        } catch { store.show(error) }
    }

    private func loadPreview() async {
        guard store.selectedProject != nil else { preview = nil; return }
        do { preview = try await store.previewPrompt(labelIDs: previewLabelIDs) } catch { store.show(error) }
    }

    private func togglePreviewLabel(_ id: String) {
        if previewLabelIDs.contains(id) { previewLabelIDs.remove(id) } else { previewLabelIDs.insert(id) }
        Task { await loadPreview() }
    }
}

private extension View {
    func promptPanel() -> some View {
        padding(13).background(DieterTheme.surface.opacity(0.72), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(DieterTheme.border))
    }

    func promptSectionLabel() -> some View {
        font(DieterFont.sectionLabel).tracking(0.8).foregroundStyle(DieterTheme.tertiary)
    }
}
