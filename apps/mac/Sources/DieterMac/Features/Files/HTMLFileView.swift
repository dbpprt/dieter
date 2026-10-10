import AppKit
import SharedCore
import SwiftUI

/// An HTML document, such as a Claude Design standalone export: a sandboxed
/// preview of the current text or its source in the editor. The preview reads
/// only the workspace's files through the core and never reaches the network.
struct HTMLFileView: View {
    let session: FileEditorSession
    let documentKey: String
    let text: String
    let filename: String
    /// The document's workspace-relative path; relative references resolve against its folder.
    let path: String
    let read: HTMLPreviewRead
    var active = true
    var editable = true
    var requestedLine: Int?
    @State private var mode = HTMLFileMode.preview

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                DieterSegmentedPicker(
                    title: "HTML mode", selection: $mode, options: HTMLFileMode.allCases, fillsWidth: true
                ) { option in
                    Label(option.rawValue, systemImage: option.symbol)
                }
                .frame(width: 220)
                .accessibilityIdentifier("files.html.mode")
                .smokeTarget("files.html.mode")
                Spacer()
                if mode == .preview {
                    Text("Offline preview").font(.caption).foregroundStyle(DieterTheme.tertiary)
                        .help("Scripts run, but the preview loads only this workspace's files.")
                }
            }
            .padding(.horizontal, 12).frame(height: 38)
            Rectangle().fill(DieterTheme.hairline).frame(height: 1)
            switch mode {
            case .preview:
                HTMLPreviewView(
                    path: path, text: session.documentKey == documentKey ? session.currentText() : text, read: read
                )
                .accessibilityIdentifier("files.html.preview")
            case .source:
                SyntaxHighlightedEditor(
                    session: session, documentKey: documentKey, text: text, filename: filename,
                    active: active, editable: editable, requestedLine: requestedLine
                )
                .accessibilityIdentifier("files.html.source")
            }
        }
        .onChange(of: requestedLine) { _, line in if line != nil { mode = .source } }
    }
}

enum HTMLFileMode: String, CaseIterable, Hashable {
    case preview = "Preview"
    case source = "Source"

    var symbol: String {
        switch self {
        case .preview: "eye"
        case .source: "chevron.left.forwardslash.chevron.right"
        }
    }
}

/// Hosts one document's sandboxed preview; a new path starts a new preview.
struct HTMLPreviewView: NSViewRepresentable {
    let path: String
    let text: String
    let read: HTMLPreviewRead

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        update(container, context: context)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        update(container, context: context)
    }

    private func update(_ container: NSView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.controller?.documentPath != path {
            coordinator.controller?.webView.removeFromSuperview()
            let controller = HTMLPreviewController(
                documentPath: path, text: text, read: read, openExternally: { NSWorkspace.shared.open($0) })
            coordinator.controller = controller
            coordinator.loadedText = nil
            let view = controller.webView
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                view.topAnchor.constraint(equalTo: container.topAnchor),
                view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }
        if coordinator.loadedText != text {
            coordinator.loadedText = text
            coordinator.controller?.load(text: text)
        }
    }

    @MainActor final class Coordinator {
        var controller: HTMLPreviewController?
        var loadedText: String?
    }
}
