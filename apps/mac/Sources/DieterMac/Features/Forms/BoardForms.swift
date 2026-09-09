import AppKit
import DieterAPI
import SwiftUI
import UniformTypeIdentifiers

struct NewBoardSheet: View {
    @Environment(DieterStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var description = ""
    @State private var workflow = BoardWorkflow.review.rawValue
    @State private var doneArchivePolicy = DoneArchivePolicy.never.rawValue
    @State private var baseRemote = ""
    @State private var remotePublishMode = RemotePublishMode.manual.rawValue

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
            TextField("Default Git remote", text: $baseRemote)
            Picker("Remote publishing", selection: $remotePublishMode) {
                ForEach(RemotePublishMode.allCases) { mode in Text(mode.title).tag(mode.rawValue) }
            }
            Text(RemotePublishMode(rawValue: remotePublishMode)?.detail ?? "")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create") {
                    Task {
                        await store.createBoard(
                            name: name, workflow: workflow, description: description,
                            doneArchivePolicy: doneArchivePolicy, baseRemote: baseRemote,
                            remotePublishMode: remotePublishMode)
                    }
                }.buttonStyle(.borderedProminent).disabled(
                    name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 540)
            .onAppear { baseRemote = store.selectedProject?.baseRemote ?? "" }
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

struct RenameProjectSheet: View {
    @Environment(DieterStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    private var normalizedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Rename project").font(.title2.weight(.bold))
            if let project = store.renameProjectTarget {
                Text(
                    "Choose a new display name for \(project.name). The Git working tree and Dieter history stay unchanged."
                )
                .foregroundStyle(.secondary)
                TextField("Project name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { rename(project.id) }
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }
                    Button("Rename") { rename(project.id) }
                        .buttonStyle(.borderedProminent)
                        .disabled(normalizedName.isEmpty || normalizedName == project.name)
                }
            } else {
                ContentUnavailableView("Project unavailable", systemImage: "folder.badge.questionmark")
            }
        }
        .padding(24).frame(width: 480)
        .onAppear { name = store.renameProjectTarget?.name ?? "" }
    }

    private func rename(_ projectID: String) {
        guard !normalizedName.isEmpty else { return }
        Task { await store.renameProject(id: projectID, name: normalizedName) }
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
