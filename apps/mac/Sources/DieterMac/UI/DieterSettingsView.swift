import DieterAPI
import SwiftUI

enum DieterSettingsSection: String, CaseIterable, Identifiable, Hashable {
    case general = "General"
    case browser = "Browser"
    case connection = "Connection"
    case usage = "Usage"
    case prompts = "Prompts"
    case notifications = "Notifications"
    case island = "Island"
    case agents = "Agents"
    case experimental = "Experimental"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .browser: "globe"
        case .connection: "network"
        case .usage: "chart.bar.xaxis"
        case .prompts: "text.quote"
        case .notifications: "bell"
        case .island: "capsule.tophalf.filled"
        case .agents: "person.2"
        case .experimental: "flask"
        }
    }

    var subtitle: String {
        switch self {
        case .general: "Server, client, and project preferences"
        case .browser: "Choose which websites leave the workspace browser"
        case .connection: "Machines, gateways, and authentication"
        case .usage: "Provider accounts, limits, and reset windows"
        case .prompts: "Global and scoped agent instructions"
        case .notifications: "macOS alerts for agent activity"
        case .island: "Live activity around the notch"
        case .agents: "Harness capabilities"
        case .experimental: "Preview features that are still being refined"
        }
    }
}

struct DieterSettingsView: View {
    @Environment(DieterStore.self) private var store

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Settings").font(DieterFont.paneTitle)
                    Text("Dieter for macOS").font(DieterFont.subtitle).foregroundStyle(DieterTheme.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.top, 15).padding(.bottom, 9)

                VStack(spacing: 3) {
                    ForEach(DieterSettingsSection.allCases) { section in
                        Button {
                            store.settingsSection = section
                        } label: {
                            SettingsNavigationRow(section: section, selected: section == store.settingsSection)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("settings.\(section.rawValue.lowercased())")
                        .smokeTarget("settings.\(section.rawValue.lowercased())")
                    }
                }
                .padding(9)

                Spacer(minLength: 10)

                Divider().overlay(DieterTheme.border)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Dieter \(store.health.releaseVersion)")
                    Text(store.endpoint.address).lineLimit(1).help(store.endpoint.address)
                }
                .font(.caption2).foregroundStyle(DieterTheme.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
            .background(DieterTheme.sidebar)
            .frame(width: 220)

            Divider().overlay(DieterTheme.border)

            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.settingsSection.rawValue).font(.system(size: 18, weight: .semibold))
                    Text(store.settingsSection.subtitle).font(DieterFont.subtitle).foregroundStyle(
                        DieterTheme.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 12)
                .background(DieterTheme.background)

                Group {
                    switch store.settingsSection {
                    case .general: GeneralSettings()
                    case .browser: BrowserSettings()
                    case .connection: ConnectionSettings()
                    case .usage: UsageSettings()
                    case .prompts: PromptSettingsEditor()
                    case .notifications: NotificationSettings()
                    case .island: IslandSettings()
                    case .agents: AgentSettings()
                    case .experimental: ExperimentalSettings()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(DieterTheme.background)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(DieterTheme.background)
    }
}

private struct UsageSettings: View {
    var body: some View {
        SettingsPage {
            SettingsPanel(
                title: "Provider quotas",
                subtitle: "Usage limits discovered across all online enrolled machines."
            ) {
                ProviderQuotaDetailsView()
            }
        }
    }
}

private struct BrowserSettings: View {
    @State private var externalURLs: [String] = []
    @State private var newURL = ""
    @State private var invalidURL = false

    var body: some View {
        SettingsPage {
            SettingsPanel(
                title: "Always open externally",
                subtitle: "Matching links and sign-in redirects open in your default browser on this Mac."
            ) {
                Text(
                    "Add a host (github.com), a host and its subdomains (*.amazonaws.com), or an HTTP(S) URL path. Full URLs match that path and its children; hosts match exactly unless prefixed with *. "
                )
                .font(.caption).foregroundStyle(DieterTheme.subtle)
                .fixedSize(horizontal: false, vertical: true)
                ForEach(externalURLs, id: \.self) { entry in
                    HStack {
                        Text(entry).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                        Spacer()
                        Button("Remove", systemImage: "minus.circle") {
                            externalURLs.removeAll { $0 == entry }
                            save()
                        }
                        .labelStyle(.iconOnly)
                        .accessibilityLabel("Remove \(entry)")
                    }
                    Divider().overlay(DieterTheme.border)
                }
                HStack {
                    TextField("Host or URL", text: $newURL)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addURL)
                        .accessibilityIdentifier("settings.browser.externalURL")
                    Button("Add", action: addURL)
                        .disabled(newURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("settings.browser.addExternalURL")
                }
                if invalidURL {
                    Text("Enter a valid host or HTTP(S) URL without a query or fragment.")
                        .font(.caption).foregroundStyle(DieterTheme.coral)
                }
            }
        }
        .onAppear { externalURLs = ExternalBrowserRules.entries() }
    }

    private func addURL() {
        guard let value = ExternalBrowserRules.normalized(newURL) else {
            invalidURL = true
            return
        }
        if !externalURLs.contains(value) { externalURLs.append(value) }
        save()
        newURL = ""
        invalidURL = false
    }

    private func save() {
        DieterAppearance.applicationDefaults().set(externalURLs, forKey: ExternalBrowserRules.storageKey)
    }
}

private struct SettingsNavigationRow: View {
    let section: DieterSettingsSection
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: section.symbol).frame(width: 17)
            Text(section.rawValue)
            Spacer()
        }
        .font(.system(size: 12, weight: selected ? .semibold : .medium))
        .foregroundStyle(selected ? DieterTheme.text : DieterTheme.subtle)
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(
            selected ? DieterTheme.selection : Color.clear,
            in: RoundedRectangle(cornerRadius: DieterMetrics.controlRadius, style: .continuous)
        )
    }
}

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
                        Button("Save global templates") { Task { await saveGlobal() } }.buttonStyle(.borderedProminent)
                            .disabled(saving)
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
                                Button("Save") { Task { await saveLabel(label) } }.disabled(saving)
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
                        Button("Refresh preview") { Task { await loadPreview() } }.disabled(
                            store.selectedProject == nil)
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
            HStack {
                Spacer(); Button("Save", action: save).disabled(disabled || saving)
            }
        }.promptPanel().frame(maxWidth: .infinity)
    }

    private func load() async {
        loading = true
        do {
            if let value = try await store.loadPromptSettings() { settings = value }
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
        labelInstructions = Dictionary(
            uniqueKeysWithValues: (store.selectedBoard?.labels ?? []).map { ($0.id, $0.instructions) })
        previewLabelIDs = previewLabelIDs.intersection(Set(store.selectedBoard?.labels.map(\.id) ?? []))
    }

    private func saveGlobal() async {
        saving = true; defer { saving = false }
        do {
            if let value = try await store.updatePromptSettings(settings) { settings = value }
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

private struct SettingsPage<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            content
                .frame(maxWidth: 860, alignment: .leading)
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(DieterTheme.background)
    }
}

private struct SettingsPanel<Content: View>: View {
    let title: String
    var subtitle = ""
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title.uppercased()).font(DieterFont.sectionLabel).tracking(0.8).foregroundStyle(
                    DieterTheme.tertiary)
                if !subtitle.isEmpty { Text(subtitle).font(.system(size: 11)).foregroundStyle(DieterTheme.subtle) }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(DieterTheme.surface.opacity(0.72), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(DieterTheme.border))
    }
}

private struct SettingsValueRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 12) {
            Text(title).foregroundStyle(DieterTheme.subtle)
            Spacer()
            Text(value).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle).textSelection(
                .enabled)
        }
        .font(.system(size: 12))
        .padding(.vertical, 3)
    }
}

struct GeneralSettings: View {
    @Environment(DieterStore.self) private var store
    @State private var archiveConfirmation = false

    var body: some View {
        SettingsPage {
            VStack(spacing: 14) {
                if !store.failedOutboxItems.isEmpty {
                    SettingsPanel(
                        title: "Failed queued operations",
                        subtitle: "Queued prompt data is preserved until you explicitly retry or discard it."
                    ) {
                        ForEach(store.failedOutboxItems) { item in
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.operation).font(.system(size: 12, weight: .semibold))
                                    Text(item.targetID).font(.caption2.monospaced()).foregroundStyle(
                                        DieterTheme.tertiary)
                                    Text(item.failure).font(.caption).foregroundStyle(DieterTheme.coral).textSelection(
                                        .enabled)
                                    Text(item.createdAt.formatted()).font(.caption2).foregroundStyle(
                                        DieterTheme.tertiary)
                                }
                                Spacer()
                                Button("Retry") { Task { await store.retryOutboxItem(item.id) } }
                                Button("Discard", role: .destructive) {
                                    Task { await store.discardOutboxItem(item.id) }
                                }
                            }
                            if item.id != store.failedOutboxItems.last?.id { Divider().overlay(DieterTheme.border) }
                        }
                    }
                }
                SettingsPanel(
                    title: "Appearance",
                    subtitle: "Choose how Dieter looks on this Mac. Changes apply immediately to every window."
                ) {
                    HStack(spacing: 9) {
                        ForEach(DieterAppearance.allCases) { appearance in
                            AppearanceOption(
                                appearance: appearance,
                                selected: appearance == store.themeSelection.appearance
                            ) {
                                store.themeSelection.appearance = appearance
                            }
                        }
                    }
                    Divider().overlay(DieterTheme.border)
                    Toggle(
                        "Window transparency",
                        isOn: Binding(
                            get: { store.themeSelection.transparencyEnabled },
                            set: { store.themeSelection.transparencyEnabled = $0 }
                        )
                    )
                    .accessibilityIdentifier("settings.windowTransparency")
                    .smokeTarget("settings.windowTransparency")
                    Text("Let the desktop show through blurred workspace surfaces.")
                        .font(.caption)
                        .foregroundStyle(DieterTheme.tertiary)
                    if DieterTransparencyAccessibility.shared.reduceTransparency {
                        Text("macOS Reduce Transparency is on. Dieter uses solid surfaces and keeps your preference.")
                            .font(.caption)
                            .foregroundStyle(DieterTheme.subtle)
                    }
                }
                SettingsPanel(
                    title: "Design",
                    subtitle: "Changes every Dieter surface, terminal, accent, and the running app icon."
                ) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 9), count: 4), spacing: 9) {
                        ForEach(DieterPalette.allCases) { palette in
                            PaletteOption(
                                palette: palette,
                                selected: palette == store.themeSelection.palette
                            ) {
                                store.themeSelection.palette = palette
                            }
                        }
                    }
                }
                SettingsPanel(
                    title: "Conversations",
                    subtitle:
                        "Choose what appears in every conversation timeline. This preference is saved on this Mac."
                ) {
                    Picker(
                        "Default layout",
                        selection: Binding(
                            get: { store.defaultConversationMode },
                            set: { store.defaultConversationMode = $0 }
                        )
                    ) {
                        Text("Tabs").tag(ConversationDefaultMode.tabs)
                        Text("Workspace").tag(ConversationDefaultMode.workspace)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("settings.conversation.defaultMode")
                    Text("Applies when you open a different card or chat. You can still switch layouts in its header.")
                        .font(.caption)
                        .foregroundStyle(DieterTheme.tertiary)
                    Divider().overlay(DieterTheme.border)
                    Toggle(
                        "Show reasoning traces",
                        isOn: Binding(
                            get: { store.showReasoning },
                            set: { store.showReasoning = $0 }
                        )
                    )
                    .accessibilityIdentifier("settings.showReasoningTraces")
                    Text(
                        "Reasoning traces are hidden by default. Turn this on to show them alongside messages and tool calls."
                    )
                    .font(.caption)
                    .foregroundStyle(DieterTheme.tertiary)
                }
                SettingsPanel(
                    title: "Screen sharing",
                    subtitle: "Control fullscreen input and unattended connections."
                ) {
                    Toggle(
                        "Capture keyboard in fullscreen",
                        isOn: Binding(
                            get: { store.screensModel.captureFullscreenKeyboard },
                            set: { store.screensModel.captureFullscreenKeyboard = $0 })
                    )
                    .toggleStyle(.switch)
                    .accessibilityIdentifier("settings.screenShare.captureKeyboard")
                    .smokeTarget("settings.screenShare.captureKeyboard")
                    Text("Forward system shortcuts such as ⌘Tab to the remote Mac. Press ⌘⇧Esc to release input.")
                        .font(.caption).foregroundStyle(DieterTheme.tertiary)
                    Text(
                        "Accessibility access is required and checked automatically. Manage it in System Settings → Privacy & Security → Accessibility."
                    )
                    .font(.caption).foregroundStyle(DieterTheme.tertiary)
                    Divider().overlay(DieterTheme.border)
                    Toggle(
                        "Disconnect inactive screen shares",
                        isOn: Binding(
                            get: { store.screensModel.inactivityTimeoutEnabled },
                            set: { store.screensModel.inactivityTimeoutEnabled = $0 }
                        )
                    )
                    .toggleStyle(.switch)
                    .accessibilityIdentifier("settings.screenShare.inactivityTimeoutEnabled")
                    .smokeTarget("settings.screenShare.inactivityTimeoutEnabled")
                    if store.screensModel.inactivityTimeoutEnabled {
                        Divider().overlay(DieterTheme.border)
                        Stepper(
                            "Disconnect after \(store.screensModel.inactivityTimeoutMinutes) \(store.screensModel.inactivityTimeoutMinutes == 1 ? "minute" : "minutes")",
                            value: Binding(
                                get: { store.screensModel.inactivityTimeoutMinutes },
                                set: { store.screensModel.inactivityTimeoutMinutes = $0 }
                            ),
                            in: 1...240
                        )
                        .accessibilityIdentifier("settings.screenShare.inactivityTimeoutMinutes")
                        .smokeTarget("settings.screenShare.inactivityTimeoutMinutes")
                    }
                    Text(
                        store.screensModel.inactivityTimeoutEnabled
                            ? "Mouse, keyboard, tab, and screen-option activity reset the timer. Open shares continue when you navigate elsewhere in Dieter."
                            : "Automatic disconnection is off. Screen shares stay open until you disconnect or close their tab."
                    )
                    .font(.caption)
                    .foregroundStyle(DieterTheme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                SettingsPanel(
                    title: "Current project route", subtitle: "Dieter routes each project to the machine that owns it."
                ) {
                    SettingsValueRow(title: "Store", value: store.health.storePath)
                    Divider().overlay(DieterTheme.border)
                    SettingsValueRow(title: "Runtime", value: store.runtime.mode)
                    SettingsValueRow(title: "Ready", value: store.runtime.ready ? "Yes" : "No")
                    SettingsValueRow(title: "Sandboxed", value: store.runtime.sandboxed ? "Yes" : "No")
                }
                SettingsPanel(title: "Client") {
                    Toggle("Open Dieter at login", isOn: .constant(false)).disabled(true)
                    Text(
                        "The macOS client keeps no project metadata in working trees and communicates only through Dieter's authenticated API."
                    )
                    .font(.caption).foregroundStyle(DieterTheme.tertiary)
                }
                SettingsPanel(title: "Current project", subtitle: store.selectedProject?.name ?? "No project selected")
                {
                    HStack {
                        Text("Archiving hides the project without deleting Dieter data or its Git working tree.")
                            .font(.caption).foregroundStyle(DieterTheme.tertiary)
                        Spacer()
                        Button("Archive project…", role: .destructive) { archiveConfirmation = true }
                            .disabled(store.selectedProjectID.isEmpty)
                    }
                }
            }
        }
        .confirmationDialog("Archive \(store.selectedProject?.name ?? "project")?", isPresented: $archiveConfirmation) {
            Button("Archive project", role: .destructive) {
                Task { await store.setProjectArchived(id: store.selectedProjectID, archived: true) }
            }
        }
    }
}

private struct PaletteOption: View {
    let palette: DieterPalette
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: palette.previewColors, startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .overlay(Circle().stroke(.white.opacity(0.24)))
                    .frame(width: 24, height: 24)
                Text(palette.title)
                    .font(.system(size: 11, weight: selected ? .semibold : .medium))
                    .lineLimit(1)
                Spacer(minLength: 2)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(selected ? DieterTheme.shell : DieterTheme.tertiary)
            }
            .foregroundStyle(DieterTheme.text)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(
                selected ? DieterTheme.selection : DieterTheme.raised,
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(selected ? DieterTheme.shell.opacity(0.48) : DieterTheme.border)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(palette.title) design")
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityIdentifier("settings.palette.\(palette.rawValue)")
        .smokeTarget("settings.palette.\(palette.rawValue)")
    }
}

private struct AppearanceOption: View {
    let appearance: DieterAppearance
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: appearance.symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(selected ? DieterTheme.shellDeep : DieterTheme.subtle)
                    .frame(width: 24)
                Text(appearance.title)
                    .font(.system(size: 12, weight: selected ? .semibold : .medium))
                Spacer(minLength: 4)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(selected ? DieterTheme.shellDeep : DieterTheme.tertiary)
            }
            .foregroundStyle(DieterTheme.text)
            .padding(.horizontal, 11)
            .frame(maxWidth: .infinity, minHeight: 46)
            .background(
                selected ? DieterTheme.selection : DieterTheme.raised,
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(selected ? DieterTheme.shellDeep.opacity(0.42) : DieterTheme.border)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(appearance.title) appearance")
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityIdentifier("settings.appearance.\(appearance.rawValue)")
        .smokeTarget("settings.appearance.\(appearance.rawValue)")
    }
}

struct ConnectionSettings: View {
    @Environment(DieterStore.self) private var store
    @State private var name = ""
    @State private var address = ""
    @State private var pendingRevoke: DieterEndpoint?
    @State private var pendingRename: DieterEndpoint?
    @State private var pendingCleanSync = false

    var body: some View {
        SettingsPage {
            VStack(spacing: 14) {
                connectionExplanation
                activeConnection
                gatewayList
                machineList
                addGateway
            }
        }
        .sheet(item: $pendingRename) { machine in RenameMachineSheet(machine: machine).environment(store) }
        .confirmationDialog(
            "Revoke \(pendingRevoke?.name ?? "machine")?",
            isPresented: Binding(get: { pendingRevoke != nil }, set: { if !$0 { pendingRevoke = nil } })
        ) {
            Button("Revoke machine", role: .destructive) {
                if let endpoint = pendingRevoke { Task { await store.revokeDaemon(endpoint) } }
                pendingRevoke = nil
            }
        } message: {
            Text("This machine will lose gateway and direct access until it is enrolled again.")
        }
        .confirmationDialog("Start a clean sync?", isPresented: $pendingCleanSync) {
            Button("Clean sync", role: .destructive) {
                Task { await store.cleanSync() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Dieter will remove all cached workspace data on this Mac, keep your sign-in and pending changes, then download fresh snapshots. Content may briefly disappear."
            )
        }
    }

    private var connectionExplanation: some View {
        SettingsPanel(title: "How connections work") {
            HStack(spacing: 13) {
                ConnectionConcept(symbol: "laptopcomputer", title: "This Mac", detail: "Dieter app")
                Image(systemName: "arrow.right").foregroundStyle(DieterTheme.tertiary)
                ConnectionConcept(
                    symbol: "point.3.connected.trianglepath.dotted", title: "Gateway", detail: "Sign-in + discovery")
                Image(systemName: "arrow.right").foregroundStyle(DieterTheme.tertiary)
                ConnectionConcept(symbol: "desktopcomputer", title: "All machines", detail: "Projects + agents")
            }
            Text(
                "A gateway does not store projects or conversations. Dieter combines every machine enrolled through the active gateway and automatically routes each project action to its owner."
            )
            .font(.caption).foregroundStyle(DieterTheme.tertiary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var activeConnection: some View {
        SettingsPanel(title: "Automatic routing", subtitle: store.phase.label) {
            HStack(spacing: 10) {
                Image(systemName: "point.3.connected.trianglepath.dotted").foregroundStyle(DieterTheme.shell).frame(
                    width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.activeGateway.name).font(.system(size: 12, weight: .semibold))
                    Text("Gateway · \(store.activeGateway.address)").font(.caption2).foregroundStyle(
                        DieterTheme.tertiary)
                }
                Spacer()
                if store.phase == .authenticationRequired {
                    Button("Sign in with GitHub") { Task { await store.signIn() } }.buttonStyle(.borderedProminent)
                }
            }
            Divider().overlay(DieterTheme.border)
            HStack(spacing: 10) {
                Circle().fill(store.phase.isConnected ? DieterTheme.eyes : DieterTheme.amber).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(store.projects.count) projects across \(store.machines.count) machines").font(
                        .system(size: 12, weight: .semibold))
                    Text("Project actions are routed to their host automatically.").font(.caption2).foregroundStyle(
                        DieterTheme.tertiary)
                }
                Spacer()
                HStack(spacing: 8) {
                    Button("Reconnect") { Task { await store.connect() } }
                    Button("Clean sync…") { pendingCleanSync = true }
                        .accessibilityIdentifier("settings.connection.clean-sync")
                }
            }
            Text(
                "Clean sync discards this Mac's cached snapshots and sync cursors, then rebuilds the workspace from every machine. Sign-in and pending changes are kept."
            )
            .font(.caption2).foregroundStyle(DieterTheme.tertiary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var gatewayList: some View {
        SettingsPanel(title: "Gateways", subtitle: "Choose one to sign in and discover its enrolled machines.") {
            ForEach(store.gateways) { gateway in
                HStack(spacing: 10) {
                    Image(systemName: "network").foregroundStyle(DieterTheme.shell).frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(gateway.name).font(.system(size: 12, weight: .semibold))
                            if gateway.credentialID == DieterEndpoint.defaults.first?.credentialID {
                                Text("PRIMARY").font(.system(size: 8, weight: .bold)).foregroundStyle(DieterTheme.eyes)
                                    .padding(.horizontal, 5).frame(height: 16).background(
                                        DieterTheme.eyes.opacity(0.1), in: Capsule())
                            }
                        }
                        Text(gateway.address).font(.caption2).foregroundStyle(DieterTheme.tertiary)
                    }
                    Spacer()
                    if gateway.credentialID == store.activeGateway.credentialID {
                        Text("Active gateway").font(.caption2).foregroundStyle(DieterTheme.eyes)
                    }
                    Button("Use gateway") { Task { await store.chooseGateway(gateway) } }
                    if store.gateways.count > 1 {
                        Button(role: .destructive) {
                            store.deleteEndpoint(gateway)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain).disabled(gateway.credentialID == store.activeGateway.credentialID)
                        .help("Remove gateway")
                    }
                }
                if gateway.id != store.gateways.last?.id { Divider().overlay(DieterTheme.border) }
            }
        }
    }

    private var machineList: some View {
        SettingsPanel(
            title: "Machines discovered through \(store.activeGateway.name)",
            subtitle: store.machines.isEmpty
                ? "Sign in to this gateway to load its machines."
                : "Projects and conversations stay on these machines, never on the gateway."
        ) {
            if store.machines.isEmpty {
                Text("No machines discovered yet.").font(.caption).foregroundStyle(DieterTheme.tertiary).padding(
                    .vertical, 5)
            }
            ForEach(store.machines) { machine in
                HStack(spacing: 10) {
                    Circle().fill(machine.online ? DieterTheme.eyes : DieterTheme.tertiary).frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(machine.name).font(.system(size: 12, weight: .semibold))
                        Text(machineSummary(machine)).font(.caption2).foregroundStyle(DieterTheme.tertiary)
                    }
                    Spacer()
                    Button {
                        pendingRename = machine
                    } label: {
                        Image(systemName: "pencil")
                    }.buttonStyle(.plain).help("Rename machine")
                    Button(role: .destructive) {
                        pendingRevoke = machine
                    } label: {
                        Image(systemName: "trash")
                    }.buttonStyle(.plain).help("Revoke machine")
                }
                if machine.id != store.machines.last?.id { Divider().overlay(DieterTheme.border) }
            }
        }
    }

    private var addGateway: some View {
        SettingsPanel(
            title: "Add another gateway",
            subtitle: "Use this only for a separate Dieter deployment. It has a separate sign-in and machine directory."
        ) {
            HStack(spacing: 9) {
                TextField("Display name", text: $name)
                TextField("https://dieter.example.com", text: $address)
                Button("Save and discover") {
                    if let gateway = DieterEndpoint.parse(address, name: name.isEmpty ? "Custom gateway" : name),
                        gateway.secure
                    {
                        Task { await store.saveEndpoint(gateway) }
                        name = ""; address = ""
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(DieterEndpoint.parse(address)?.secure != true)
            }
            Text(
                "Gateway sessions are stored in Dieter's private app data directory. Dieter prefers verified direct TLS to a discovered machine and otherwise uses the gateway's encrypted relay."
            )
            .font(.caption2).foregroundStyle(DieterTheme.tertiary)
        }
    }

    private func machineSummary(_ machine: DieterEndpoint) -> String {
        if let incompatibility = machine.incompatibilityDescription { return incompatibility }
        if let connectionError = store.machineConnectionErrors[machine.id] { return connectionError }
        guard machine.online else { return MachinePresenceText.lastSeen(machine.lastSeenAt) }
        if let status = store.connectionStatus(for: machine) {
            return "\(status.route.rawValue) · \(status.latencyMilliseconds) ms"
        }
        return machine.releaseVersion.isEmpty ? "Online" : "Online · Dieter \(machine.releaseVersion)"
    }
}

private struct ConnectionConcept: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(DieterTheme.shell)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 11, weight: .semibold))
                Text(detail).font(.system(size: 9)).foregroundStyle(DieterTheme.tertiary)
            }
        }
        .padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .background(DieterTheme.input, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(DieterTheme.border))
    }
}

struct NotificationSettings: View {
    @Environment(DieterStore.self) private var store
    @State private var enabled = UserDefaults.standard.bool(forKey: "DieterNotifications")

    var body: some View {
        SettingsPage {
            VStack(spacing: 14) {
                SettingsPanel(title: "Agent activity", subtitle: "Choose whether Dieter can alert you outside the app.")
                {
                    Toggle("Show macOS notifications", isOn: $enabled)
                        .onChange(of: enabled) { _, value in
                            UserDefaults.standard.set(value, forKey: "DieterNotifications")
                            if value { store.requestNotifications() }
                        }
                    Divider().overlay(DieterTheme.border)
                    Toggle("Review requested", isOn: .constant(true))
                    Toggle("Agent failed", isOn: .constant(true))
                    Toggle("Agent completed", isOn: .constant(true))
                }
                SettingsPanel(title: "Delivery") {
                    Text(
                        "Notifications come from state transitions on the synchronized Dieter stream. Clicking one opens the same durable conversation."
                    )
                    .font(.caption).foregroundStyle(DieterTheme.tertiary)
                }
            }
        }
    }
}

struct IslandSettings: View {
    @AppStorage(DieterIslandPreferences.enabledKey, store: DieterAppearance.applicationDefaults())
    private var enabled = DieterIslandPreferences.defaultEnabled

    var body: some View {
        SettingsPage {
            VStack(spacing: 14) {
                SettingsPanel(
                    title: "Dieter Island",
                    subtitle: "See active turns and reviews without leaving the app you are working in."
                ) {
                    Toggle("Show live activity around the notch", isOn: $enabled)
                        .font(.system(size: 12, weight: .semibold))
                        .toggleStyle(.switch)
                        .accessibilityIdentifier("settings.island.enabled")
                    Text(
                        "Hover the Island to expand a compact activity list. Choose a conversation to jump back into the same durable Dieter session."
                    )
                    .font(.caption)
                    .foregroundStyle(DieterTheme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    DieterIslandSettingsPreview()
                        .opacity(enabled ? 1 : 0.42)
                        .animation(.easeOut(duration: 0.18), value: enabled)
                }
                SettingsPanel(title: "Display behavior") {
                    HStack(alignment: .top, spacing: 11) {
                        Image(systemName: "macbook")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(DieterTheme.primary)
                            .frame(width: 25)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Notch-aware on MacBook")
                                .font(.system(size: 12, weight: .semibold))
                            Text(
                                "Dieter aligns to the built-in camera housing. On a display without a notch, it becomes a floating pill at the top right."
                            )
                            .font(.caption)
                            .foregroundStyle(DieterTheme.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Divider().overlay(DieterTheme.border)
                    HStack(alignment: .top, spacing: 11) {
                        Image(systemName: "rectangle.on.rectangle")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(DieterTheme.eyes)
                            .frame(width: 25)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Available across Spaces")
                                .font(.system(size: 12, weight: .semibold))
                            Text(
                                "The Island follows macOS Spaces and remains available beside full-screen apps without taking keyboard focus."
                            )
                            .font(.caption)
                            .foregroundStyle(DieterTheme.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                SettingsPanel(title: "Activity source") {
                    Text(
                        "The Island uses the same bounded synchronized card stream as Dieter's board and menu bar. It does not start another connection or duplicate notifications."
                    )
                    .font(.caption)
                    .foregroundStyle(DieterTheme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

struct ExperimentalSettings: View {
    @Environment(DieterStore.self) private var store

    var body: some View {
        SettingsPage {
            VStack(spacing: 14) {
                SettingsPanel(
                    title: "Screen sharing resolution",
                    subtitle: "Match the remote desktop to your fullscreen display."
                ) {
                    HStack {
                        Text("Match remote resolution in fullscreen")
                            .font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Toggle(
                            "Match remote resolution in fullscreen",
                            isOn: Binding(
                                get: { store.screensModel.matchClientResolution },
                                set: { store.screensModel.matchClientResolution = $0 })
                        )
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .accessibilityLabel("Match remote resolution in fullscreen")
                        .accessibilityIdentifier("settings.experimental.screenResolution")
                        .smokeTarget("settings.experimental.screenResolution")
                    }
                    Text(
                        "Off by default. Temporarily changes the remote monitor for everyone using it, using the closest supported resolution and Retina scale. Restores on fullscreen exit or disconnect. Video quality limits still apply."
                    )
                    .font(.caption).foregroundStyle(DieterTheme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

struct AgentSettings: View {
    @Environment(DieterStore.self) private var store

    var body: some View {
        SettingsPage {
            VStack(spacing: 14) {
                SettingsPanel(title: "Harness capabilities") {
                    ForEach(store.harnessCatalog.harnesses, id: \.id) { harness in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(harness.name).font(.system(size: 12, weight: .semibold))
                            Text(harness.models.map(\.name).joined(separator: ", ")).font(.caption).foregroundStyle(
                                DieterTheme.tertiary)
                        }
                        if harness.id != store.harnessCatalog.harnesses.last?.id {
                            Divider().overlay(DieterTheme.border)
                        }
                    }
                }
            }
        }
    }
}
