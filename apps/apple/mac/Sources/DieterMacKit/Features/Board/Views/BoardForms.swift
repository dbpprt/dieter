import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct NewBoardSheet: View {
    @Environment(DieterStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var description = ""
    @State private var workflow = AdminChoices.options.defaultWorkflow
    @State private var doneArchivePolicy = AdminChoices.options.defaultArchivePolicy
    @State private var baseRemote = ""
    @State private var remotePublishMode = AdminChoices.options.defaultPublishMode

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Create board").font(.title2.weight(.bold))
            if let project = store.selectedProject {
                Text(project.name).font(.caption.weight(.semibold)).foregroundStyle(DieterTheme.shell)
            }
            TextField("Board name", text: $name)
            TextField("Description", text: $description)
            LabeledContent("Workflow") {
                DieterSegmentedPicker(
                    "Workflow", selection: $workflow, options: AdminChoices.options.workflows.map(\.id),
                    optionTitle: { AdminChoices.choice($0, in: AdminChoices.options.workflows)?.title ?? $0 })
            }
            Text(AdminChoices.choice(workflow, in: AdminChoices.options.workflows)?.lanes ?? "")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Archive Done conversations", selection: $doneArchivePolicy) {
                ForEach(AdminChoices.options.archivePolicies, id: \.id) { option in Text(option.title).tag(option.id) }
            }
            TextField("Default Git remote", text: $baseRemote)
            Picker("Remote publishing", selection: $remotePublishMode) {
                ForEach(AdminChoices.options.publishModes, id: \.id) { mode in Text(mode.title).tag(mode.id) }
            }
            Text(AdminChoices.choice(remotePublishMode, in: AdminChoices.options.publishModes)?.detail ?? "")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(DieterBarButtonStyle())
                Button("Create") {
                    Task {
                        await store.createBoard(
                            name: name, workflow: workflow, description: description,
                            doneArchivePolicy: doneArchivePolicy, baseRemote: baseRemote,
                            remotePublishMode: remotePublishMode)
                    }
                }.buttonStyle(DieterBarButtonStyle(prominent: true)).disabled(
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
                    Button("Cancel") { dismiss() }.buttonStyle(DieterBarButtonStyle())
                    Button("Rename") { rename(board.id) }
                        .buttonStyle(DieterBarButtonStyle(prominent: true))
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
