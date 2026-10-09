import AppKit
import DieterAPI
import DieterShared
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
    private var editorSession: FileEditorSession { model.fileEditorSession }

    var body: some View {
        DieterSectionScaffold {
            DieterTitleCapsule(title: "Files", detail: headerSummary)
        } trailing: {
            EmptyView()
        } content: {
            VStack(spacing: 0) {
                navigationToolbar
                Rectangle().fill(DieterTheme.hairline).frame(height: 1)
                FilePaneSplit {
                    VStack(spacing: 0) {
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
                                        .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(model.fileNavigationLoading)
                                .listRowInsets(EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10))
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
                                        Image(
                                            systemName: FilePresentation.symbol(
                                                name: entry.name, directory: entry.kind == "directory")
                                        )
                                        .foregroundStyle(
                                            entry.kind == "directory" ? DieterTheme.shell : DieterTheme.tertiary
                                        )
                                        .frame(width: 15)
                                        Text(entry.name).lineLimit(1)
                                        Spacer()
                                        if entry.kind != "directory" {
                                            Text(SharedRules.shared.bytes(count: entry.size))
                                                .font(.caption2).foregroundStyle(DieterTheme.tertiary)
                                        }
                                    }
                                    .font(
                                        .system(
                                            size: 12,
                                            weight: model.selectedFilePath == entry.path ? .semibold : .regular)
                                    )
                                    .padding(.horizontal, 8).frame(minHeight: 24)
                                    .background(
                                        model.selectedFilePath == entry.path ? DieterTheme.tileSelected : .clear,
                                        in: RoundedRectangle(cornerRadius: DieterMetrics.rowRadius, style: .continuous)
                                    )
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("files.row.\(entry.path)")
                                .smokeTarget("files.row.\(entry.path)")
                                .disabled(entry.kind == "directory" && model.fileNavigationLoading)
                                .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6))
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                                .contextMenu {
                                    Button(entry.kind == "directory" ? "Open Folder" : "Open") {
                                        Task {
                                            if entry.kind == "directory" {
                                                await model.navigateFiles(to: entry.path)
                                            } else {
                                                await model.openFile(path: entry.path)
                                            }
                                        }
                                    }
                                    Divider()
                                    Button("Copy Path") { FileExternalActions.copy(entry.path) }
                                    Button("Copy Name") { FileExternalActions.copy(entry.name) }
                                    Divider()
                                    Button("Move or rename…") {
                                        movingEntry = entry; moveDestination = entry.path
                                    }.disabled(!model.isLive || model.saving)
                                    Button("Delete", role: .destructive) {
                                        Task {
                                            await model.deleteFile(
                                                path: entry.path, recursive: entry.kind == "directory")
                                        }
                                    }.disabled(!model.isLive || model.saving)
                                }
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                    }.frame(maxHeight: .infinity, alignment: .top)
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
                                documentToolbar(document)
                                Rectangle().fill(DieterTheme.hairline).frame(height: 1)
                                if model.fileLoading || model.fileError != nil {
                                    // A save conflict offers Reload above instead of retrying the read.
                                    LoadFeedback(
                                        title: "Refreshing \(document.name)…", error: model.fileError,
                                        retry: model.conflict
                                            ? nil : { Task { await model.openFile(path: document.path) } },
                                        compact: true)
                                }
                                let renderer = FilePresentation.renderer(document)
                                switch renderer {
                                case .image:
                                    if let image = NSImage(data: document.bytes) {
                                        ProjectImagePreview(image: image)
                                    } else {
                                        unsupportedDocument(document)
                                    }
                                case .pdf:
                                    ConversationPDFDocumentRenderer(data: document.bytes) {
                                        unsupportedDocument(document)
                                    }
                                case .markdown, .text, .html:
                                    VStack(spacing: 0) {
                                        if renderer == .html {
                                            HTMLFileView(
                                                session: editorSession, documentKey: model.documentKey,
                                                text: document.content, filename: document.name,
                                                path: document.path, read: model.htmlPreviewRead
                                            )
                                            .id(model.documentKey)
                                        } else if renderer == .markdown {
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
                                            Text(model.languageName)
                                            Text("UTF-8")
                                            Spacer()
                                            Text("\(editorSession.lineCount) lines")
                                        }
                                        .font(.system(size: 10))
                                        .foregroundStyle(DieterTheme.tertiary)
                                        .padding(.horizontal, 12).frame(height: 25)
                                        .overlay(alignment: .top) {
                                            Rectangle().fill(DieterTheme.hairline).frame(height: 1)
                                        }
                                    }
                                default:
                                    unsupportedDocument(document)
                                }
                            }
                        } else {
                            VStack(spacing: 0) {
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
        }
        .task(id: model.fileScopeGeneration) {
            let generation = model.fileScopeGeneration
            guard await model.loadFiles(), !Task.isCancelled, generation == model.fileScopeGeneration else { return }
            if !model.selectedFilePath.isEmpty, !editorSession.isDirty {
                await model.openFile(path: model.selectedFilePath)
            }
        }
        .task(id: externalActionKey) { await prepareExternalActions() }
        .sheet(isPresented: $createPresented) {
            VStack(alignment: .leading, spacing: 14) {
                Text(newDirectory ? "New folder" : "New file").font(.title2.weight(.bold));
                TextField(newDirectory ? "Folder path" : "File path", text: $newPath);
                HStack {
                    Spacer(); Button("Cancel") { createPresented = false }.buttonStyle(DieterBarButtonStyle());
                    Button("Create") {
                        Task {
                            await model.createFile(name: newPath, directory: newDirectory);
                            newPath = ""; createPresented = false
                        }
                    }.buttonStyle(DieterBarButtonStyle(prominent: true)).disabled(newPath.isEmpty)
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
                        Spacer(); Button("Cancel") { movingEntry = nil }.buttonStyle(DieterBarButtonStyle());
                        Button("Move") {
                            Task {
                                await model.moveFile(source: entry.path, destination: moveDestination);
                                movingEntry = nil
                            }
                        }.buttonStyle(DieterBarButtonStyle(prominent: true)).disabled(
                            moveDestination.isEmpty || moveDestination == entry.path)
                    }
                }.padding(22).frame(width: 500)
            }
        }
    }

    /// One dense row: the document's folder and name, its state, and its actions.
    private func documentToolbar(_ document: Dieter_V1_FileDocument) -> some View {
        let directory = (document.path as NSString).deletingLastPathComponent
        return HStack(spacing: 8) {
            Image(systemName: FilePresentation.symbol(name: document.name)).font(.system(size: 11))
                .foregroundStyle(DieterTheme.tertiary)
            HStack(spacing: 0) {
                if !directory.isEmpty {
                    Text(directory + "/").foregroundStyle(DieterTheme.tertiary).lineLimit(1).truncationMode(.head)
                }
                Text(document.name).fontWeight(.semibold).lineLimit(1).layoutPriority(1)
            }
            .font(.system(size: 12, design: .monospaced))
            .help(preparedExternalActions?.displayPath ?? document.path)
            .textSelection(.enabled)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("files.document-title")
            .smokeTarget("files.document-title")
            .contextMenu {
                Button("Copy File Name") { FileExternalActions.copy(document.name) }
                Button("Copy Path") { FileExternalActions.copy(preparedExternalActions?.displayPath ?? document.path) }
                if !directory.isEmpty {
                    Button("Show Folder") { Task { await model.navigateFiles(to: directory) } }
                }
            }
            if editorSession.isDirty { StatusPill(text: "Edited", color: DieterTheme.amber) }
            Text(
                "\(model.typeLabel) · \(SharedRules.shared.bytes(count: document.size))\(document.binary ? "" : " · Editable")"
            )
            .font(.system(size: 10)).foregroundStyle(DieterTheme.tertiary).lineLimit(1)
            Spacer(minLength: 8)
            FileDocumentActions(
                files: model, identifierPrefix: "files", compact: true, resolveExternalActions: currentExternalActions)
            openMenu(document)
            if model.conflict {
                Button("Reload") { Task { await model.reloadDocument() } }
                    .buttonStyle(DieterBarButtonStyle(size: 28))
                    .help("Replace your edits with the version on disk")
                    .accessibilityIdentifier("files.reload").smokeTarget("files.reload")
                    .disabled(!model.isLive || model.saving)
            }
            Button("Save") { Task { await model.saveCurrentDocument() } }
                .buttonStyle(DieterBarButtonStyle(prominent: true, size: 28))
                .keyboardShortcut("s", modifiers: .command)
                .accessibilityIdentifier("files.save").smokeTarget("files.save")
                .disabled(document.binary || !editorSession.isDirty || !model.isLive || model.saving)
        }
        .controlSize(.small)
        .padding(.horizontal, 10).frame(height: 38)
    }

    private var headerSummary: String {
        let count = SharedRules.shared.count(count: Int32(clamping: model.files.count), noun: "item", plural: "")
        return "\(model.fileScopeCardID == nil ? model.projectName : "Conversation workspace") · \(count)"
    }

    private var navigationToolbar: some View {
        Group {
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Button {
                        Task { await model.navigateFilesBack() }
                    } label: {
                        Label("Back", systemImage: "chevron.left").labelStyle(.iconOnly)
                    }
                    .disabled(!model.fileNavigation.canGoBack || model.fileNavigationLoading)
                    .help("Back")
                    .accessibilityIdentifier("files.back")
                    Button {
                        Task { await model.navigateFilesForward() }
                    } label: {
                        Label("Forward", systemImage: "chevron.right").labelStyle(.iconOnly)
                    }
                    .disabled(!model.fileNavigation.canGoForward || model.fileNavigationLoading)
                    .help("Forward")
                    .accessibilityIdentifier("files.forward")
                }
                .buttonStyle(DieterBarButtonStyle(shape: .circle, size: 28))
                if model.fileScopeCardID == nil {
                    ProjectCheckoutMenu(projectID: model.target.projectID, size: 28)
                }
                breadcrumb
                Spacer(minLength: 8)
                Menu {
                    Button("New File…", systemImage: "doc.badge.plus") {
                        newDirectory = false; createPresented = true
                    }.disabled(!model.isLive || model.saving)
                    Button("New Folder…", systemImage: "folder.badge.plus") {
                        newDirectory = true; createPresented = true
                    }.disabled(!model.isLive || model.saving)
                    Divider()
                    Button("Copy Folder Path") {
                        FileExternalActions.copy(model.filePath.isEmpty ? model.projectPath : model.filePath)
                    }
                    if model.fileScopeCardID != nil {
                        Divider()
                        Button("Return to Project Root") {
                            Task { await model.returnToProjectRoot() }
                        }
                    }
                    Divider()
                    Toggle("Show Hidden Files", isOn: $model.showHiddenFiles)
                } label: {
                    DieterMenuLabel(symbol: "plus", size: 28)
                }
                .dieterMenuChrome(.circle)
                .help("New file or folder")
                .accessibilityLabel("New")
                .accessibilityIdentifier("files.actions")
                Button {
                    Task { await model.loadFiles() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise").labelStyle(.iconOnly)
                }
                .buttonStyle(DieterBarButtonStyle(shape: .circle, size: 28))
                .disabled(model.fileNavigationLoading)
                .help("Refresh files")
                .accessibilityIdentifier("files.refresh")
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }

    /// The current folder as clickable segments from the checkout root.
    private var breadcrumb: some View {
        let parts = model.filePath.split(separator: "/").map(String.init)
        let root =
            model.fileScopeCardID == nil
            ? ((model.projectPath as NSString).lastPathComponent.isEmpty
                ? model.projectName : (model.projectPath as NSString).lastPathComponent)
            : "Workspace"
        return HStack(spacing: 2) {
            breadcrumbSegment(root, path: "", current: parts.isEmpty)
                .help(model.fileScopeCardID == nil ? model.projectPath : "Conversation workspace root")
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                Image(systemName: "chevron.compact.right").font(.system(size: 10)).foregroundStyle(DieterTheme.tertiary)
                breadcrumbSegment(
                    part, path: parts[...index].joined(separator: "/"), current: index == parts.count - 1)
            }
            if model.showHiddenFiles {
                Text("Hidden shown").font(.system(size: 10, weight: .semibold)).foregroundStyle(DieterTheme.shell)
                    .padding(.leading, 6)
            }
        }
        .lineLimit(1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Folder path")
        .accessibilityIdentifier("files.breadcrumb")
    }

    private func breadcrumbSegment(_ title: String, path: String, current: Bool) -> some View {
        Button {
            Task { await model.navigateFiles(to: path) }
        } label: {
            Text(title).font(.system(size: 12, weight: current ? .semibold : .regular))
                .foregroundStyle(current ? DieterTheme.text : DieterTheme.subtle)
                .truncationMode(.middle)
                .padding(.horizontal, 4).padding(.vertical, 2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(current || model.fileNavigationLoading)
        .contextMenu {
            Button("Copy Path") { FileExternalActions.copy(path.isEmpty ? model.projectPath : path) }
        }
    }

    private func unsupportedDocument(_ document: Dieter_V1_FileDocument) -> some View {
        ContentUnavailableView(
            "No preview available", systemImage: "doc.badge.ellipsis",
            description: Text("\(SharedRules.shared.bytes(count: document.size)) • \(document.mimeType)"))
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
        let local = store.isLocalMachine(model.target.endpointID)
        return
            "\(model.documentKey):\(model.fileScopeGeneration):\(model.projectPath):\(model.isLive):\(store.phase.isConnected):\(model.fileDocument?.revision ?? ""):\(local)"
    }

    private var preparedExternalActions: FileExternalActions? {
        externalPreparedKey == externalActionKey ? externalActions : nil
    }

    private var verifiedLocalTransport: Bool {
        model.isLive && store.isLocalMachine(model.target.endpointID)
    }

    private func prepareExternalActions() async {
        let key = externalActionKey
        externalActions = nil
        externalRootPath = nil
        guard let document = model.fileDocument else { return }
        let target = model.target
        var rootPath: String? = target.conversationID.isEmpty ? model.projectPath : nil
        if !target.conversationID.isEmpty,
            let workspace = try? await store.conversationWorkspace(cardID: target.conversationID),
            workspace.cardID == target.conversationID, workspace.projectID == target.projectID
        {
            rootPath = workspace.path
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
        return HStack(spacing: 4) {
            Button {
                if actions?.fileURL != nil { openExternally() } else { download(document) }
            } label: {
                Label(
                    actions?.fileURL == nil ? "Save As…" : (editorSession.isDirty ? "Open Saved" : "Open"),
                    systemImage: actions?.fileURL == nil ? "square.and.arrow.down" : "arrow.up.forward.app")
            }
            .buttonStyle(DieterBarButtonStyle(size: 28))
            .help(actions?.fileURL == nil ? "Save a local copy of this file" : "Open the saved file in its default app")
            .accessibilityIdentifier("files.open-menu")
            .smokeTarget("files.open-menu")
            openOptionsMenu(document, actions: actions)
        }
    }

    private func openOptionsMenu(_ document: Dieter_V1_FileDocument, actions: FileExternalActions?) -> some View {
        Menu {
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
                Divider()
            } else {
                Text(actions?.unavailableReason ?? "Preparing file actions…")
            }
            Button("Save As…", systemImage: "square.and.arrow.down") { download(document) }
                .accessibilityIdentifier("files.save-as")
            Divider()
            Button("Copy File Name", systemImage: "doc.on.doc") { FileExternalActions.copy(document.name) }
            Button("Copy Path") { FileExternalActions.copy(actions?.displayPath ?? document.path) }
        } label: {
            DieterMenuLabel(symbol: "chevron.down", size: 28)
        }
        .dieterMenuChrome(.circle)
        .help("More file actions")
        .accessibilityLabel("More file actions")
    }

    private func currentExternalActions() -> FileExternalActions {
        FileExternalActions.resolve(
            verifiedLocal: verifiedLocalTransport && preparedExternalActions != nil,
            rootPath: preparedExternalActions != nil ? externalRootPath : nil,
            relativePath: model.fileDocument?.path ?? "")
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
        Task { await model.navigateToParent() }
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
                .buttonStyle(DieterBarButtonStyle(shape: .circle, size: 28)).disabled(zoom <= 0.5).help("Zoom out")
                Button("Fit") { zoom = 1 }.buttonStyle(DieterBarButtonStyle(size: 28))
                Button {
                    zoom = min(4, zoom + 0.25)
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(DieterBarButtonStyle(shape: .circle, size: 28)).disabled(zoom >= 4).help("Zoom in")
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
