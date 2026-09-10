import AppKit
import DieterAPI
import SwiftUI
import UniformTypeIdentifiers

struct FilesView: View {
    @Environment(DieterStore.self) private var store
    @Bindable var model: FilesModel
    @State private var createPresented = false
    @State private var newPath = ""
    @State private var newDirectory = false
    @State private var movingEntry: Dieter_V1_FileEntry?
    @State private var moveDestination = ""
    @State private var externalActions: FileExternalActions?
    @State private var externalRootPath: String?
    @State private var externalPreparedKey = ""
    @State private var exportingMarkdown = false
    private var editorSession: FileEditorSession { model.fileEditorSession }

    var body: some View {
        VStack(spacing: 0) {
            FilePaneSplit {
                VStack(spacing: 0) {
                    FluidPaneChrome(background: DieterTheme.sidebar, spacing: 9) {
                        HStack(spacing: 8) {
                            Button {
                                Task { await model.navigateFilesBack() }
                            } label: {
                                Image(systemName: "chevron.left")
                            }
                            .buttonStyle(DieterIconButtonStyle())
                            .disabled(!model.fileNavigation.canGoBack || model.fileNavigationLoading)
                            .help("Back")
                            .accessibilityLabel("Back")
                            .accessibilityIdentifier("files.back")
                            Button {
                                Task { await model.navigateFilesForward() }
                            } label: {
                                Image(systemName: "chevron.right")
                            }
                            .buttonStyle(DieterIconButtonStyle())
                            .disabled(!model.fileNavigation.canGoForward || model.fileNavigationLoading)
                            .help("Forward")
                            .accessibilityLabel("Forward")
                            .accessibilityIdentifier("files.forward")
                            PaneTitleBlock(
                                title: "Files",
                                subtitle:
                                    "\(model.files.count) item\(model.files.count == 1 ? "" : "s") · \(model.fileScopeCardID == nil ? model.projectName : "Conversation workspace")",
                                symbol: "folder",
                                prominent: true
                            )
                            Menu {
                                Button("New file…") {
                                    newDirectory = false; createPresented = true
                                }.disabled(!model.isLive || model.saving)
                                Button("New folder…") {
                                    newDirectory = true; createPresented = true
                                }.disabled(!model.isLive || model.saving)
                                if model.fileScopeCardID != nil {
                                    Divider()
                                    Button("Return to project root") {
                                        Task { await model.returnToProjectRoot() }
                                    }
                                }
                                Divider(); Toggle("Show hidden", isOn: $model.showHiddenFiles)
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().buttonStyle(
                                DieterIconButtonStyle())
                            Button {
                                Task { await model.loadFiles() }
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }.buttonStyle(DieterIconButtonStyle()).disabled(model.fileNavigationLoading)
                        }
                    } secondary: {
                        HStack(spacing: 8) {
                            Image(
                                systemName: model.fileScopeCardID == nil
                                    ? (model.filePath.isEmpty ? "folder" : "folder.fill")
                                    : "point.3.connected.trianglepath.dotted"
                            ).font(.system(size: 11)).foregroundStyle(DieterTheme.tertiary)
                            Text(
                                model.filePath.isEmpty
                                    ? (model.fileScopeCardID == nil
                                        ? model.projectPath
                                        : "Workspace root · \(model.fileScopeCardID?.prefix(8) ?? "")") : model.filePath
                            )
                            .font(.system(size: 11)).foregroundStyle(DieterTheme.tertiary).lineLimit(1).truncationMode(
                                .middle
                            )
                            .textSelection(.enabled)
                            Spacer()
                            if model.showHiddenFiles {
                                Text("Hidden files").font(.system(size: 10, weight: .semibold)).foregroundStyle(
                                    DieterTheme.shell)
                            }
                        }
                    }
                    if model.filesLoading || model.filesError != nil {
                        LoadFeedback(
                            title: "Loading files…", error: model.filesError,
                            retry: { Task { await model.loadFiles() } }, compact: true
                        )
                        .accessibilityIdentifier("files.list-feedback")
                    }
                    List {
                        if !model.filePath.isEmpty {
                            Button {
                                navigateToParent()
                            } label: {
                                Label("Parent Folder", systemImage: "arrow.turn.up.left")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(DieterTheme.subtle)
                                    .frame(maxWidth: .infinity, minHeight: 29, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(model.fileNavigationLoading)
                            .listRowInsets(EdgeInsets(top: 1, leading: 10, bottom: 1, trailing: 10))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                        }
                        ForEach(model.files, id: \.path) { entry in
                            Button {
                                Task {
                                    if entry.kind == "directory" {
                                        await model.navigateFiles(to: entry.path)
                                    } else {
                                        await model.openFile(path: entry.path)
                                    }
                                }
                            } label: {
                                HStack(spacing: 9) {
                                    Image(systemName: entry.kind == "directory" ? "folder.fill" : symbol(entry.name))
                                        .foregroundStyle(
                                            entry.kind == "directory" ? DieterTheme.shell : DieterTheme.tertiary
                                        )
                                        .frame(width: 15)
                                    Text(entry.name).lineLimit(1)
                                    Spacer()
                                    if entry.kind != "directory" {
                                        Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                                            .font(.caption2).foregroundStyle(DieterTheme.tertiary)
                                    }
                                }
                                .font(
                                    .system(
                                        size: 12, weight: model.selectedFilePath == entry.path ? .semibold : .regular)
                                )
                                .padding(.horizontal, 8).frame(minHeight: 30)
                                .background(
                                    model.selectedFilePath == entry.path ? DieterTheme.selection : .clear,
                                    in: RoundedRectangle(cornerRadius: DieterMetrics.controlRadius, style: .continuous)
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("files.row.\(entry.path)")
                            .smokeTarget("files.row.\(entry.path)")
                            .disabled(entry.kind == "directory" && model.fileNavigationLoading)
                            .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .contextMenu {
                                Button("Move or rename…") {
                                    movingEntry = entry; moveDestination = entry.path
                                }.disabled(!model.isLive || model.saving)
                                Button("Delete", role: .destructive) {
                                    Task {
                                        await model.deleteFile(path: entry.path, recursive: entry.kind == "directory")
                                    }
                                }.disabled(!model.isLive || model.saving)
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }.frame(maxHeight: .infinity, alignment: .top).background(DieterTheme.sidebar)
            } preview: {
                VStack(spacing: 0) {
                    if (model.fileLoading || model.fileError != nil) && model.fileDocument == nil {
                        LoadFeedback(
                            title: "Loading \(model.selectedFilePath)…", error: model.fileError,
                            retry: { Task { await model.openFile(path: model.selectedFilePath) } }
                        )
                        .accessibilityIdentifier("files.preview-feedback")
                    } else if let document = model.fileDocument {
                        VStack(spacing: 0) {
                            FluidPaneChrome(background: DieterTheme.sidebar, spacing: 8) {
                                HStack(spacing: 9) {
                                    PaneTitleBlock(
                                        title: document.name,
                                        subtitle: preparedExternalActions?.displayPath ?? document.path,
                                        symbol: symbol(document.name)
                                    )
                                    .textSelection(.enabled)
                                    .accessibilityIdentifier("files.document-title")
                                    .smokeTarget("files.document-title")
                                    .contextMenu {
                                        Button("Copy File Name") { FileExternalActions.copy(document.name) }
                                        Button("Copy Path") {
                                            FileExternalActions.copy(
                                                preparedExternalActions?.displayPath ?? document.path)
                                        }
                                    }
                                    if editorSession.isDirty { StatusPill(text: "Edited", color: DieterTheme.amber) }
                                    openMenu(document)
                                    if exportingMarkdown {
                                        ProgressView().controlSize(.small)
                                            .accessibilityLabel("Exporting Markdown")
                                    }
                                    Button("Save") { Task { await model.saveCurrentDocument() } }
                                        .buttonStyle(DieterPrimaryButtonStyle())
                                        .keyboardShortcut("s", modifiers: .command)
                                        .accessibilityIdentifier("files.save").smokeTarget("files.save")
                                        .disabled(
                                            document.binary || !editorSession.isDirty || !model.isLive || model.saving)
                                }
                            } secondary: {
                                HStack(spacing: 8) {
                                    Text(
                                        ProjectFileLanguage.detect(filename: document.name) == .markdown
                                            ? "Markdown"
                                            : (document.mimeType.isEmpty ? "Unknown type" : document.mimeType))
                                    Text("·")
                                    Text(ByteCountFormatter.string(fromByteCount: document.size, countStyle: .file))
                                    Spacer()
                                    if !document.binary { Text("Editable") }
                                }
                                .font(.system(size: 10)).foregroundStyle(DieterTheme.tertiary)
                            }
                            if model.fileLoading || model.fileError != nil {
                                LoadFeedback(
                                    title: "Refreshing \(document.name)…", error: model.fileError,
                                    retry: { Task { await model.openFile(path: document.path) } }, compact: true)
                            }
                            if let image = previewImage(document) {
                                ProjectImagePreview(image: image)
                            } else if document.binary {
                                ContentUnavailableView(
                                    "Binary file", systemImage: "doc.badge.ellipsis",
                                    description: Text(
                                        "\(ByteCountFormatter.string(fromByteCount: document.size, countStyle: .file)) • \(document.mimeType)"
                                    ))
                            } else {
                                VStack(spacing: 0) {
                                    if ProjectFileLanguage.detect(filename: document.name) == .markdown {
                                        MarkdownFileEditor(
                                            session: editorSession, documentKey: model.documentKey,
                                            text: document.content, filename: document.name
                                        )
                                        .id(model.documentKey)
                                    } else {
                                        SyntaxHighlightedEditor(
                                            session: editorSession,
                                            documentKey: model.documentKey,
                                            text: document.content,
                                            filename: document.name
                                        )
                                        .id(model.documentKey)
                                        .accessibilityIdentifier("files.editor")
                                    }
                                    HStack(spacing: 12) {
                                        Text(ProjectFileLanguage.detect(filename: document.name).displayName)
                                        Text("UTF-8")
                                        Spacer()
                                        Text("\(editorSession.lineCount) lines")
                                    }
                                    .font(.system(size: 10))
                                    .foregroundStyle(DieterTheme.tertiary)
                                    .padding(.horizontal, 12).frame(height: 25)
                                    .background(DieterTheme.sidebar)
                                    .overlay(alignment: .top) { Rectangle().fill(DieterTheme.border).frame(height: 1) }
                                }
                            }
                        }
                    } else {
                        VStack(spacing: 0) {
                            FluidPaneChrome {
                                PaneTitleBlock(
                                    title: "File preview", subtitle: "Select a project file to inspect or edit",
                                    symbol: "doc.text")
                            }
                            ContentUnavailableView(
                                "Select a file", systemImage: "doc.text",
                                description: Text("Browse and edit text files in the selected Git working tree.")
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: model.fileScopeGeneration) {
            let generation = model.fileScopeGeneration
            guard await model.loadFiles(), !Task.isCancelled, generation == model.fileScopeGeneration else { return }
            if !model.selectedFilePath.isEmpty, !editorSession.isDirty {
                await model.openFile(path: model.selectedFilePath)
            }
        }
        .onChange(of: model.showHiddenFiles) { _, _ in Task { await model.loadFiles() } }
        .task(id: externalActionKey) { await prepareExternalActions() }
        .sheet(isPresented: $createPresented) {
            VStack(alignment: .leading, spacing: 14) {
                Text(newDirectory ? "New folder" : "New file").font(.title2.weight(.bold));
                TextField(newDirectory ? "Folder path" : "File path", text: $newPath);
                HStack {
                    Spacer(); Button("Cancel") { createPresented = false };
                    Button("Create") {
                        Task {
                            await model.createFile(path: joined(model.filePath, newPath), directory: newDirectory);
                            newPath = ""; createPresented = false
                        }
                    }.buttonStyle(.borderedProminent).disabled(newPath.isEmpty)
                }
            }.padding(22).frame(width: 430)
        }
        .sheet(isPresented: Binding(get: { movingEntry != nil }, set: { if !$0 { movingEntry = nil } })) {
            if let entry = movingEntry {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Move or rename").font(.title2.weight(.bold));
                    Text(entry.path).font(.caption.monospaced()).foregroundStyle(.secondary);
                    TextField("Destination path", text: $moveDestination);
                    HStack {
                        Spacer(); Button("Cancel") { movingEntry = nil };
                        Button("Move") {
                            Task {
                                await model.moveFile(source: entry.path, destination: moveDestination);
                                movingEntry = nil
                            }
                        }.buttonStyle(.borderedProminent).disabled(
                            moveDestination.isEmpty || moveDestination == entry.path)
                    }
                }.padding(22).frame(width: 500)
            }
        }
    }

    private func symbol(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "gif", "webp"].contains(ext)
            ? "photo"
            : ["swift", "go", "kt", "js", "ts", "tsx", "json", "md", "yml", "yaml"].contains(ext)
                ? "chevron.left.forwardslash.chevron.right" : "doc"
    }

    private func previewImage(_ document: Dieter_V1_FileDocument) -> NSImage? {
        guard ProjectFilePresentation.isImage(filename: document.name, mimeType: document.mimeType) else { return nil }
        let bytes = ProjectFilePresentation.bytes(
            binary: document.binary, content: document.content, data: document.data)
        return NSImage(data: bytes)
    }

    private func download(_ document: Dieter_V1_FileDocument) {
        let bytes = FileExternalActions.exportBytes(
            document: document, session: editorSession, documentKey: model.documentKey)
        let panel = NSSavePanel()
        panel.title = "Save As"
        panel.prompt = "Save"
        panel.nameFieldStringValue = document.name
        panel.canCreateDirectories = true
        let extensionName = (document.name as NSString).pathExtension
        if !extensionName.isEmpty, let contentType = UTType(filenameExtension: extensionName) {
            panel.allowedContentTypes = [contentType]
        }
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try bytes.write(to: destination, options: .atomic)
        } catch {
            model.fileError = "Could not save a copy of \(document.name): \(error.localizedDescription)"
        }
    }

    private var externalActionKey: String {
        let transport = store.rpc.map { String(describing: ObjectIdentifier($0)) } ?? "none"
        return
            "\(model.documentKey):\(model.fileScopeGeneration):\(model.isLive):\(store.phase.isConnected):\(model.fileDocument?.revision ?? ""):\(transport)"
    }

    private var preparedExternalActions: FileExternalActions? {
        externalPreparedKey == externalActionKey ? externalActions : nil
    }

    private var verifiedLocalTransport: Bool {
        guard model.isLive, store.phase.isConnected, let rpc = store.rpc else { return false }
        return rpc.endpoint.id == model.target.endpointID && rpc.isLoopbackDataPlane
    }

    private func prepareExternalActions() async {
        let key = externalActionKey
        externalActions = nil
        externalRootPath = nil
        guard let document = model.fileDocument else { return }
        let target = model.target
        var rootPath: String? = target.conversationID.isEmpty ? model.projectPath : nil
        if !target.conversationID.isEmpty, let rpc = store.rpc, rpc.endpoint.id == target.endpointID {
            if let workspace = try? await rpc.workspace(cardID: target.conversationID),
                workspace.cardID == target.conversationID, workspace.projectID == target.projectID
            {
                rootPath = workspace.path
            }
        }
        guard !Task.isCancelled, key == externalActionKey else { return }
        var actions = FileExternalActions.resolve(
            verifiedLocal: verifiedLocalTransport, rootPath: rootPath, relativePath: document.path)
        actions.loadApplications()
        externalRootPath = rootPath
        externalActions = actions
        externalPreparedKey = key
    }

    private func openMenu(_ document: Dieter_V1_FileDocument) -> some View {
        let actions = preparedExternalActions
        let documentKey = model.documentKey
        return Menu {
            if actions?.fileURL != nil {
                if editorSession.isDirty { Text("Opens the saved version") }
                Section("Open in") {
                    ForEach(actions?.applications ?? []) { application in
                        Button {
                            openExternally(application: application.url)
                        } label: {
                            Label {
                                Text(application.name + (application.isDefault ? " (Default)" : ""))
                            } icon: {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: application.url.path))
                            }
                        }
                    }
                    if actions?.applications.isEmpty == true {
                        Button("Default App") { openExternally() }
                    }
                }
                Button("Reveal in Finder", systemImage: "folder") {
                    if let url = currentLocalFileURL() { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                Divider()
            } else {
                Text(actions?.unavailableReason ?? "Preparing file actions…")
            }
            Button("Save As…", systemImage: "square.and.arrow.down") { download(document) }
                .accessibilityIdentifier("files.save-as")
            if !document.binary, ProjectFileLanguage.detect(filename: document.name) == .markdown {
                Divider()
                Button("Export PDF…", systemImage: "doc.richtext") {
                    exportMarkdown(document, documentKey: documentKey, format: .pdf)
                }
                .disabled(exportingMarkdown)
                .accessibilityIdentifier("files.export.pdf")
                Button("Export HTML…", systemImage: "chevron.left.forwardslash.chevron.right") {
                    exportMarkdown(document, documentKey: documentKey, format: .html)
                }
                .disabled(exportingMarkdown)
                .accessibilityIdentifier("files.export.html")
            }
            Divider()
            Button("Copy File Name", systemImage: "doc.on.doc") { FileExternalActions.copy(document.name) }
            Button("Copy Path") { FileExternalActions.copy(actions?.displayPath ?? document.path) }
        } label: {
            Label(
                actions?.fileURL == nil ? "Save As…" : (editorSession.isDirty ? "Open Saved" : "Open"),
                systemImage: actions?.fileURL == nil ? "square.and.arrow.down" : "arrow.up.forward.app")
        } primaryAction: {
            if actions?.fileURL != nil { openExternally() } else { download(document) }
        }
        .menuStyle(.button)
        .fixedSize()
        .help(actions?.fileURL == nil ? "Save a local copy of this file" : "Open the saved file in its default app")
        .accessibilityIdentifier("files.open-menu")
        .smokeTarget("files.open-menu")
    }

    private func exportMarkdown(
        _ document: Dieter_V1_FileDocument, documentKey: String, format: MarkdownFileExport.Format
    ) {
        guard !exportingMarkdown, model.documentKey == documentKey,
            let snapshot = FileExternalActions.markdownExportDocument(
                document: document, session: editorSession, documentKey: documentKey)
        else { return }
        let panel = NSSavePanel()
        panel.title = format.title
        panel.prompt = "Export"
        panel.nameFieldStringValue = snapshot.filename(for: format)
        panel.allowedContentTypes = [format.contentType]
        panel.canCreateDirectories = true
        panel.message =
            format == .pdf
            ? "Export the current draft on light pages, including diagrams and charts."
            : "Export the current draft as a standalone HTML document with diagrams and charts."
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        exportingMarkdown = true
        Task { @MainActor in
            defer { exportingMarkdown = false }
            do {
                let data = try await MarkdownFileExport.data(for: snapshot, format: format)
                try data.write(to: destination, options: .atomic)
            } catch {
                if model.documentKey == documentKey {
                    model.fileError = "Could not export \(document.name): \(error.localizedDescription)"
                }
            }
        }
    }

    private func currentLocalFileURL() -> URL? {
        guard preparedExternalActions?.fileURL != nil, let document = model.fileDocument else { return nil }
        let current = FileExternalActions.resolve(
            verifiedLocal: verifiedLocalTransport, rootPath: externalRootPath, relativePath: document.path)
        if current.fileURL == nil { model.fileError = current.unavailableReason }
        return current.fileURL
    }

    private func openExternally(application: URL? = nil) {
        guard let url = currentLocalFileURL() else { return }
        let key = model.documentKey
        Task { @MainActor in
            do {
                let configuration = NSWorkspace.OpenConfiguration()
                if let application {
                    _ = try await NSWorkspace.shared.open(
                        [url], withApplicationAt: application, configuration: configuration)
                } else {
                    _ = try await NSWorkspace.shared.open(url, configuration: configuration)
                }
            } catch {
                if model.documentKey == key {
                    model.fileError = "Could not open \(url.lastPathComponent): \(error.localizedDescription)"
                }
            }
        }
    }

    private func navigateToParent() {
        guard !model.filePath.isEmpty else { return }
        let parent = ProjectFileNavigation.parentPath(of: model.filePath)
        Task { await model.navigateFiles(to: parent) }
    }

    private func joined(_ base: String, _ path: String) -> String {
        base.isEmpty ? path : (base as NSString).appendingPathComponent(path)
    }
}

private struct ProjectImagePreview: View {
    let image: NSImage
    @State private var zoom: CGFloat = 1

    private var pixelSize: CGSize {
        guard
            let representation = image.representations.max(by: {
                ($0.pixelsWide * $0.pixelsHigh) < ($1.pixelsWide * $1.pixelsHigh)
            }),
            representation.pixelsWide > 0, representation.pixelsHigh > 0
        else { return image.size }
        return CGSize(width: representation.pixelsWide, height: representation.pixelsHigh)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "photo")
                Text("\(Int(pixelSize.width)) × \(Int(pixelSize.height)) px")
                Spacer()
                Button {
                    zoom = max(0.5, zoom - 0.25)
                } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(DieterIconButtonStyle()).disabled(zoom <= 0.5).help("Zoom out")
                Button("Fit") { zoom = 1 }.buttonStyle(.borderless).font(.caption)
                Button {
                    zoom = min(4, zoom + 0.25)
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(DieterIconButtonStyle()).disabled(zoom >= 4).help("Zoom in")
            }
            .font(.system(size: 10, weight: .medium)).foregroundStyle(DieterTheme.subtle)
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(DieterTheme.sidebar)
            .overlay(alignment: .bottom) { Rectangle().fill(DieterTheme.border).frame(height: 1) }

            GeometryReader { geometry in
                let availableWidth = max(1, geometry.size.width - 48)
                let availableHeight = max(1, geometry.size.height - 48)
                let fitScale = min(
                    1, min(availableWidth / max(1, pixelSize.width), availableHeight / max(1, pixelSize.height)))
                let width = pixelSize.width * fitScale * zoom
                let height = pixelSize.height * fitScale * zoom

                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: width, height: height)
                        .background(Color.white.opacity(0.04))
                        .overlay(Rectangle().stroke(DieterTheme.strongBorder))
                        .shadow(color: .black.opacity(0.32), radius: 18, y: 8)
                        .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
                }
                .background(DieterTheme.background)
            }
        }
    }
}
