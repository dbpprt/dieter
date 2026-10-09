import AppKit
import DieterAPI
import SwiftUI
import UniformTypeIdentifiers

struct StandaloneChatStartView: View {
    @Environment(DieterStore.self) private var store
    @State private var form = CreationFormModel(chat: true)
    @State private var machineID = ""
    @State private var projectID = ""
    @State private var checkoutID = ""
    @State private var submitting = false
    @State private var fileImporterPresented = false
    @State private var attachmentDropTargeted = false
    @FocusState private var promptFocused: Bool
    @State private var workspaceMode: ConversationWorkspaceMode?

    /// What a preview depends on: the choices and how many files are attached.
    private struct PreviewKey: Equatable {
        let intent: ClientCreationIntent
        let attachments: Int
        let connected: Bool
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
    private var preview: ClientCreationPreview { form.preview }
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("New chat").font(.system(size: 15, weight: .semibold)).foregroundStyle(DieterTheme.text)
                        .lineLimit(1)
                    StatusPill(text: "New")
                    Spacer(minLength: 0)
                }
                .frame(height: 44)
                Text(
                    destination.map { "\($0.project.name) on \($0.machineName) · Standalone chat" }
                        ?? "Choose a machine and project · Standalone chat"
                )
                .font(.system(size: 11.5)).foregroundStyle(DieterTheme.tertiary)
                .lineLimit(1).truncationMode(.middle)
                HStack(spacing: 7) {
                    Image(systemName: "info.circle").foregroundStyle(DieterTheme.shell)
                    Text("Standalone chats stay in their project folder and never become board cards.")
                    Spacer(minLength: 0)
                }
                .font(.caption2).foregroundStyle(DieterTheme.tertiary)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)

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
                        StandaloneChatSuggestionTile(title: suggestion.0) { form.intent.prompt = suggestion.1 }
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
            attachments: $form.attachments
        )
        .onAppear {
            form.attach(store.core)
            chooseDestination()
        }
        .onChange(of: store.newChatProjectID) { _, value in
            if !value.isEmpty { chooseDestination(preferredProjectID: value) }
        }
        .onChange(of: destinationGroups) { _, _ in reconcileDestination() }
        .onChange(of: workspaceMode) { _, mode in form.intent.workspaceMode = mode?.rawValue ?? "" }
        .task(
            id: PreviewKey(
                intent: form.intent, attachments: form.attachments.count, connected: store.phase.isConnected)
        ) {
            form.attach(store.core)
            await form.refresh()
        }
    }

    private var canSubmit: Bool {
        !submitting && destination != nil && form.previewed && preview.problem.isEmpty
    }

    private var newChatComposer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if destination != nil, preview.catalog == .none {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text(preview.destinationStatus.isEmpty ? "Loading agent models…" : preview.destinationStatus)
                }
                .font(.caption2).foregroundStyle(DieterTheme.tertiary)
                .accessibilityIdentifier("chats.new.harness-loading")
            } else if destination != nil, preview.catalog != .live {
                Label(preview.destinationStatus, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(DieterTheme.coral)
                    .font(.caption2)
                    .accessibilityIdentifier("chats.new.harness-error")
            }

            ComposerSurface(focused: promptFocused, dropTargeted: attachmentDropTargeted) {
                destinationControls
                ComposerTextInput(
                    placeholder: "Ask anything, describe a task, or explore an idea…",
                    text: $form.intent.prompt, focus: $promptFocused
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

                if !form.attachments.isEmpty {
                    AttachmentPreviewStrip(attachments: $form.attachments)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 6)
                }

                ComposerToolbar { metrics in
                    ComposerAttachmentButton(
                        identifierPrefix: "chats.new", identity: projectID,
                        onUpload: { fileImporterPresented = true }
                    )
                    AgentComposerMenus(
                        controls: preview.agent, compact: metrics.compact, identifierPrefix: "chats.new",
                        identity: projectID
                    ) { choice in Task { await form.refresh(choice: choice) } }
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
                        form.attachments = try await store.attachmentParts(
                            providers, appendingTo: form.attachments)
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
                            selectDestination(item, picked: true)
                        } label: {
                            Label(
                                item.optionTitle,
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
                    title: form.workspaceMode.shortTitle, symbol: "square.stack.3d.up", help: "Workspace",
                    maximumWidth: 92
                ) {
                    ForEach(ConversationWorkspaceMode.allCases) { mode in
                        Button(mode.title) { workspaceMode = mode }
                    }
                }
                .help(preview.workspaceDetail)
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

    private func chooseDestination(preferredProjectID: String? = nil) {
        let requestedProjectID =
            preferredProjectID
            ?? (!store.newChatProjectID.isEmpty
                ? store.newChatProjectID
                : (!store.selectedProjectID.isEmpty ? store.selectedProjectID : projectID))
        let selected = ProjectDestinationCatalog.preferredDestination(
            preferredMachineID: store.localMachine?.id ?? "",
            preferredProjectID: requestedProjectID,
            preferredCheckoutID: store.checkout(forProjectID: requestedProjectID)?.id ?? "",
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
        selectDestination(selected, picked: true)
    }

    /// Shows `selected`; a destination the user picked is remembered for new conversations.
    private func selectDestination(_ selected: ProjectDestination, picked: Bool = false) {
        machineID = selected.machineID
        projectID = selected.project.id
        checkoutID = selected.checkoutID
        form.intent.projectID = selected.project.id
        form.intent.checkoutID = selected.checkoutID
        if picked, let checkout = selected.checkout { store.pickCheckout(checkout) }
    }

    private func submit() async {
        guard canSubmit else { return }
        submitting = true
        if await form.create(using: store) {
            form.intent.prompt = ""
            form.attachments = []
        }
        submitting = false
    }
}

private struct StandaloneChatSuggestionTile: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: "sparkles").font(.system(size: 10)).foregroundStyle(DieterTheme.shell)
                Text(title).font(.system(size: 12, weight: .medium))
                Spacer()
            }
            .padding(.horizontal, 13).frame(height: 46)
            .dieterTile(DieterTileState(selected: false, hovering: hovering))
            .contentShape(RoundedRectangle(cornerRadius: DieterMetrics.cardRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
