import DieterAPI
import SwiftUI

/// Local, uncommitted state for the registered project checkout. This surface
/// is intentionally project-scoped: shared-directory conversations link here
/// instead of pretending that the checkout belongs to one card.
struct ProjectChangesView: View {
    @Environment(DieterStore.self) private var store
    @State private var changes: Dieter_V1_Changeset?
    @State private var diff: Dieter_V1_FileDiff?
    @State private var operation: Dieter_V1_GitOperation?
    @State private var selectedPath = ""
    @State private var selectedSection = ""
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var discardPath: String?
    @State private var commitPresented = false
    @State private var commitSubject = ""
    @State private var commitBody = ""

    private var stagedFiles: [Dieter_V1_ChangedFile] { changes?.files.filter(\.staged) ?? [] }
    private var unstagedFiles: [Dieter_V1_ChangedFile] { changes?.files.filter(\.unstaged) ?? [] }
    private var operationActive: Bool { GitOperationStatus.active(operation?.status ?? "") }
    private var mutationsDisabled: Bool { operationActive || (changes?.volatile ?? false) }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(DieterTheme.paneSeparator)
            if let operation, operationActive || operation.status == "failed" {
                operationBanner(operation)
                Divider().overlay(DieterTheme.border)
            }
            if loading && changes == nil {
                ProgressView("Reading project changes…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage, changes == nil {
                ContentUnavailableView("Changes unavailable", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let changes {
                HSplitView {
                    changeList(changes)
                        .frame(minWidth: 280, idealWidth: 350, maxWidth: 460)
                    diffPane
                }
            } else {
                ContentUnavailableView("No changes loaded", systemImage: "doc.text.magnifyingglass")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(DieterTheme.background)
        .task(id: store.selectedProjectID) { await loadChanges() }
        .confirmationDialog(
            "Discard local changes?",
            isPresented: Binding(get: { discardPath != nil }, set: { if !$0 { discardPath = nil } }),
            presenting: discardPath
        ) { path in
            Button("Discard \(path)", role: .destructive) {
                discardPath = nil
                Task { await perform(kind: "discard_changes", path: path) }
            }
            Button("Cancel", role: .cancel) { discardPath = nil }
        } message: { path in
            Text("Dieter creates recovery artifacts first, then restores this path to HEAD. Untracked files are removed.")
        }
        .sheet(isPresented: $commitPresented) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Commit staged changes").font(.title2.weight(.bold))
                Text("Only the staged index in the project checkout will be committed on \(changes?.branch ?? "the current branch").")
                    .font(.callout).foregroundStyle(DieterTheme.tertiary)
                TextField("Commit subject", text: $commitSubject)
                TextField("Optional body", text: $commitBody, axis: .vertical).lineLimit(3...8)
                HStack {
                    Spacer()
                    Button("Cancel") { commitPresented = false }
                    Button("Commit") {
                        let subject = commitSubject.trimmingCharacters(in: .whitespacesAndNewlines)
                        commitPresented = false
                        Task { await perform(kind: "commit", parameters: ["subject": subject, "body": commitBody, "validate": "false"]) }
                    }
                    .buttonStyle(DieterPrimaryButtonStyle())
                    .disabled(commitSubject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(22).frame(width: 480)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 9) {
            PaneTitleBlock(
                title: "Project Changes",
                subtitle: changes.map { "\($0.files.count) local file\($0.files.count == 1 ? "" : "s") · \($0.branch.isEmpty ? "current branch" : $0.branch)" } ?? "Registered project checkout",
                symbol: "arrow.triangle.branch",
                prominent: true
            )
            Spacer()
            if !unstagedFiles.isEmpty {
                Button("Stage all") { Task { await perform(kind: "stage") } }
                    .buttonStyle(DieterSecondaryButtonStyle()).disabled(mutationsDisabled)
                    .accessibilityIdentifier("project-changes.stage-all")
            }
            if !stagedFiles.isEmpty {
                Button("Unstage all") { Task { await perform(kind: "unstage") } }
                    .buttonStyle(DieterSecondaryButtonStyle()).disabled(mutationsDisabled)
                    .accessibilityIdentifier("project-changes.unstage-all")
                Button("Commit…") { commitPresented = true }
                    .buttonStyle(DieterPrimaryButtonStyle()).disabled(mutationsDisabled)
                    .accessibilityIdentifier("project-changes.commit")
            }
            Button { Task { await loadChanges() } } label: {
                if loading { ProgressView().controlSize(.mini) } else { Image(systemName: "arrow.clockwise") }
            }
            .buttonStyle(DieterIconButtonStyle()).disabled(loading).help("Refresh project changes")
        }
        .padding(.horizontal, 14).frame(height: 54).background(DieterTheme.sidebar)
    }

    private func changeList(_ value: Dieter_V1_Changeset) -> some View {
        List {
            if value.volatile {
                Section {
                    Label("A project-directory conversation is active. Changes can be inspected, but mutations wait until it finishes.", systemImage: "person.crop.circle.badge.clock")
                        .font(DieterFont.meta).foregroundStyle(DieterTheme.amber)
                }
            }
            Section("Staged · \(stagedFiles.count)") {
                if stagedFiles.isEmpty { Text("Nothing staged").foregroundStyle(DieterTheme.tertiary) }
                ForEach(stagedFiles, id: \.path) { file in
                    changeRow(file, section: "staged")
                }
            }
            Section("Changes · \(unstagedFiles.count)") {
                if unstagedFiles.isEmpty {
                    Text(stagedFiles.isEmpty ? "Working tree is clean" : "No unstaged changes")
                        .foregroundStyle(DieterTheme.tertiary)
                }
                ForEach(unstagedFiles, id: \.path) { file in
                    changeRow(file, section: "unstaged")
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(DieterTheme.sidebar)
    }

    private func changeRow(_ file: Dieter_V1_ChangedFile, section: String) -> some View {
        let selected = selectedPath == file.path && selectedSection == section
        let additions = section == "staged" ? file.stagedAdditions : file.unstagedAdditions
        let deletions = section == "staged" ? file.stagedDeletions : file.unstagedDeletions
        return HStack(spacing: 8) {
            Button {
                Task { await loadDiff(path: file.path, section: section) }
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(file.path).font(.system(size: 11, weight: selected ? .semibold : .regular, design: .monospaced)).lineLimit(1)
                    HStack(spacing: 6) {
                        Text(section == "staged" ? (file.indexStatus.isEmpty ? file.status : file.indexStatus) : (file.worktreeStatus.isEmpty ? file.status : file.worktreeStatus))
                        Text("+\(additions)").foregroundStyle(DieterTheme.eyes)
                        Text("−\(deletions)").foregroundStyle(DieterTheme.coral)
                    }
                    .font(.system(size: 9, weight: .medium))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button(section == "staged" ? "Unstage" : "Stage") {
                Task { await perform(kind: section == "staged" ? "unstage" : "stage", path: file.path) }
            }
            .buttonStyle(.borderless).font(.caption).disabled(mutationsDisabled)
            Button(role: .destructive) { discardPath = file.path } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).disabled(mutationsDisabled).help("Discard changes to \(file.path)")
        }
        .padding(.vertical, 3)
        .listRowBackground(selected ? DieterTheme.selection : Color.clear)
        .accessibilityIdentifier("project-changes.\(section).\(file.path)")
    }

    private var diffPane: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "doc.text")
                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedPath.isEmpty ? "Diff" : selectedPath).font(.system(size: 11, weight: .semibold, design: .monospaced)).lineLimit(1)
                    if !selectedSection.isEmpty { Text(selectedSection.capitalized).font(DieterFont.meta).foregroundStyle(DieterTheme.tertiary) }
                }
                Spacer()
            }
            .padding(.horizontal, 12).frame(height: 46).background(DieterTheme.sidebar)
            Divider().overlay(DieterTheme.border)
            if let diff {
                if diff.binary {
                    ContentUnavailableView("Binary diff", systemImage: "doc.badge.ellipsis")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView([.horizontal, .vertical]) {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(UnifiedDiffParser.parse(diff.patch)) { line in
                                Text(line.text.isEmpty ? " " : line.text)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(diffColor(line.kind))
                                    .padding(.horizontal, 10).frame(minHeight: 19, alignment: .leading)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else {
                ContentUnavailableView("Select a change", systemImage: "doc.text.magnifyingglass", description: Text("A file can appear once in Staged and once in Changes when both index and working-tree edits exist."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func operationBanner(_ value: Dieter_V1_GitOperation) -> some View {
        HStack(spacing: 8) {
            if operationActive { ProgressView().controlSize(.small) }
            Image(systemName: value.status == "failed" ? "exclamationmark.triangle.fill" : "gearshape.2")
            Text(value.status == "failed" ? value.error : "\(value.kind.replacingOccurrences(of: "_", with: " ").capitalized)…")
                .font(.system(size: 11, weight: .medium)).lineLimit(2)
            Spacer()
        }
        .foregroundStyle(value.status == "failed" ? DieterTheme.coral : DieterTheme.subtle)
        .padding(.horizontal, 14).frame(minHeight: 38).background(DieterTheme.raised)
    }

    private func diffColor(_ kind: UnifiedDiffLine.Kind) -> Color {
        switch kind {
        case .addition: DieterTheme.eyes
        case .deletion: DieterTheme.coral
        case .hunk: DieterTheme.shell
        case .header: DieterTheme.tertiary
        case .context: DieterTheme.text
        }
    }

    @MainActor
    private func loadChanges() async {
        guard let rpc = store.rpc, !store.selectedProjectID.isEmpty else { return }
        let projectID = store.selectedProjectID
        loading = true
        errorMessage = nil
        do {
            let value = try await rpc.changeset(projectID: projectID)
            guard store.selectedProjectID == projectID else { return }
            changes = value
            let currentStillExists = value.files.contains { file in
                file.path == selectedPath && ((selectedSection == "staged" && file.staged) || (selectedSection == "unstaged" && file.unstaged))
            }
            if !currentStillExists {
                if let file = value.files.first(where: \.staged) {
                    selectedPath = file.path; selectedSection = "staged"
                } else if let file = value.files.first(where: \.unstaged) {
                    selectedPath = file.path; selectedSection = "unstaged"
                } else {
                    selectedPath = ""; selectedSection = ""; diff = nil
                }
            }
            if !selectedPath.isEmpty { await loadDiff(path: selectedPath, section: selectedSection) }
            if !value.currentOperationID.isEmpty {
                operation = try? await rpc.gitOperation(id: value.currentOperationID)
                if let operation, GitOperationStatus.active(operation.status) {
                    await monitorOperation(id: operation.id)
                }
            }
        } catch {
            errorMessage = DieterRPCFailure.message(for: error)
        }
        loading = false
    }

    @MainActor
    private func loadDiff(path: String, section: String) async {
        guard let rpc = store.rpc, let changes, !path.isEmpty else { return }
        selectedPath = path
        selectedSection = section
        var request = Dieter_V1_GetDiffRequest()
        request.projectID = store.selectedProjectID
        request.path = path
        request.section = section
        request.expectedRevision = changes.revision
        request.limit = 1_048_576
        do {
            diff = try await rpc.fileDiff(request)
        } catch {
            errorMessage = DieterRPCFailure.message(for: error)
        }
    }

    @MainActor
    private func perform(kind: String, path: String = "", parameters: [String: String] = [:]) async {
        guard let rpc = store.rpc, let changes, !mutationsDisabled else { return }
        var request = Dieter_V1_StartGitOperationRequest()
        request.projectID = store.selectedProjectID
        request.kind = kind
        request.expectedRevision = changes.revision
        request.parameters = parameters
        if !path.isEmpty { request.parameters["path"] = path }
        do {
            operation = try await rpc.startGitOperation(request)
            guard let operation else { return }
            await monitorOperation(id: operation.id)
        } catch {
            errorMessage = DieterRPCFailure.message(for: error)
            await loadChanges()
        }
    }

    @MainActor
    private func monitorOperation(id: String) async {
        guard let rpc = store.rpc else { return }
        while !Task.isCancelled {
            do {
                let value = try await rpc.gitOperation(id: id)
                operation = value
                if !GitOperationStatus.active(value.status) {
                    if value.status != "succeeded" { errorMessage = value.error }
                    await loadChanges()
                    return
                }
            } catch {
                errorMessage = DieterRPCFailure.message(for: error)
                return
            }
            try? await DieterTaskSleep.milliseconds(300)
        }
    }
}
