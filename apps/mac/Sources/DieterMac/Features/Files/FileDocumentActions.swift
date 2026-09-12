import AppKit
import DieterAPI
import SwiftUI
import UniformTypeIdentifiers

/// Shared document actions use the displayed editor's draft and its exact
/// workspace scope. Each local reveal resolves the path again at click time.
struct FileDocumentActions: View {
    @Bindable var files: FilesModel
    let identifierPrefix: String
    var active = true
    var compact = false
    let resolveExternalActions: @MainActor () -> FileExternalActions
    var reveal: @MainActor (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
    @State private var exportingMarkdown = false

    var body: some View {
        if let document = files.fileDocument {
            let actions = active ? resolveExternalActions() : nil
            let key = files.documentKey
            let session = files.fileEditorSession
            HStack(spacing: 10) {
                Button {
                    showInFinder()
                } label: {
                    if compact {
                        Image(systemName: "folder")
                    } else {
                        Label("Show in Finder", systemImage: "folder")
                    }
                }
                .disabled(!active || actions?.fileURL == nil)
                .help(actions?.unavailableReason ?? "Show in Finder")
                .accessibilityLabel("Show in Finder")
                .accessibilityIdentifier("\(identifierPrefix).show-in-finder")
                .smokeTarget("\(identifierPrefix).show-in-finder")

                if !document.binary, ProjectFileLanguage.detect(filename: document.name) == .markdown {
                    Menu {
                        Button("Export PDF…", systemImage: "doc.richtext") {
                            export(document, key: key, session: session, format: .pdf)
                        }
                        .accessibilityIdentifier("\(identifierPrefix).export.pdf")
                        Button("Export HTML…", systemImage: "chevron.left.forwardslash.chevron.right") {
                            export(document, key: key, session: session, format: .html)
                        }
                        .accessibilityIdentifier("\(identifierPrefix).export.html")
                        Divider()
                        Button("Save a Copy…", systemImage: "square.and.arrow.down") {
                            saveCopy(document, key: key, session: session)
                        }
                        .accessibilityIdentifier("\(identifierPrefix).save-copy")
                    } label: {
                        if compact { Text("Export") } else { Label("Export", systemImage: "square.and.arrow.up") }
                    }
                    .fixedSize()
                    .disabled(!active || exportingMarkdown || files.fileEditorSession.documentKey != files.documentKey)
                    .help("Export the current draft as PDF or HTML")
                    .accessibilityIdentifier("\(identifierPrefix).export-menu")
                    .smokeTarget("\(identifierPrefix).export-menu")
                } else if actions?.fileURL == nil {
                    Button {
                        saveCopy(document, key: key, session: session)
                    } label: {
                        if compact {
                            Image(systemName: "square.and.arrow.down")
                        } else {
                            Label("Save a Copy…", systemImage: "square.and.arrow.down")
                        }
                    }
                    .disabled(!active)
                    .help("Save a local copy of this file")
                    .accessibilityLabel("Save a Copy…")
                    .accessibilityIdentifier("\(identifierPrefix).save-copy")
                    .smokeTarget("\(identifierPrefix).save-copy")
                }
                if exportingMarkdown {
                    ProgressView().controlSize(.small).accessibilityLabel("Exporting Markdown")
                }
            }
            .buttonStyle(.borderless).controlSize(.small).font(.caption)
        }
    }

    func showInFinder() {
        guard active else { return }
        let current = resolveExternalActions()
        guard let url = current.fileURL else {
            files.fileError = current.unavailableReason
            return
        }
        reveal(url)
    }

    private func saveCopy(_ document: Dieter_V1_FileDocument, key: String, session: FileEditorSession) {
        guard active, files.documentKey == key, files.fileEditorSession === session,
            files.fileDocument?.path == document.path
        else { return }
        let bytes = FileExternalActions.exportBytes(
            document: document, session: session, documentKey: key)
        let panel = NSSavePanel()
        panel.title = "Save a Copy"
        panel.nameFieldStringValue = document.name
        panel.canCreateDirectories = true
        if let type = UTType(filenameExtension: (document.name as NSString).pathExtension) {
            panel.allowedContentTypes = [type]
        }
        let window = NSApp.keyWindow
        Task { @MainActor in
            guard let destination = await destination(for: panel, window: window) else { return }
            do { try bytes.write(to: destination, options: .atomic) } catch {
                if files.documentKey == key, files.fileEditorSession === session {
                    files.fileError = "Could not save a copy of \(document.name): \(error.localizedDescription)"
                }
            }
        }
    }

    private func export(
        _ document: Dieter_V1_FileDocument, key: String, session: FileEditorSession, format: MarkdownFileExport.Format
    ) {
        guard active, !exportingMarkdown, files.documentKey == key, files.fileEditorSession === session,
            files.fileDocument?.path == document.path
        else { return }
        guard
            let snapshot = FileExternalActions.markdownExportDocument(
                document: document, session: session, documentKey: key)
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
        let window = NSApp.keyWindow
        exportingMarkdown = true
        Task { @MainActor in
            defer { exportingMarkdown = false }
            guard let destination = await destination(for: panel, window: window) else { return }
            do {
                let data = try await MarkdownFileExport.data(for: snapshot, format: format)
                try data.write(to: destination, options: .atomic)
            } catch {
                if files.documentKey == key, files.fileEditorSession === session {
                    files.fileError = "Could not export \(document.name): \(error.localizedDescription)"
                }
            }
        }
    }

    private func destination(for panel: NSSavePanel, window: NSWindow?) async -> URL? {
        #if DIETER_UI_SMOKE
            ConversationFileActionsUISmoke.configureSavePanel?(panel, window)
        #endif
        let response = await withCheckedContinuation { continuation in
            if let window {
                panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            } else {
                panel.begin { continuation.resume(returning: $0) }
            }
        }
        return response == .OK ? panel.url : nil
    }
}
