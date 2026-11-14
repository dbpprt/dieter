import SwiftUI

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
                    Button("Cancel") { dismiss() }.buttonStyle(DieterBarButtonStyle())
                    Button("Rename") { rename(project.id) }
                        .buttonStyle(DieterBarButtonStyle(prominent: true))
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
