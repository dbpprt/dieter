import DieterShared
import SwiftUI

struct NavigationFolderEditor: Identifiable {
    let id = UUID()
    let folderID: String?
    let title: String
    let initialName: String

    static func create(title: String) -> Self {
        Self(folderID: nil, title: title, initialName: "")
    }

    static func rename(id: String, name: String) -> Self {
        Self(folderID: id, title: "Rename folder", initialName: name)
    }
}

struct NavigationFolderNameSheet: View {
    let editor: NavigationFolderEditor
    let existingNames: [String]
    let save: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @FocusState private var nameFocused: Bool

    init(
        editor: NavigationFolderEditor,
        existingNames: [String],
        save: @escaping (String) -> Void
    ) {
        self.editor = editor
        self.existingNames = existingNames
        self.save = save
        _name = State(initialValue: editor.initialName)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Why the name cannot be used, as the core words it; empty when it can.
    private var problem: String {
        SharedRules.shared.folderNameProblem(name: name, existingNames: existingNames)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(DieterTheme.shell)
                    .frame(width: 34, height: 34)
                    .background(DieterTheme.shell.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 2) {
                    Text(editor.title).font(.title2.weight(.bold))
                    Text("Folders and their layout sync across your devices.")
                        .font(.callout).foregroundStyle(DieterTheme.tertiary)
                }
            }

            TextField("Folder name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                .accessibilityIdentifier("navigation-folder.name")
                .onSubmit { submit() }

            if !trimmedName.isEmpty, !problem.isEmpty {
                Label(problem, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(DieterTheme.coral)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(editor.folderID == nil ? "Create folder" : "Rename") { submit() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!problem.isEmpty)
                    .accessibilityIdentifier("navigation-folder.confirm")
            }
        }
        .padding(22)
        .frame(width: 440)
        .onAppear { nameFocused = true }
    }

    private func submit() {
        guard problem.isEmpty else { return }
        save(trimmedName)
        dismiss()
    }
}
