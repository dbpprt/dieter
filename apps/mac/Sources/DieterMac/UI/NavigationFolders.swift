import SwiftUI

struct NavigationFolderEditor: Identifiable {
    let id = UUID()
    let folderID: String?
    let title: String
    let initialName: String

    static func create(title: String) -> Self {
        Self(folderID: nil, title: title, initialName: "")
    }

    static func rename(_ folder: NavigationFolder) -> Self {
        Self(folderID: folder.id, title: "Rename folder", initialName: folder.name)
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

    private var duplicatesExistingName: Bool {
        existingNames.contains {
            $0.compare(trimmedName, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
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
                    Text("Folders only change how items are arranged on this Mac.")
                        .font(.callout).foregroundStyle(DieterTheme.tertiary)
                }
            }

            TextField("Folder name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
                .accessibilityIdentifier("navigation-folder.name")
                .onSubmit { submit() }

            if duplicatesExistingName {
                Label("A folder with this name already exists.", systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(DieterTheme.coral)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(editor.folderID == nil ? "Create folder" : "Rename") { submit() }
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmedName.isEmpty || duplicatesExistingName)
                    .accessibilityIdentifier("navigation-folder.confirm")
            }
        }
        .padding(22)
        .frame(width: 440)
        .onAppear { nameFocused = true }
    }

    private func submit() {
        guard !trimmedName.isEmpty, !duplicatesExistingName else { return }
        save(trimmedName)
        dismiss()
    }
}
