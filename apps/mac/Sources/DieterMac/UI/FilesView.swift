import AppKit
import DieterAPI
import SwiftUI
import UniformTypeIdentifiers

struct FilesView: View {
    @Environment(DieterStore.self) private var store
    @State private var createPresented = false
    @State private var newPath = ""
    @State private var newDirectory = false
    @State private var movingEntry: Dieter_V1_FileEntry?
    @State private var moveDestination = ""

    var body: some View {
        @Bindable var store = store
        HSplitView {
            VStack(spacing: 0) {
                FluidPaneChrome(background: DieterTheme.sidebar, spacing: 9) {
                    HStack(spacing: 8) {
                        Button { Task { await store.navigateFilesBack() } } label: {
                            Image(systemName: "chevron.left")
                        }
                        .buttonStyle(DieterIconButtonStyle())
                        .disabled(!store.fileNavigation.canGoBack || store.fileNavigationLoading)
                        .help("Back")
                        .accessibilityLabel("Back")
                        .accessibilityIdentifier("files.back")
                        Button { Task { await store.navigateFilesForward() } } label: {
                            Image(systemName: "chevron.right")
                        }
                        .buttonStyle(DieterIconButtonStyle())
                        .disabled(!store.fileNavigation.canGoForward || store.fileNavigationLoading)
                        .help("Forward")
                        .accessibilityLabel("Forward")
                        .accessibilityIdentifier("files.forward")
                        PaneTitleBlock(
                            title: "Files",
                            subtitle: "\(store.files.count) item\(store.files.count == 1 ? "" : "s") · \(store.fileScopeCardID == nil ? (store.selectedProject?.name ?? "Project") : "Conversation workspace")",
                            symbol: "folder",
                            prominent: true
                        )
                        Menu {
                            Button("New file…") { newDirectory = false; createPresented = true }
                            Button("New folder…") { newDirectory = true; createPresented = true }
                            if store.fileScopeCardID != nil {
                                Divider()
                                Button("Return to project root") {
                                    store.fileScopeCardID = nil; store.filePath = ""; store.fileNavigation.reset(); store.fileDocument = nil
                                    Task { await store.loadFiles() }
                                }
                            }
                            Divider(); Toggle("Show hidden", isOn: $store.showHiddenFiles)
                        } label: { Image(systemName: "ellipsis.circle") }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().buttonStyle(DieterIconButtonStyle())
                        Button { Task { await store.loadFiles() } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(DieterIconButtonStyle()).disabled(store.fileNavigationLoading)
                    }
                } secondary: {
                    HStack(spacing: 8) {
                        Image(systemName: store.fileScopeCardID == nil ? (store.filePath.isEmpty ? "folder" : "folder.fill") : "point.3.connected.trianglepath.dotted").font(.system(size: 11)).foregroundStyle(DieterTheme.tertiary)
                        Text(store.filePath.isEmpty ? (store.fileScopeCardID == nil ? store.selectedProject?.path ?? "Project root" : "Workspace root · \(store.fileScopeCardID?.prefix(8) ?? "")") : store.filePath)
                            .font(.system(size: 11)).foregroundStyle(DieterTheme.tertiary).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        if store.showHiddenFiles { Text("Hidden files").font(.system(size: 10, weight: .semibold)).foregroundStyle(DieterTheme.shell) }
                    }
                }
                List {
                    if !store.filePath.isEmpty {
                        Button { navigateToParent() } label: {
                            Label("Parent Folder", systemImage: "arrow.turn.up.left")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(DieterTheme.subtle)
                                .frame(maxWidth: .infinity, minHeight: 29, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(store.fileNavigationLoading)
                        .listRowInsets(EdgeInsets(top: 1, leading: 10, bottom: 1, trailing: 10))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }
                    ForEach(store.files, id: \.path) { entry in
                        Button {
                            Task { if entry.kind == "directory" { await store.navigateFiles(to: entry.path) } else { await store.openFile(path: entry.path) } }
                        } label: {
                            HStack(spacing: 9) {
                                Image(systemName: entry.kind == "directory" ? "folder.fill" : symbol(entry.name))
                                    .foregroundStyle(entry.kind == "directory" ? DieterTheme.shell : DieterTheme.tertiary)
                                    .frame(width: 15)
                                Text(entry.name).lineLimit(1)
                                Spacer()
                                if entry.kind != "directory" {
                                    Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                                        .font(.caption2).foregroundStyle(DieterTheme.tertiary)
                                }
                            }
                            .font(.system(size: 12, weight: store.fileDocument?.path == entry.path ? .semibold : .regular))
                            .padding(.horizontal, 8).frame(minHeight: 30)
                            .background(store.fileDocument?.path == entry.path ? DieterTheme.selection : .clear, in: RoundedRectangle(cornerRadius: DieterMetrics.controlRadius, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(entry.kind == "directory" && store.fileNavigationLoading)
                        .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .contextMenu { Button("Move or rename…") { movingEntry = entry; moveDestination = entry.path }; Button("Delete", role: .destructive) { Task { await store.deleteFile(path: entry.path, recursive: entry.kind == "directory") } } }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }.frame(minWidth: 260, idealWidth: 340, maxWidth: 440).background(DieterTheme.sidebar)

            if let document = store.fileDocument {
                VStack(spacing: 0) {
                    FluidPaneChrome(background: DieterTheme.sidebar, spacing: 8) {
                        HStack(spacing: 9) {
                            PaneTitleBlock(title: document.name, subtitle: document.path, symbol: symbol(document.name))
                            if store.fileEditorText != document.content { StatusPill(text: "Edited", color: DieterTheme.amber) }
                            Button { download(document) } label: { Image(systemName: "arrow.down.to.line") }
                                .buttonStyle(DieterIconButtonStyle())
                                .help("Download (document.name)")
                                .accessibilityIdentifier("files.download")
                            Button("Save") { Task { await store.saveFile() } }.buttonStyle(DieterPrimaryButtonStyle()).keyboardShortcut("s", modifiers: .command).disabled(document.binary || store.fileEditorText == document.content)
                        }
                    } secondary: {
                        HStack(spacing: 8) {
                            Text(document.mimeType.isEmpty ? "Unknown type" : document.mimeType)
                            Text("·")
                            Text(ByteCountFormatter.string(fromByteCount: document.size, countStyle: .file))
                            Spacer()
                            if !document.binary { Text("Editable") }
                        }
                        .font(.system(size: 10)).foregroundStyle(DieterTheme.tertiary)
                    }
                    if let image = previewImage(document) {
                        ProjectImagePreview(image: image)
                    } else if document.binary {
                        ContentUnavailableView("Binary file", systemImage: "doc.badge.ellipsis", description: Text("\(ByteCountFormatter.string(fromByteCount: document.size, countStyle: .file)) • \(document.mimeType)"))
                    } else {
                        VStack(spacing: 0) {
                            SyntaxHighlightedEditor(text: $store.fileEditorText, filename: document.name)
                                .accessibilityIdentifier("files.editor")
                            HStack(spacing: 12) {
                                Text(ProjectFileLanguage.detect(filename: document.name).displayName)
                                Text("UTF-8")
                                Spacer()
                                Text("\(store.fileEditorText.components(separatedBy: .newlines).count) lines")
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
                        PaneTitleBlock(title: "File preview", subtitle: "Select a project file to inspect or edit", symbol: "doc.text")
                    }
                    ContentUnavailableView("Select a file", systemImage: "doc.text", description: Text("Browse and edit text files in the selected Git working tree."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await store.loadFiles() }
        .onChange(of: store.showHiddenFiles) { _, _ in Task { await store.loadFiles() } }
        .sheet(isPresented: $createPresented) {
            VStack(alignment: .leading, spacing: 14) { Text(newDirectory ? "New folder" : "New file").font(.title2.weight(.bold)); TextField(newDirectory ? "Folder path" : "File path", text: $newPath); HStack { Spacer(); Button("Cancel") { createPresented = false }; Button("Create") { Task { await store.createFile(path: joined(store.filePath, newPath), directory: newDirectory); newPath = ""; createPresented = false } }.buttonStyle(.borderedProminent).disabled(newPath.isEmpty) } }.padding(22).frame(width: 430)
        }
        .sheet(isPresented: Binding(get: { movingEntry != nil }, set: { if !$0 { movingEntry = nil } })) {
            if let entry = movingEntry {
                VStack(alignment: .leading, spacing: 14) { Text("Move or rename").font(.title2.weight(.bold)); Text(entry.path).font(.caption.monospaced()).foregroundStyle(.secondary); TextField("Destination path", text: $moveDestination); HStack { Spacer(); Button("Cancel") { movingEntry = nil }; Button("Move") { Task { await store.moveFile(source: entry.path, destination: moveDestination); movingEntry = nil } }.buttonStyle(.borderedProminent).disabled(moveDestination.isEmpty || moveDestination == entry.path) } }.padding(22).frame(width: 500)
            }
        }
    }

    private func symbol(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "gif", "webp"].contains(ext) ? "photo" : ["swift", "go", "kt", "js", "ts", "tsx", "json", "md", "yml", "yaml"].contains(ext) ? "chevron.left.forwardslash.chevron.right" : "doc"
    }

    private func previewImage(_ document: Dieter_V1_FileDocument) -> NSImage? {
        guard ProjectFilePresentation.isImage(filename: document.name, mimeType: document.mimeType) else { return nil }
        let bytes = ProjectFilePresentation.bytes(binary: document.binary, content: document.content, data: document.data)
        return NSImage(data: bytes)
    }

    private func download(_ document: Dieter_V1_FileDocument) {
        let panel = NSSavePanel()
        panel.title = "Download \(document.name)"
        panel.prompt = "Download"
        panel.nameFieldStringValue = document.name
        panel.canCreateDirectories = true
        let extensionName = (document.name as NSString).pathExtension
        if !extensionName.isEmpty, let contentType = UTType(filenameExtension: extensionName) {
            panel.allowedContentTypes = [contentType]
        }
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let bytes = ProjectFilePresentation.bytes(binary: document.binary, content: document.content, data: document.data)
        do {
            try bytes.write(to: destination, options: .atomic)
        } catch {
            store.errorMessage = "Could not download \(document.name): \(error.localizedDescription)"
        }
    }

    private func navigateToParent() {
        guard !store.filePath.isEmpty else { return }
        let parent = ProjectFileNavigation.parentPath(of: store.filePath)
        Task { await store.navigateFiles(to: parent) }
    }

    private func joined(_ base: String, _ path: String) -> String { base.isEmpty ? path : (base as NSString).appendingPathComponent(path) }
}

private struct ProjectImagePreview: View {
    let image: NSImage
    @State private var zoom: CGFloat = 1

    private var pixelSize: CGSize {
        guard let representation = image.representations.max(by: { ($0.pixelsWide * $0.pixelsHigh) < ($1.pixelsWide * $1.pixelsHigh) }),
              representation.pixelsWide > 0, representation.pixelsHigh > 0 else { return image.size }
        return CGSize(width: representation.pixelsWide, height: representation.pixelsHigh)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "photo")
                Text("\(Int(pixelSize.width)) × \(Int(pixelSize.height)) px")
                Spacer()
                Button { zoom = max(0.5, zoom - 0.25) } label: { Image(systemName: "minus") }
                    .buttonStyle(DieterIconButtonStyle()).disabled(zoom <= 0.5).help("Zoom out")
                Button("Fit") { zoom = 1 }.buttonStyle(.borderless).font(.caption)
                Button { zoom = min(4, zoom + 0.25) } label: { Image(systemName: "plus") }
                    .buttonStyle(DieterIconButtonStyle()).disabled(zoom >= 4).help("Zoom in")
            }
            .font(.system(size: 10, weight: .medium)).foregroundStyle(DieterTheme.subtle)
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(DieterTheme.sidebar)
            .overlay(alignment: .bottom) { Rectangle().fill(DieterTheme.border).frame(height: 1) }

            GeometryReader { geometry in
                let availableWidth = max(1, geometry.size.width - 48)
                let availableHeight = max(1, geometry.size.height - 48)
                let fitScale = min(1, min(availableWidth / max(1, pixelSize.width), availableHeight / max(1, pixelSize.height)))
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
