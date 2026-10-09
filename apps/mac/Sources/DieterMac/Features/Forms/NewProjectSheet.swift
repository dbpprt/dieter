import AppKit
import DieterAPI
import SwiftUI
import UniformTypeIdentifiers

struct NewProjectSheet: View {
    @Environment(DieterStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var operationID = UUID().uuidString
    @State private var existingProjectID = ""
    @State private var machineID = ""
    @State private var draft = ProjectSetupDraft()
    @State private var browserPresented = false
    @State private var submitting = false
    @State private var errorMessage = ""
    @State private var suggestedName = ""
    @State private var workspaceSettingsExpanded = false

    private var selectedMachine: MachineEndpoint? {
        store.machines.first { $0.id == machineID }
    }

    private var selectedMachineAvailable: Bool {
        selectedMachine.map(store.machineIsAvailable) == true
    }

    private var canSubmit: Bool {
        existingProjectID.isEmpty
            ? draft.canSubmit : !draft.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .bold))
                }
                .buttonStyle(DieterBarButtonStyle(shape: .circle, size: 28)).help("Close").disabled(submitting)
            }
            .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 15)

            ScrollView {
                VStack(alignment: .leading, spacing: 17) {
                    if existingProjectID.isEmpty {
                        DieterSegmentedPicker(
                            "Project type", selection: $draft.mode, options: ProjectSetupMode.allCases,
                            fillsWidth: true, optionTitle: { $0.title }
                        )
                        .accessibilityIdentifier("new-project.mode")
                    }

                    Picker("Project", selection: $existingProjectID) {
                        Text("Create a new project").tag("")
                        ForEach(store.projects, id: \.id) { project in Text("Attach to \(project.name)").tag(project.id)
                        }
                    }
                    projectLabel("Checkout machine")
                    Menu {
                        ForEach(store.machines) { machine in
                            Button {
                                if store.machineIsAvailable(machine) { machineID = machine.id }
                            } label: {
                                if machine.id == machineID {
                                    Label(machine.name, systemImage: "checkmark")
                                } else if let reason = store.unavailableReason(machine) {
                                    Text("\(machine.name) · \(reason)")
                                } else {
                                    Text(machine.name)
                                }
                            }
                            .disabled(!store.machineIsAvailable(machine))
                        }
                    } label: {
                        HStack(spacing: 9) {
                            Circle().fill(selectedMachineAvailable ? DieterTheme.eyes : DieterTheme.tertiary)
                                .frame(width: 7, height: 7)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(selectedMachine?.name ?? "Choose a machine").font(
                                    .system(size: 13, weight: .semibold))
                                Text(
                                    selectedMachineAvailable
                                        ? "Online · repository and agents run here"
                                        : selectedMachine.flatMap(store.unavailableReason) ?? "Offline"
                                )
                                .font(.caption2).foregroundStyle(DieterTheme.tertiary)
                            }
                            Spacer()
                            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(
                                DieterTheme.tertiary)
                        }
                        .foregroundStyle(DieterTheme.subtle).padding(.horizontal, 13).frame(height: 48)
                        .contentShape(RoundedRectangle(cornerRadius: 9))
                        .dieterInset(radius: 9)
                    }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                    Text(
                        "The repository path and every agent process belong to this host. This placement choice does not filter the combined workspace."
                    )
                    .font(.caption2).foregroundStyle(DieterTheme.tertiary)

                    projectLabel(draft.mode.pathLabel)
                    HStack {
                        projectTextField("/path/on/\(selectedMachine?.name ?? "machine")/repository", text: $draft.path)
                            .accessibilityIdentifier("new-project.path")
                        Button {
                            browserPresented = true
                        } label: {
                            Label("Browse…", systemImage: "folder")
                        }
                        .buttonStyle(DieterBarButtonStyle(size: 30))
                        .accessibilityIdentifier("new-project.browse")
                        .smokeTarget("new-project.browse")
                        .disabled(submitting || machineID.isEmpty || !selectedMachineAvailable)
                    }
                    Text(pathHelp)
                        .font(.caption2).foregroundStyle(DieterTheme.tertiary)

                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 7) {
                            projectLabel(existingProjectID.isEmpty ? "Project name" : "Checkout name")
                            projectTextField("Directory name by default", text: $draft.name)
                                .accessibilityIdentifier("new-project.name")
                            Text("Optional; the directory name is used by default.")
                                .font(.caption2).foregroundStyle(DieterTheme.tertiary)
                        }
                        if existingProjectID.isEmpty {
                            VStack(alignment: .leading, spacing: 7) {
                                projectLabel("Summary")
                                projectTextField("What is this repository?", text: $draft.summary)
                                    .accessibilityIdentifier("new-project.summary")
                            }
                        }
                    }

                    if existingProjectID.isEmpty {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 7) {
                                projectLabel("First board")
                                projectTextField("Main", text: $draft.boardName)
                                    .accessibilityIdentifier("new-project.board-name")
                            }
                            VStack(alignment: .leading, spacing: 7) {
                                projectLabel("Workflow")
                                Menu {
                                    ForEach(AdminChoices.options.workflows, id: \.id) { option in
                                        Button(option.title) { draft.workflow = option.id }
                                    }
                                } label: {
                                    HStack {
                                        Text(
                                            AdminChoices.choice(draft.workflow, in: AdminChoices.options.workflows)?
                                                .title ?? draft.workflow)
                                        Spacer()
                                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                                            .foregroundStyle(DieterTheme.tertiary)
                                    }
                                    .font(.system(size: 13, weight: .medium)).foregroundStyle(DieterTheme.subtle)
                                    .padding(.horizontal, 12).frame(height: 40)
                                    .contentShape(RoundedRectangle(cornerRadius: 8))
                                    .dieterInset(radius: 8)
                                }
                                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                                .accessibilityIdentifier("new-project.workflow")
                            }
                        }
                        Text(AdminChoices.choice(draft.workflow, in: AdminChoices.options.workflows)?.lanes ?? "")
                            .font(.caption2).foregroundStyle(DieterTheme.tertiary)

                        DisclosureGroup(isExpanded: $workspaceSettingsExpanded) {
                            VStack(alignment: .leading, spacing: 11) {
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 7) {
                                        projectLabel("Workspace base")
                                        Text("Configured independently on every chat and card.")
                                            .font(.caption2).foregroundStyle(DieterTheme.tertiary)
                                    }
                                }
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 7) {
                                        projectLabel("Base remote")
                                        projectTextField("origin", text: $draft.baseRemote)
                                    }
                                    VStack(alignment: .leading, spacing: 7) {
                                        projectLabel("Base branch")
                                        projectTextField("main", text: $draft.baseBranch)
                                    }
                                }
                                Text(
                                    "Each chat and card chooses its own workspace mode. Git operations run on the selected checkout’s machine."
                                )
                                .font(.caption2).foregroundStyle(DieterTheme.tertiary)
                            }
                            .padding(.top, 10)
                        } label: {
                            Label("Agent workspaces", systemImage: "square.stack.3d.up")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .accessibilityIdentifier("new-project.workspace-settings")

                        projectLabel("Project instructions")
                        TextField("How should agents work in this project?", text: $draft.prompt, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13)).lineSpacing(3).lineLimit(1...5)
                            .padding(.horizontal, 12).padding(.vertical, 13)
                            .frame(height: 105)
                            .dieterInset(radius: 9)
                            .accessibilityIdentifier("new-project.instructions")
                        Text("Stored centrally and included in every new card conversation for this project.")
                            .font(.caption2).foregroundStyle(DieterTheme.tertiary)
                    }

                    if !errorMessage.isEmpty {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                            Text(errorMessage).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .font(.caption).foregroundStyle(DieterTheme.coral)
                        .padding(11)
                        .background(DieterTheme.coral.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityIdentifier("new-project.error")
                    }
                }
                .padding(.horizontal, 24).padding(.bottom, 18)
                .disabled(submitting)
            }

            Divider().overlay(DieterTheme.border)
            HStack(spacing: 10) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(DieterBarButtonStyle(size: 30))
                    .disabled(submitting)
                Button {
                    submit()
                } label: {
                    if submitting {
                        HStack(spacing: 7) {
                            ProgressView().controlSize(.small)
                            Text(
                                !existingProjectID.isEmpty
                                    ? "Attaching…" : draft.mode == .existing ? "Adding…" : "Creating…")
                        }
                    } else {
                        Label(
                            existingProjectID.isEmpty ? draft.mode.submitTitle : "Attach checkout", systemImage: "plus")
                    }
                }
                .buttonStyle(DieterBarButtonStyle(prominent: true, size: 30))
                .disabled(submitting || !canSubmit || !selectedMachineAvailable)
                .accessibilityIdentifier("new-project.submit")
            }
            .padding(.horizontal, 24).padding(.vertical, 14)
        }
        .frame(width: 680, height: 820)
        .background(DieterTheme.background)
        .task {
            if machineID.isEmpty {
                // This Mac's machine, else the first that can take work.
                machineID =
                    store.localMachine.flatMap { store.machineIsAvailable($0) ? $0.id : nil }
                    ?? store.machines.first(where: store.machineIsAvailable)?.id ?? ""
            }
        }
        .onChange(of: existingProjectID) { _, value in
            if !value.isEmpty { draft.mode = .existing }
            errorMessage = ""
        }
        .onChange(of: machineID) { _, _ in
            draft.path = ""
            suggestedName = ""
            errorMessage = ""
        }
        .onChange(of: draft.mode) { _, _ in
            draft.path = ""
            suggestedName = ""
            errorMessage = ""
        }
        .onChange(of: draft.path) { _, newValue in
            let update = RemoteProjectPath.updatingSuggestedName(
                currentName: draft.name,
                previousSuggestion: suggestedName,
                path: newValue
            )
            draft.name = update.name
            suggestedName = update.suggestion
            errorMessage = ""
        }
        .sheet(isPresented: $browserPresented) {
            RemoteDirectoryBrowserSheet(machineID: machineID, mode: draft.mode, selection: $draft.path)
                .environment(store)
        }
    }

    private var pathHelp: String {
        switch draft.mode {
        case .existing:
            "Choose a repository root or linked Git worktree on the selected host. The host validates the .git directory or file."
        case .newRepository:
            "Enter a new directory path or browse for its parent. The selected host creates the folder and runs git init."
        }
    }

    private func submit() {
        guard !submitting, canSubmit else { return }
        submitting = true
        errorMessage = ""
        Task {
            do {
                if existingProjectID.isEmpty {
                    _ = try await store.createProject(draft, machineID: machineID, operationID: operationID)
                } else {
                    guard
                        await store.attachCheckout(
                            projectID: existingProjectID, path: draft.path, name: draft.name, machineID: machineID)
                    else {
                        submitting = false; errorMessage = store.errorMessage ?? "Could not attach checkout"; return
                    }
                }
                submitting = false
                dismiss()
            } catch {
                submitting = false
                errorMessage = ((error as? CoreFailure)?.message ?? error.localizedDescription)
            }
        }
    }

    private func projectLabel(_ value: String) -> some View {
        Text(value).font(.system(size: 12, weight: .semibold)).foregroundStyle(DieterTheme.subtle)
    }

    private func projectTextField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain).font(.system(size: 13))
            .padding(.horizontal, 12).frame(height: 40)
            .dieterInset(radius: 8)
    }
}
