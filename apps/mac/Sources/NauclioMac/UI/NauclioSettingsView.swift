import NauclioAPI
import SwiftUI

enum NauclioSettingsSection: String, CaseIterable, Identifiable, Hashable {
    case general = "General"
    case connection = "Connection"
    case prompts = "Prompts"
    case notifications = "Notifications"
    case agents = "Agents"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .connection: "network"
        case .prompts: "text.quote"
        case .notifications: "bell"
        case .agents: "person.2"
        }
    }

    var subtitle: String {
        switch self {
        case .general: "Server, client, and project preferences"
        case .connection: "Machines, gateways, and authentication"
        case .prompts: "Global and scoped agent instructions"
        case .notifications: "macOS alerts for agent activity"
        case .agents: "Parallel limits and harness capabilities"
        }
    }
}

struct NauclioSettingsView: View {
    @Environment(NauclioStore.self) private var store
    @State private var selection: NauclioSettingsSection? = .general

    private var selectedSection: NauclioSettingsSection { selection ?? .general }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Settings").font(.system(size: 18, weight: .bold))
                    Text("Nauclio for macOS").font(.caption).foregroundStyle(NauclioTheme.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.vertical, 15)

                Divider().overlay(NauclioTheme.border)

                List(selection: $selection) {
                    ForEach(NauclioSettingsSection.allCases) { section in
                        Label(section.rawValue, systemImage: section.symbol)
                            .font(.system(size: 12, weight: section == selectedSection ? .semibold : .medium))
                            .foregroundStyle(section == selectedSection ? Color.white : NauclioTheme.subtle)
                            .tag(section)
                            .accessibilityIdentifier("settings.\(section.rawValue.lowercased())")
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)

                Divider().overlay(NauclioTheme.border)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Nauclio \(store.health.version)")
                    Text(store.endpoint.address).lineLimit(1).help(store.endpoint.address)
                }
                .font(.caption2).foregroundStyle(NauclioTheme.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
            .background(NauclioTheme.sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 260)
        } detail: {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(selectedSection.rawValue).font(.system(size: 22, weight: .bold))
                    Text(selectedSection.subtitle).font(.caption).foregroundStyle(NauclioTheme.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22).padding(.vertical, 17)
                .background(NauclioTheme.background)

                Divider().overlay(NauclioTheme.border)

                Group {
                    switch selectedSection {
                    case .general: GeneralSettings()
                    case .connection: ConnectionSettings()
                    case .prompts: PromptSettingsEditor()
                    case .notifications: NotificationSettings()
                    case .agents: AgentSettings()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(NauclioTheme.background)
        }
        .navigationSplitViewStyle(.balanced)
    }
}

struct PromptSettingsEditor: View {
    @Environment(NauclioStore.self) private var store
    @State private var settings = Nauclio_V1_PromptSettings()
    @State private var globalKind = "Context"
    @State private var projectTemplate = ""
    @State private var boardTemplate = ""
    @State private var projectInherits = true
    @State private var boardInherits = true
    @State private var labelInstructions: [String: String] = [:]
    @State private var previewLabelIDs: Set<String> = []
    @State private var preview: Nauclio_V1_PromptPreview?
    @State private var loading = true
    @State private var saving = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("GLOBAL TEMPLATES").promptSectionLabel()
                        Spacer()
                        Picker("Template", selection: $globalKind) {
                            Text("Context").tag("Context")
                            Text("Board skill").tag("Board")
                            Text("Chat skill").tag("Chat")
                        }.labelsHidden().pickerStyle(.segmented).frame(width: 300)
                    }
                    TextEditor(text: globalTemplate)
                        .font(.system(size: 11, design: .monospaced)).scrollContentBackground(.hidden)
                        .padding(9).frame(minHeight: 150)
                        .background(NauclioTheme.input, in: RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(NauclioTheme.strongBorder))
                    if !settings.variables.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                Text("Variables").font(.caption2).foregroundStyle(NauclioTheme.tertiary)
                                ForEach(settings.variables, id: \.self) { Text($0).font(.caption2.monospaced()).padding(.horizontal, 7).frame(height: 22).background(NauclioTheme.raised, in: Capsule()) }
                            }
                        }
                    }
                    HStack { Spacer(); Button("Save global templates") { Task { await saveGlobal() } }.buttonStyle(.borderedProminent).disabled(saving) }
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
                            Text("Included only when a card carries the label").font(.caption2).foregroundStyle(NauclioTheme.tertiary)
                        }
                        ForEach(board.labels, id: \.id) { label in
                            HStack(spacing: 9) {
                                Circle().fill(Color(hex: label.color) ?? NauclioTheme.cobalt).frame(width: 8, height: 8)
                                Text(label.name).font(.caption.weight(.semibold)).frame(width: 90, alignment: .leading)
                                TextField("Optional agent instructions", text: Binding(
                                    get: { labelInstructions[label.id, default: label.instructions] },
                                    set: { labelInstructions[label.id] = $0 }
                                ))
                                .textFieldStyle(.roundedBorder)
                                Button("Save") { Task { await saveLabel(label) } }.disabled(saving)
                                Button { togglePreviewLabel(label.id) } label: {
                                    Image(systemName: previewLabelIDs.contains(label.id) ? "checkmark.square.fill" : "square")
                                }.buttonStyle(.plain).help("Include this label in the preview")
                            }
                        }
                    }.promptPanel()
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("PREVIEW").promptSectionLabel()
                        Spacer()
                        if let preview { Text("\(preview.estimatedTokens) estimated tokens · \(preview.source)").font(.caption2).foregroundStyle(NauclioTheme.tertiary) }
                        Button("Refresh preview") { Task { await loadPreview() } }.disabled(store.selectedProject == nil)
                    }
                    if let preview {
                        Text(preview.instructions).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                            .background(NauclioTheme.input, in: RoundedRectangle(cornerRadius: 9))
                    } else {
                        Text("Choose a project and refresh to inspect the exact resolved agent instructions.")
                            .font(.caption).foregroundStyle(NauclioTheme.tertiary).padding(.vertical, 10)
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

    private func scopedEditor(title: String, subtitle: String, inherits: Binding<Bool>, template: Binding<String>, disabled: Bool, save: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).promptSectionLabel()
            Text(subtitle).font(.caption.weight(.semibold)).lineLimit(1)
            Toggle("Inherit parent template", isOn: inherits)
                .font(.caption).disabled(disabled)
            TextEditor(text: template).font(.system(size: 10, design: .monospaced)).scrollContentBackground(.hidden)
                .padding(7).frame(height: 90).disabled(disabled || inherits.wrappedValue)
                .background(NauclioTheme.input.opacity(inherits.wrappedValue ? 0.45 : 1), in: RoundedRectangle(cornerRadius: 8))
            HStack { Spacer(); Button("Save", action: save).disabled(disabled || saving) }
        }.promptPanel().frame(maxWidth: .infinity)
    }

    private func load() async {
        loading = true
        do {
            if let rpc = store.rpc { settings = try await rpc.promptSettings() }
            syncScopedTemplates()
            await loadPreview()
        } catch { store.show(error) }
        loading = false
    }

    private func syncScopedTemplates() {
        projectTemplate = store.selectedProject?.promptTemplate ?? ""
        projectInherits = projectTemplate.isEmpty
        boardTemplate = store.selectedBoard?.promptTemplate ?? ""
        boardInherits = boardTemplate.isEmpty
        labelInstructions = Dictionary(uniqueKeysWithValues: (store.selectedBoard?.labels ?? []).map { ($0.id, $0.instructions) })
        previewLabelIDs = previewLabelIDs.intersection(Set(store.selectedBoard?.labels.map(\.id) ?? []))
    }

    private func saveGlobal() async {
        guard let rpc = store.rpc else { return }
        saving = true; defer { saving = false }
        var request = Nauclio_V1_UpdatePromptSettingsRequest()
        request.promptTemplate = settings.promptTemplate
        request.boardSkillTemplate = settings.boardSkillTemplate
        request.chatSkillTemplate = settings.chatSkillTemplate
        do { settings = try await rpc.updatePromptSettings(request); await loadPreview() } catch { store.show(error) }
    }

    private func saveProject() async {
        guard let rpc = store.rpc, let project = store.selectedProject else { return }
        saving = true; defer { saving = false }
        var request = Nauclio_V1_SetScopedPromptTemplateRequest()
        request.scopeID = project.id; request.inherit = projectInherits; request.promptTemplate = projectTemplate
        do { _ = try await rpc.setProjectPromptTemplate(request); await store.refreshState(); syncScopedTemplates(); await loadPreview() } catch { store.show(error) }
    }

    private func saveBoard() async {
        guard let rpc = store.rpc, let board = store.selectedBoard else { return }
        saving = true; defer { saving = false }
        var request = Nauclio_V1_SetScopedPromptTemplateRequest()
        request.scopeID = board.id; request.inherit = boardInherits; request.promptTemplate = boardTemplate
        do { _ = try await rpc.setBoardPromptTemplate(request); await store.refreshState(); syncScopedTemplates(); await loadPreview() } catch { store.show(error) }
    }

    private func saveLabel(_ label: Nauclio_V1_Label) async {
        guard let rpc = store.rpc, let board = store.selectedBoard else { return }
        saving = true; defer { saving = false }
        var request = Nauclio_V1_UpdateBoardLabelRequest()
        request.boardID = board.id; request.labelID = label.id
        request.name = label.name; request.color = label.color
        request.instructions = labelInstructions[label.id, default: label.instructions]
        do { _ = try await rpc.updateBoardLabel(request); await store.refreshState(); syncScopedTemplates(); await loadPreview() } catch { store.show(error) }
    }

    private func loadPreview() async {
        guard let rpc = store.rpc, let project = store.selectedProject else { preview = nil; return }
        var request = Nauclio_V1_PreviewPromptRequest()
        request.projectID = project.id; request.boardID = store.selectedBoard?.id ?? ""
        request.scope = request.boardID.isEmpty ? "chat" : "board"
        request.labelIds = Array(previewLabelIDs)
        do { preview = try await rpc.previewPrompt(request) } catch { store.show(error) }
    }

    private func togglePreviewLabel(_ id: String) {
        if previewLabelIDs.contains(id) { previewLabelIDs.remove(id) } else { previewLabelIDs.insert(id) }
        Task { await loadPreview() }
    }
}

private extension View {
    func promptPanel() -> some View {
        padding(13).background(NauclioTheme.surface.opacity(0.72), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(NauclioTheme.border))
    }

    func promptSectionLabel() -> some View {
        font(.system(size: 9, weight: .bold)).tracking(0.7).foregroundStyle(NauclioTheme.tertiary)
    }
}

struct GeneralSettings: View {
    @Environment(NauclioStore.self) private var store
    @State private var archiveConfirmation = false
    var body: some View {
        Form {
            Section("Server") { LabeledContent("Store", value: store.health.storePath); LabeledContent("Runtime", value: store.runtime.mode); LabeledContent("Ready", value: store.runtime.ready ? "Yes" : "No"); LabeledContent("Sandboxed", value: store.runtime.sandboxed ? "Yes" : "No") }
            Section("Client") { Toggle("Open Nauclio at login", isOn: .constant(false)).disabled(true); Text("The macOS client keeps no project metadata in working trees and communicates only through Nauclio's API.").font(.caption).foregroundStyle(.secondary) }
            Section("Project") { Button("Archive current project…", role: .destructive) { archiveConfirmation = true }.disabled(store.selectedProjectID.isEmpty); Text("Archiving removes the project from active views without deleting its Nauclio data or Git working tree.").font(.caption).foregroundStyle(.secondary) }
        }.formStyle(.grouped)
            .confirmationDialog("Archive \(store.selectedProject?.name ?? "project")?", isPresented: $archiveConfirmation) { Button("Archive project", role: .destructive) { Task { await store.setProjectArchived(id: store.selectedProjectID, archived: true) } } }
    }
}

struct ConnectionSettings: View {
    @Environment(NauclioStore.self) private var store
    @State private var name = ""
    @State private var address = ""
    @State private var pendingRevoke: NauclioEndpoint?
    @State private var pendingRename: NauclioEndpoint?

    var body: some View {
        Form {
            Section("Active connection") { HStack { Circle().fill(store.phase.isConnected ? NauclioTheme.seafoam : NauclioTheme.coral).frame(width: 8, height: 8); VStack(alignment: .leading) { Text(store.endpoint.name).fontWeight(.semibold); Text(store.endpoint.address).font(.caption).foregroundStyle(.secondary) }; Spacer(); if store.phase == .authenticationRequired { Button("Sign in with GitHub") { Task { await store.signIn() } } } else { Button("Reconnect") { Task { await store.connect() } } } } }
            Section("Available daemons") {
                ForEach(store.endpoints) { endpoint in
                    HStack { VStack(alignment: .leading) { Text(endpoint.name); Text(endpoint.address).font(.caption).foregroundStyle(.secondary) }; Spacer(); if endpoint == store.endpoint { Text("Active").font(.caption).foregroundStyle(NauclioTheme.seafoam) } else { Button("Connect") { Task { await store.setEndpoint(endpoint) } } }; if endpoint.daemonID != nil { Button { pendingRename = endpoint } label: { Image(systemName: "pencil") }.buttonStyle(.plain).help("Rename machine") }; Button(role: .destructive) { if endpoint.daemonID != nil { pendingRevoke = endpoint } else { store.deleteEndpoint(endpoint) } } label: { Image(systemName: "trash") }.buttonStyle(.plain).disabled(endpoint.daemonID == nil && store.endpoints.count == 1) }
                }
            }
            Section("Add gateway") { TextField("Name", text: $name); TextField("https://nauclio.example.com", text: $address); Button("Save and connect") { if let endpoint = NauclioEndpoint.parse(address, name: name.isEmpty ? "Custom" : name), endpoint.secure { Task { await store.saveEndpoint(endpoint) }; name = ""; address = "" } }.disabled(NauclioEndpoint.parse(address)?.secure != true) }
            Section { Text("The gateway session is stored unencrypted in a user-only local file, not in Keychain. Nauclio discovers your daemons, prefers a verified direct TLS route, and falls back to the encrypted gateway relay.").font(.caption).foregroundStyle(.secondary) }
        }.formStyle(.grouped)
            .sheet(item: $pendingRename) { machine in RenameMachineSheet(machine: machine).environment(store) }
            .confirmationDialog("Revoke \(pendingRevoke?.name ?? "daemon")?", isPresented: Binding(get: { pendingRevoke != nil }, set: { if !$0 { pendingRevoke = nil } })) {
                Button("Revoke daemon", role: .destructive) {
                    if let endpoint = pendingRevoke { Task { await store.revokeDaemon(endpoint) } }
                    pendingRevoke = nil
                }
            } message: { Text("This machine will lose gateway and direct access until it is enrolled again.") }
    }
}

struct NotificationSettings: View {
    @Environment(NauclioStore.self) private var store
    @State private var enabled = UserDefaults.standard.bool(forKey: "NauclioNotifications")
    var body: some View {
        Form {
            Section("Agent activity") { Toggle("Show macOS notifications", isOn: $enabled).onChange(of: enabled) { _, value in UserDefaults.standard.set(value, forKey: "NauclioNotifications"); if value { store.requestNotifications() } }; Toggle("Review requested", isOn: .constant(true)); Toggle("Agent failed", isOn: .constant(true)); Toggle("Agent completed", isOn: .constant(true)) }
            Section { Text("Notifications are generated by state transitions observed on the gRPC stream. Clicking a menu-bar task opens its durable conversation.").font(.caption).foregroundStyle(.secondary) }
        }.formStyle(.grouped)
    }
}

struct AgentSettings: View {
    @Environment(NauclioStore.self) private var store
    @State private var global = 1
    @State private var agentLimits: [String: Int] = [:]
    @State private var boardLimits: [String: Int] = [:]

    var body: some View {
        Form {
            Section("Parallel sessions") {
                Stepper("Global limit: \(global)", value: $global, in: 1...64)
                ForEach(store.harnessCatalog.harnesses, id: \.id) { harness in
                    Stepper("\(harness.name): \(agentLimits[harness.id, default: 0])", value: Binding(get: { agentLimits[harness.id, default: 0] }, set: { agentLimits[harness.id] = $0 }), in: 0...64)
                }
                DisclosureGroup("Per-board limits") {
                    ForEach(store.settingsOptions.boards, id: \.id) { board in
                        Stepper("\(board.name): \(boardLimits[board.id, default: 0])", value: Binding(get: { boardLimits[board.id, default: 0] }, set: { boardLimits[board.id] = $0 }), in: 0...64)
                    }
                }
                Button("Save parallel limits") { Task { await store.updateLimits(global: global, agents: agentLimits, boards: boardLimits) } }
            }
            Section("Capabilities") { ForEach(store.harnessCatalog.harnesses, id: \.id) { harness in VStack(alignment: .leading) { Text(harness.name).fontWeight(.semibold); Text(harness.models.map(\.name).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary) } } }
        }.formStyle(.grouped).onAppear { global = max(1, Int(store.boardSettings.globalParallelLimit)); agentLimits = store.boardSettings.agentParallelLimits.mapValues(Int.init); boardLimits = store.boardSettings.boardParallelLimits.mapValues(Int.init) }
    }
}
