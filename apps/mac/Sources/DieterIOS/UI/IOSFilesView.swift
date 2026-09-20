#if os(iOS)
    import DieterAPI
    import SwiftUI

    struct IOSFilesView: View {
        @Environment(\.dismiss) private var dismiss
        @Bindable var store: IOSStore
        let scope: IOSFileScope
        @State private var directory = ""
        @State private var listing: Dieter_V1_FileList?
        @State private var document: Dieter_V1_FileDocument?
        @State private var text = ""
        @State private var loading = false
        @State private var saving = false
        @State private var failed = false
        @State private var pendingExit: FileExit?
        @State private var confirmExit = false
        @FocusState private var editorFocused: Bool

        private enum FileExit { case back, dismiss }
        private var isDirty: Bool { document.map { !$0.binary && text != $0.content } ?? false }
        private var isCurrentScope: Bool { store.machines.contains { $0.daemonID == scope.machineID } }
        private var canAccess: Bool { store.machines.contains { $0.daemonID == scope.machineID && $0.online } }

        var body: some View {
            NavigationStack {
                Group {
                    if let document {
                        documentContent(document)
                    } else if loading, listing == nil {
                        ProgressView("Loading files…").frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        directoryContent
                    }
                }
                .safeAreaInset(edge: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(document?.path ?? (directory.isEmpty ? scope.title : directory))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("ios.files.path")
                        if !isCurrentScope {
                            Label(
                                "This file belongs to another machine. Reconnect to that machine to save.",
                                systemImage: "wifi.exclamationmark"
                            )
                            .font(.caption).foregroundStyle(.orange)
                        } else if !canAccess {
                            Label("Offline · Your edits remain available", systemImage: "wifi.slash")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8).background(.bar)
                }
                .navigationTitle(
                    document?.name ?? (directory.isEmpty ? "Files" : (directory as NSString).lastPathComponent)
                )
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        if document != nil || !directory.isEmpty {
                            Button("Back", systemImage: "chevron.left") { requestExit(.back) }
                                .disabled(loading || saving)
                                .accessibilityIdentifier("ios.files.back")
                        }
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        if let document, !document.binary {
                            Button {
                                Task { _ = await save() }
                            } label: {
                                if saving { ProgressView() } else { Text("Save").fontWeight(.semibold) }
                            }
                            .disabled(!isDirty || !canAccess || saving)
                            .accessibilityIdentifier("ios.files.save")
                        }
                        Button("Done") { requestExit(.dismiss) }
                            .disabled(saving)
                            .accessibilityIdentifier("ios.files.done")
                    }
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Done") { editorFocused = false }
                            .accessibilityIdentifier("ios.files.keyboard-done")
                    }
                }
                .confirmationDialog("Save changes to this file?", isPresented: $confirmExit, titleVisibility: .visible)
                {
                    Button("Save Changes") {
                        Task { if await save() { finishExit() } }
                    }.disabled(!canAccess)
                    Button("Discard Changes", role: .destructive) { finishExit() }
                    Button("Keep Editing", role: .cancel) { pendingExit = nil }
                } message: {
                    Text("Your changes have not been saved on \(scope.title).")
                }
                .interactiveDismissDisabled(isDirty || saving)
                .task { await loadDirectory() }
            }
            .accessibilityIdentifier("ios.files")
        }

        private var directoryContent: some View {
            List {
                ForEach(listing?.entries ?? [], id: \.path) { entry in
                    Button {
                        Task {
                            if entry.kind == "directory" {
                                directory = entry.path
                                listing = nil
                                await loadDirectory()
                            } else {
                                await openFile(entry.path)
                            }
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: entry.kind == "directory" ? "folder.fill" : "doc.text")
                                .foregroundStyle(entry.kind == "directory" ? Color.accentColor : .secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.name).foregroundStyle(.primary).lineLimit(2)
                                if entry.kind != "directory" {
                                    Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(
                                .tertiary)
                        }.padding(.vertical, 3)
                    }
                    .disabled(!canAccess || loading)
                    .accessibilityIdentifier("ios.files.entry.\(entry.path)")
                }
            }
            .listStyle(.plain)
            .overlay {
                if failed {
                    ContentUnavailableView {
                        Label("Couldn’t load files", systemImage: "wifi.exclamationmark")
                    } actions: {
                        Button("Try again") { Task { await loadDirectory() } }.disabled(!canAccess)
                    }
                } else if listing?.entries.isEmpty == true {
                    ContentUnavailableView("Empty folder", systemImage: "folder")
                }
            }
            .refreshable { await loadDirectory() }
            .accessibilityIdentifier("ios.files.list")
        }

        @ViewBuilder
        private func documentContent(_ document: Dieter_V1_FileDocument) -> some View {
            if document.binary {
                if document.mimeType.hasPrefix("image/"), let image = UIImage(data: document.data) {
                    ScrollView([.horizontal, .vertical]) {
                        Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: 1000)
                            .accessibilityLabel(document.name)
                    }
                } else {
                    ContentUnavailableView(
                        "No text preview", systemImage: "doc",
                        description: Text(
                            "\(document.name) · \(ByteCountFormatter.string(fromByteCount: document.size, countStyle: .file))"
                        ))
                }
            } else {
                TextEditor(text: $text)
                    .focused($editorFocused)
                    .font(.system(.body, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 10)
                    .disabled(saving)
                    .accessibilityLabel("File contents")
                    .accessibilityIdentifier("ios.files.editor")
            }
        }

        private func loadDirectory() async {
            guard canAccess, !loading else { return }
            loading = true
            failed = false
            defer { loading = false }
            let result = await store.listFiles(
                projectID: scope.projectID, checkoutID: scope.checkoutID, cardID: scope.cardID, path: directory)
            guard isCurrentScope else { return }
            listing = result
            failed = result == nil
        }

        private func openFile(_ path: String) async {
            guard canAccess, !loading else { return }
            loading = true
            defer { loading = false }
            if let result = await store.readFile(
                projectID: scope.projectID, checkoutID: scope.checkoutID, cardID: scope.cardID, path: path),
                isCurrentScope
            {
                document = result
                text = result.content
            }
        }

        private func save() async -> Bool {
            guard canAccess, !saving, let current = document, !current.binary else { return false }
            if !isDirty { return true }
            saving = true
            editorFocused = false
            defer { saving = false }
            let snapshot = text
            guard
                let saved = await store.saveFile(
                    projectID: scope.projectID, checkoutID: scope.checkoutID, cardID: scope.cardID, document: current,
                    content: snapshot
                ), isCurrentScope, document?.path == current.path
            else { return false }
            document = saved
            text = saved.content
            return true
        }

        private func requestExit(_ exit: FileExit) {
            pendingExit = exit
            if isDirty { confirmExit = true } else { finishExit() }
        }

        private func finishExit() {
            guard let exit = pendingExit else { return }
            pendingExit = nil
            switch exit {
            case .dismiss: dismiss()
            case .back:
                if document != nil {
                    document = nil; text = ""
                } else {
                    directory = (directory as NSString).deletingLastPathComponent
                    listing = nil
                    Task { await loadDirectory() }
                }
            }
        }
    }
#endif
