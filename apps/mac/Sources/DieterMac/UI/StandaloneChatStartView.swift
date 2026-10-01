import AppKit
import DieterAPI
import SwiftUI
import UniformTypeIdentifiers

struct StandaloneChatStartView: View {
    @Environment(DieterStore.self) private var store
    @State private var prompt = ""
    @State private var machineID = ""
    @State private var projectID = ""
    @State private var checkoutID = ""
    @State private var provider = ""
    @State private var model = ""
    @State private var effort = ""
    @State private var providerOptions: [String: String] = [:]
    @State private var submitting = false
    @State private var attachments: [Dieter_V1_MessagePart] = []
    @State private var fileImporterPresented = false
    @State private var attachmentDropTargeted = false
    @FocusState private var promptFocused: Bool
    @State private var workspaceDraft = ConversationWorkspaceDraft()
    @State private var destinationHarnesses: [Dieter_V1_Harness] = []
    @State private var harnessCatalogLoading = false
    @State private var harnessCatalogError: String?
    @State private var harnessCatalogRetry = 0
    @State private var harnessCatalogRequestID = UUID()

    private struct HarnessLoadID: Hashable {
        let projectID: String
        let checkoutID: String
        let endpointID: String
        let connected: Bool
        let retry: Int
    }

    private let suggestions = [
        (
            "Explore the codebase",
            "Explore this codebase and explain its architecture, important entry points, and current risks."
        ),
        ("Build a feature", "Help me design and implement a new feature in this project."),
        (
            "Review recent changes",
            "Review the recent changes in this repository and identify correctness or maintainability issues."
        ),
        (
            "Fix a failure",
            "Investigate the current failures in this project, find the root cause, and implement a verified fix."
        ),
    ]

    private var availableProjects: [Dieter_V1_Project] { store.projects.filter { !$0.archived } }
    private var destinationGroups: [ProjectDestinationGroup] {
        store.projectDestinationGroups(projects: availableProjects)
    }
    private var destinationGroup: ProjectDestinationGroup? {
        destinationGroups.first { $0.machineID == machineID }
    }
    private var machineDestinations: [ProjectDestination] {
        destinationGroup?.destinations ?? []
    }
    private var destination: ProjectDestination? {
        ProjectDestinationCatalog.destination(
            machineID: machineID,
            projectID: projectID,
            checkoutID: checkoutID,
            in: destinationGroups
        )
    }
    private var project: Dieter_V1_Project? { destination?.project }
    private var harness: Dieter_V1_Harness? { destinationHarnesses.first { $0.id == provider } }
    private var selectedModel: Dieter_V1_HarnessModel? { harness?.models.first { $0.id == model } }
    var body: some View {
        VStack(spacing: 0) {
            FluidPaneChrome(background: .clear, spacing: 8) {
                HStack {
                    PaneTitleBlock(
                        title: "New chat",
                        subtitle: destination.map {
                            "\($0.project.name) on \($0.machineName) · Standalone chat"
                        }
                            ?? "Choose a machine and project · Standalone chat",
                        symbol: "bubble.left"
                    )
                    StatusPill(text: "New")
                }
            } secondary: {
                HStack(spacing: 7) {
                    Image(systemName: "info.circle").foregroundStyle(DieterTheme.shell)
                    Text("Standalone chats stay in their project folder and never become board cards.")
                    Spacer()
                }
                .font(.caption2).foregroundStyle(DieterTheme.tertiary)
            }

            Spacer(minLength: 24)
            VStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 15, style: .continuous).fill(
                        DieterTheme.shellDeep.opacity(0.16)
                    )
                    .frame(width: 60, height: 60)
                    Image(systemName: "bubble.left").font(.system(size: 23, weight: .medium)).foregroundStyle(
                        DieterTheme.shell)
                }
                Text("What should we work on?").font(.system(size: 22, weight: .semibold))
                Text(
                    "Start a standalone local conversation in one of your project folders.\nIt never becomes a dieter card."
                )
                .font(.system(size: 13)).foregroundStyle(DieterTheme.subtle).multilineTextAlignment(.center)
                .lineSpacing(3)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(suggestions, id: \.0) { suggestion in
                        Button {
                            prompt = suggestion.1
                        } label: {
                            HStack {
                                Image(systemName: "sparkles").font(.system(size: 10)).foregroundStyle(
                                    DieterTheme.shell)
                                Text(suggestion.0).font(.system(size: 12, weight: .medium))
                                Spacer()
                            }
                            .padding(.horizontal, 13).frame(height: 46)
                            .background(
                                DieterTheme.surface.opacity(0.7),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(DieterTheme.border))
                        }.buttonStyle(.plain)
                    }
                }.frame(maxWidth: 590)
            }
            Spacer(minLength: 24)

            newChatComposer
                .padding(.horizontal, 14).padding(.vertical, 12)
        }
        .attachmentIntake(
            store: store,
            importerPresented: $fileImporterPresented,
            attachments: $attachments
        )
        .onAppear { chooseDestination() }
        .onChange(of: store.newChatProjectID) { _, value in
            if !value.isEmpty { chooseDestination(preferredProjectID: value) }
        }
        .onChange(of: destinationGroups) { _, _ in reconcileDestination() }
        .task(
            id: HarnessLoadID(
                projectID: projectID, checkoutID: checkoutID, endpointID: store.endpoint.id,
                connected: store.phase.isConnected, retry: harnessCatalogRetry)
        ) { await loadDestinationHarnesses(for: projectID, checkoutID: checkoutID) }
    }

    private var canSubmit: Bool {
        !submitting && !harnessCatalogLoading && harnessCatalogError == nil && harness != nil
            && destination != nil
            && (!prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }

    private var newChatComposer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if harnessCatalogLoading {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("Loading models from the selected machine…")
                }
                .font(.caption2).foregroundStyle(DieterTheme.tertiary)
                .accessibilityIdentifier("chats.new.harness-loading")
            } else if let harnessCatalogError {
                HStack {
                    Label(harnessCatalogError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(DieterTheme.coral)
                        .accessibilityIdentifier("chats.new.harness-error")
                    Button("Retry") { harnessCatalogRetry += 1 }
                        .accessibilityIdentifier("chats.new.harness-retry")
                }.font(.caption2)
            }

            ComposerSurface(focused: promptFocused, dropTargeted: attachmentDropTargeted) {
                destinationControls
                ComposerTextInput(
                    placeholder: "Ask anything, describe a task, or explore an idea…",
                    text: $prompt, focus: $promptFocused
                )
                .accessibilityIdentifier("chats.new.prompt")
                .smokeTarget("chats.new.prompt")
                .onKeyPress(.return, phases: .down) { press in
                    if !ComposerReturnPolicy.sendsMessage(shiftPressed: press.modifiers.contains(.shift)) {
                        return .ignored
                    }
                    if canSubmit { Task { await submit() } }
                    return .handled
                }

                if !attachments.isEmpty {
                    AttachmentPreviewStrip(attachments: $attachments)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 6)
                }

                ComposerToolbar { metrics in
                    ComposerAttachmentButton(
                        identifierPrefix: "chats.new", identity: projectID,
                        onUpload: { fileImporterPresented = true }
                    )
                    newChatProviderMenu(compact: metrics.compact)
                    newChatModelMenu(compact: metrics.compact)
                        .layoutPriority(1)
                    if let efforts = selectedModel?.efforts, !efforts.isEmpty {
                        newChatReasoningMenu(efforts: efforts, compact: metrics.compact)
                    }
                    ComposerProviderOptions(
                        options: ProviderOptionValues.options(for: harness, model: model),
                        values: $providerOptions, identity: projectID, identifierPrefix: "chats.new"
                    )
                    .smokeTarget("chats.new.provider-options")
                    .fixedSize()
                    Spacer(minLength: 0)
                    ComposerSendButton(isEnabled: canSubmit, submitting: submitting) {
                        Task { await submit() }
                    }
                    .accessibilityIdentifier("chats.new.send")
                    .smokeTarget("chats.new.send")
                }
            }
            .smokeTarget("chats.new.composer-shell")
            .attachmentDropTarget(isTargeted: $attachmentDropTargeted) { providers in
                Task {
                    do {
                        attachments = try await store.attachmentParts(providers, appendingTo: attachments)
                    } catch { store.show(error) }
                }
            }
        }
    }

    private var destinationControls: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 12) {
                ComposerSelectionMenu(
                    title: destinationGroup?.machineName ?? "Machine", symbol: "desktopcomputer", help: "Machine",
                    maximumWidth: 136
                ) {
                    ForEach(destinationGroups) { group in
                        Button {
                            selectMachine(group)
                        } label: {
                            Label(
                                group.machineName,
                                systemImage: group.machineID == machineID ? "checkmark" : "desktopcomputer"
                            )
                        }
                        .help(group.title)
                        .accessibilityLabel("\(group.machineName), \(group.machineOnline ? "online" : "offline")")
                    }
                }
                .disabled(destinationGroups.isEmpty)
                .accessibilityIdentifier("chats.new.machine")
                .accessibilityValue(destinationGroup?.title ?? "No machine selected")
                .smokeTarget("chats.new.machine")

                ComposerSelectionMenu(
                    title: destination?.project.name ?? "Project", symbol: "folder", help: "Project",
                    maximumWidth: 180
                ) {
                    ForEach(machineDestinations) { item in
                        Button {
                            selectDestination(item)
                        } label: {
                            Label(
                                projectOptionTitle(item),
                                systemImage: item.checkoutID == checkoutID ? "checkmark" : "folder"
                            )
                        }
                        .help(item.detail)
                        .accessibilityLabel("\(item.project.name), \(item.detail)")
                    }
                }
                .disabled(machineDestinations.isEmpty)
                .accessibilityIdentifier("chats.new.project")
                .accessibilityValue(destination?.project.name ?? "No project selected")
                .smokeTarget("chats.new.project")

                ComposerSelectionMenu(
                    title: workspaceDraft.mode.shortTitle, symbol: "square.stack.3d.up", help: "Workspace",
                    maximumWidth: 92
                ) {
                    ForEach(ConversationWorkspaceMode.allCases) { mode in
                        Button(mode.title) { workspaceDraft.mode = mode }
                    }
                }
                .accessibilityIdentifier("chats.new.workspace")
                .smokeTarget("chats.new.workspace")
                Spacer(minLength: 0)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(DieterTheme.subtle)
            .controlSize(.small)

            if let destination {
                HStack(spacing: 6) {
                    Image(
                        systemName: destination.machineOnline
                            ? "desktopcomputer" : "desktopcomputer.trianglebadge.exclamationmark"
                    )
                    .foregroundStyle(destination.machineOnline ? DieterTheme.eyes : DieterTheme.coral)
                    Text("Runs on \(destination.machineName)")
                        .font(.caption2.weight(.medium)).foregroundStyle(DieterTheme.subtle)
                    Text("· \(destination.detail)")
                        .font(.caption2).foregroundStyle(DieterTheme.tertiary)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .lineLimit(1)
                .accessibilityIdentifier("chats.new.destination")
                .smokeTarget("chats.new.destination")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private func newChatProviderMenu(compact: Bool) -> some View {
        ComposerSelectionMenu(
            title: harness?.name ?? "Agent", symbol: "cpu", help: "Provider", compact: compact, maximumWidth: 100
        ) {
            ForEach(destinationHarnesses, id: \.id) { item in
                Button(item.name) {
                    guard let selection = HarnessSelection(provider: item.id).resolved(in: [item]) else { return }
                    provider = selection.provider
                    model = selection.model
                    effort = selection.effort
                    providerOptions = selection.providerOptions
                }
            }
        }
        .disabled(destinationHarnesses.isEmpty)
        .accessibilityIdentifier("chats.new.provider")
        .smokeTarget("chats.new.provider")
    }

    private func newChatModelMenu(compact: Bool) -> some View {
        let name = selectedModel?.name ?? "Model"
        return ComposerSelectionMenu(
            title: compact ? name.replacingOccurrences(of: "GPT-", with: "") : name,
            symbol: "sparkles", help: "Model"
        ) {
            ForEach(harness?.models ?? [], id: \.id) { item in
                Button(item.name) {
                    model = item.id
                    effort = item.defaultEffort
                    providerOptions = ProviderOptionValues.normalized(
                        for: harness, model: model, saved: providerOptions)
                }
            }
        }
        .accessibilityLabel("Model: \(name)")
        .accessibilityIdentifier("chats.new.model")
        .smokeTarget("chats.new.model")
    }

    private func newChatReasoningMenu(efforts: [String], compact: Bool) -> some View {
        ComposerSelectionMenu(
            title: effort.isEmpty ? "Default" : effort.capitalized,
            symbol: "sparkles", help: "Reasoning", compact: compact, maximumWidth: 80
        ) {
            ForEach(efforts, id: \.self) { value in
                Button(value.capitalized) { effort = value }
            }
        }
        .accessibilityIdentifier("chats.new.reasoning")
        .smokeTarget("chats.new.reasoning")
    }

    private func projectOptionTitle(_ item: ProjectDestination) -> String {
        let duplicates = machineDestinations.filter { $0.project.id == item.project.id }
        guard duplicates.count > 1 else { return item.project.name }
        let checkoutName = item.checkout?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !checkoutName.isEmpty { return "\(item.project.name) · \(checkoutName)" }
        let path = item.checkout?.path ?? ""
        return path.isEmpty ? item.project.name : "\(item.project.name) · \((path as NSString).lastPathComponent)"
    }

    private func chooseDestination(preferredProjectID: String? = nil) {
        let requestedProjectID =
            preferredProjectID
            ?? (!store.newChatProjectID.isEmpty
                ? store.newChatProjectID
                : (!store.selectedProjectID.isEmpty ? store.selectedProjectID : projectID))
        let selected = ProjectDestinationCatalog.preferredDestination(
            preferredMachineID: store.endpoint.id,
            preferredProjectID: requestedProjectID,
            preferredCheckoutID: store.creationCheckoutIDs[requestedProjectID] ?? "",
            in: destinationGroups
        )
        if let selected {
            selectDestination(selected)
        } else {
            machineID = ""
            projectID = ""
            checkoutID = ""
        }
    }

    private func reconcileDestination() {
        guard
            ProjectDestinationCatalog.destination(
                machineID: machineID,
                projectID: projectID,
                checkoutID: checkoutID,
                in: destinationGroups
            ) == nil
        else { return }
        chooseDestination(preferredProjectID: projectID)
    }

    private func selectMachine(_ group: ProjectDestinationGroup) {
        guard
            let selected = ProjectDestinationCatalog.preferredDestination(
                preferredMachineID: group.machineID,
                preferredProjectID: projectID,
                in: destinationGroups
            )
        else { return }
        selectDestination(selected)
    }

    private func selectDestination(_ selected: ProjectDestination) {
        machineID = selected.machineID
        projectID = selected.project.id
        checkoutID = selected.checkoutID
        store.creationCheckoutIDs[selected.project.id] = selected.checkoutID
    }

    private func loadDestinationHarnesses(
        for requestedProjectID: String, checkoutID requestedCheckoutID: String
    ) async {
        guard !Task.isCancelled else { return }
        let requestID = UUID()
        harnessCatalogRequestID = requestID
        guard !requestedProjectID.isEmpty else {
            destinationHarnesses = []
            return
        }
        harnessCatalogLoading = true
        harnessCatalogError = nil
        defer { if harnessCatalogRequestID == requestID { harnessCatalogLoading = false } }
        let catalog: Dieter_V1_HarnessCatalog
        do {
            catalog = try await store.loadHarnessCatalog(forProjectID: requestedProjectID)
        } catch {
            guard !Task.isCancelled, harnessCatalogRequestID == requestID,
                projectID == requestedProjectID, checkoutID == requestedCheckoutID
            else { return }
            destinationHarnesses = []
            harnessCatalogError =
                DieterRPCFailure.isCancellation(error)
                ? "The connection was interrupted while loading models. Try again."
                : DieterRPCFailure.message(for: error)
            return
        }
        guard !Task.isCancelled, harnessCatalogRequestID == requestID,
            projectID == requestedProjectID, checkoutID == requestedCheckoutID
        else { return }
        destinationHarnesses = catalog.harnesses
        let initializing = provider.isEmpty
        let preferences =
            initializing
            ? store.creationPreferences
            : ConversationCreationPreferences(
                provider: provider, model: model, effort: effort, workspaceMode: workspaceDraft.mode)
        guard let selection = preferences.resolved(in: destinationHarnesses),
            let harness = destinationHarnesses.first(where: { $0.id == selection.provider })
        else {
            harnessCatalogError = "This machine did not advertise any usable agent models."
            return
        }
        let previousProvider = provider
        provider = selection.provider
        model = selection.model
        effort = selection.effort
        if initializing { workspaceDraft.mode = selection.workspaceMode }
        providerOptions = ProviderOptionValues.resolved(
            for: harness,
            existing: previousProvider == selection.provider ? providerOptions : [:]
        )
    }

    private func submit() async {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty, !projectID.isEmpty,
            !harnessCatalogLoading, harnessCatalogError == nil, harness != nil
        else { return }
        submitting = true
        store.rememberCreation(
            ConversationCreationPreferences(
                provider: provider,
                model: model,
                effort: effort,
                workspaceMode: workspaceDraft.mode
            ))
        let firstLine =
            text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init)
            ?? attachments.first?.filename ?? "New chat"
        let title = firstLine.count > 72 ? String(firstLine.prefix(69)) + "…" : firstLine
        await store.createConversation(
            title: title, prompt: text, attachments: attachments, chat: true, provider: provider,
            model: model,
            effort: effort, providerOptions: providerOptions, deferred: false, projectID: projectID,
            workspace: workspaceDraft)
        submitting = false
    }
}
