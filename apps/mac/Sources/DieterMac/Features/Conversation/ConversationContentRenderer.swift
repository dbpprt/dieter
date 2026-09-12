import AppKit
import DieterAPI
import DieterCore
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// File rendering stays native and uses the pane's own workspace-scoped editor
/// session. Web content has a separate renderer and never enters this editor.
struct ConversationContentRenderer: View {
    let files: FilesModel
    var line: Int?
    var navigationID: UUID?

    var body: some View {
        Group {
            if let document = files.fileDocument {
                documentView(document)
                    .id(files.documentKey)
                    .id(ObjectIdentifier(files.fileEditorSession))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("conversation.content.renderer")
    }

    @ViewBuilder
    private func documentView(_ document: Dieter_V1_FileDocument) -> some View {
        switch ConversationFileRendererKind(document: document) {
        case .markdown:
            MarkdownFileEditor(
                session: files.fileEditorSession, documentKey: files.documentKey,
                text: document.content, filename: document.name
            )
        case .text:
            SyntaxHighlightedEditor(
                session: files.fileEditorSession, documentKey: files.documentKey,
                text: document.content, filename: document.name,
                editable: false, requestedLine: line
            )
            .id(navigationID)
            .accessibilityIdentifier("conversation.content.code")
        case .image:
            ConversationImageDocumentRenderer(data: bytes(document)) {
                unsupported(document, title: "This image could not be displayed")
            }
        case .pdf:
            ConversationPDFDocumentRenderer(data: bytes(document)) {
                unsupported(document, title: "This PDF could not be displayed")
            }
        case .unsupported:
            unsupported(document, title: "No preview available")
        }
    }

    private func bytes(_ document: Dieter_V1_FileDocument) -> Data {
        ProjectFilePresentation.bytes(binary: document.binary, content: document.content, data: document.data)
    }

    private func unsupported(_ document: Dieter_V1_FileDocument, title: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: "doc.badge.ellipsis")
        } description: {
            Text("Save a copy of \(document.name) to open it in another app.")
        } actions: {
            Button("Save a Copy…", systemImage: "square.and.arrow.down") { saveCopy(document) }
                .accessibilityIdentifier("conversation.content.download")
        }
    }

    private func saveCopy(_ document: Dieter_V1_FileDocument) {
        let panel = NSSavePanel()
        panel.title = "Save a Copy"
        panel.nameFieldStringValue = document.name
        panel.canCreateDirectories = true
        if let type = UTType(filenameExtension: (document.name as NSString).pathExtension) {
            panel.allowedContentTypes = [type]
        }
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do { try bytes(document).write(to: destination, options: .atomic) } catch {
            files.fileError = "Could not save \(document.name): \(error.localizedDescription)"
        }
    }
}

enum ConversationFileRendererKind: Equatable {
    case markdown, text, image, pdf, unsupported

    init(document: Dieter_V1_FileDocument) {
        let mime = document.mimeType.split(separator: ";", maxSplits: 1).first.map(String.init)?.lowercased() ?? ""
        if (document.name as NSString).pathExtension.lowercased() == "pdf" || mime == "application/pdf" {
            self = .pdf
        } else if ProjectFilePresentation.isImage(filename: document.name, mimeType: mime) {
            self = .image
        } else if document.binary {
            self = .unsupported
        } else if ProjectFileLanguage.detect(filename: document.name) == .markdown {
            self = .markdown
        } else {
            self = .text
        }
    }
}

/// Decode a changed payload once, keeping media and its viewport alive while
/// unrelated conversation updates re-evaluate the surrounding SwiftUI tree.
private struct ConversationImageDocumentRenderer<Unavailable: View>: View {
    let data: Data
    let unavailable: () -> Unavailable
    @State private var image: NSImage?
    @State private var loaded = false

    var body: some View {
        Group {
            if let image {
                ConversationImageRenderer(image: image)
            } else if loaded {
                unavailable()
            } else {
                ProgressView("Loading image…")
            }
        }
        .onChange(of: data, initial: true) { _, bytes in
            image = NSImage(data: bytes)
            loaded = true
        }
    }
}

private struct ConversationPDFDocumentRenderer<Unavailable: View>: View {
    let data: Data
    let unavailable: () -> Unavailable
    @State private var document: PDFDocument?
    @State private var loaded = false

    var body: some View {
        Group {
            if let document {
                ConversationPDFRenderer(document: document)
                    .accessibilityIdentifier("conversation.content.pdf")
            } else if loaded {
                unavailable()
            } else {
                ProgressView("Loading PDF…")
            }
        }
        .onChange(of: data, initial: true) { _, bytes in
            document = PDFDocument(data: bytes)
            loaded = true
        }
    }
}

private struct ConversationImageRenderer: View {
    let image: NSImage
    @State private var zoom: CGFloat = 1
    @GestureState private var magnification: CGFloat = 1

    private var pixelSize: CGSize {
        guard
            let representation = image.representations.max(by: {
                ($0.pixelsWide * $0.pixelsHigh) < ($1.pixelsWide * $1.pixelsHigh)
            }), representation.pixelsWide > 0, representation.pixelsHigh > 0
        else { return image.size }
        return CGSize(width: representation.pixelsWide, height: representation.pixelsHigh)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("\(Int(pixelSize.width)) × \(Int(pixelSize.height)) px")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("Zoom out", systemImage: "minus.magnifyingglass") { zoom = max(0.25, zoom / 1.25) }
                    .disabled(zoom <= 0.25)
                Button("Fit") { zoom = 1 }
                    .help("Fit image to the pane")
                Button("Zoom in", systemImage: "plus.magnifyingglass") { zoom = min(8, zoom * 1.25) }
                    .disabled(zoom >= 8)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .controlSize(.small)
            .font(.caption)
            .padding(.horizontal, 12)
            .frame(height: 34)
            Divider()
            GeometryReader { geometry in
                let fit = min(
                    1,
                    min(
                        max(1, geometry.size.width - 32) / max(1, pixelSize.width),
                        max(1, geometry.size.height - 32) / max(1, pixelSize.height))
                )
                let scale = fit * min(8, max(0.25, zoom * magnification))
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: pixelSize.width * scale, height: pixelSize.height * scale)
                        .padding(16)
                        .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
                }
                .gesture(
                    MagnifyGesture()
                        .updating($magnification) { value, state, _ in state = value.magnification }
                        .onEnded { value in zoom = min(8, max(0.25, zoom * value.magnification)) }
                )
            }
        }
        .accessibilityIdentifier("conversation.content.image")
    }
}

/// PDFKit owns text selection, search, scrolling and standard contextual zoom.
private struct ConversationPDFRenderer: NSViewRepresentable {
    let document: PDFDocument

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.document = document
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.backgroundColor = .clear
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== document {
            view.document = document
            view.autoScales = true
        }
    }
}
