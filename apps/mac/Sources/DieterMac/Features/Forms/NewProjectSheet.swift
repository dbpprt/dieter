import AppKit
import DieterAPI
import SwiftUI
import UniformTypeIdentifiers

struct NewProjectSheet: View {
    @Environment(DieterStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var machineID = ""
    @State private var draft = ProjectSetupDraft()
    @State private var browserPresented = false
    @State private var submitting = false
    @State private var errorMessage = ""
    @State private var suggestedName = ""
    @State private var workspaceSettingsExpanded = false

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
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .bold))
                }
                .buttonStyle(DieterIconButtonStyle()).help("Close").disabled(submitting)
            }
            .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 15)

            ScrollView {
                VStack(alignment: .leading, spacing: 17) {
                    Picker("Project type", selection: $draft.mode) {
                        ForEach(ProjectSetupMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityIdentifier("new-project.mode")

                    projectLabel("Project host")
                    Menu {
                        ForEach(availableMachines) { machine in
                            Button {
                                if machine.online { machineID = machine.id }
                            } label: {
                                if machine.id == machineID {
                                    Label(machine.name, systemImage: "checkmark")
                                } else {
                                    Text(machine.online ? machine.name : "\(machine.name) · Offline")
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 9) {
                            Circle().fill(selectedMachine?.online == true ? DieterTheme.eyes : DieterTheme.tertiary)
                                .frame(width: 7, height: 7)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(selectedMachine?.name ?? "Choose a project host").font(
                                    .system(size: 13, weight: .semibold))
                                Text(
                                    selectedMachine?.online == true
                                        ? "Online · repository and agents run here" : "Offline"
                                )
                                .font(.caption2).foregroundStyle(DieterTheme.tertiary)
                            }
                            Spacer()
                            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(
                                DieterTheme.tertiary)
                        }
                        .foregroundStyle(DieterTheme.subtle).padding(.horizontal, 13).frame(height: 48)
                        .background(DieterTheme.input, in: RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(DieterTheme.strongBorder))
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden)
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
                        .buttonStyle(DieterSecondaryButtonStyle())
                        .accessibilityIdentifier("new-project.browse")
                        .smokeTarget("new-project.browse")
                        .disabled(submitting || machineID.isEmpty || selectedMachine?.online != true)
                    }
                    Text(pathHelp)
                        .font(.caption2).foregroundStyle(DieterTheme.tertiary)

                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 7) {
                            projectLabel("Project name")
                            projectTextField("Directory name by default", text: $draft.name)
                                .accessibilityIdentifier("new-project.name")
                            Text("Optional; the directory name is used by default.")
                                .font(.caption2).foregroundStyle(DieterTheme.tertiary)
                        }
                        VStack(alignment: .leading, spacing: 7) {
                            projectLabel("Summary")
                            projectTextField("What is this repository?", text: $draft.summary)
                                .accessibilityIdentifier("new-project.summary")
                        }
                    }

                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 7) {
                            projectLabel("First board")
                            projectTextField("Main", text: $draft.boardName)
                                .accessibilityIdentifier("new-project.board-name")
                        }
                        VStack(alignment: .leading, spacing: 7) {
                            projectLabel("Workflow")
                            Menu {
                                ForEach(BoardWorkflow.allCases) { option in
                                    Button(option.title) { draft.workflow = option.rawValue }
                                }
                            } label: {
                                HStack {
                                    Text(BoardWorkflow(rawValue: draft.workflow)?.title ?? "With review")
                                    Spacer()
                                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(DieterTheme.tertiary)
                                }
                                .font(.system(size: 13, weight: .medium)).foregroundStyle(DieterTheme.subtle)
                                .padding(.horizontal, 12).frame(height: 40)
                                .background(DieterTheme.input, in: RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(DieterTheme.strongBorder))
                            }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden)
                            .accessibilityIdentifier("new-project.workflow")
                        }
                    }
                    Text(BoardWorkflow(rawValue: draft.workflow)?.laneDescription ?? "")
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
                                "Each chat and card chooses its own workspace mode. Git operations run on the selected project host."
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
                        .background(DieterTheme.input, in: RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(DieterTheme.strongBorder))
                        .accessibilityIdentifier("new-project.instructions")
                    Text("Stored centrally and included in every new card conversation for this project.")
                        .font(.caption2).foregroundStyle(DieterTheme.tertiary)

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
                    .buttonStyle(DieterSecondaryButtonStyle())
                    .disabled(submitting)
                Button {
                    submit()
                } label: {
                    if submitting {
                        HStack(spacing: 7) {
                            ProgressView().controlSize(.small)
                            Text(draft.mode == .existing ? "Adding…" : "Creating…")
                        }
                    } else {
                        Label(draft.mode.submitTitle, systemImage: "plus")
                    }
                }
                .buttonStyle(DieterPrimaryButtonStyle())
                .disabled(submitting || !draft.canSubmit || selectedMachine?.online != true)
                .accessibilityIdentifier("new-project.submit")
            }
            .padding(.horizontal, 24).padding(.vertical, 14)
        }
        .frame(width: 680, height: 820)
        .background(DieterTheme.background)
        .task {
            if machineID.isEmpty {
                machineID =
                    availableMachines.first(where: { $0.id == store.endpoint.id })?.id ?? availableMachines.first(
                        where: \.online)?.id ?? ""
            }
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
        guard !submitting, draft.canSubmit else { return }
        submitting = true
        errorMessage = ""
        Task {
            do {
                _ = try await store.createProject(draft, machineID: machineID)
                submitting = false
                dismiss()
            } catch {
                submitting = false
                errorMessage = DieterRPCFailure.message(for: error)
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
            .background(DieterTheme.input, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(DieterTheme.strongBorder))
    }
}
