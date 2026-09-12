import SwiftUI

enum MarkdownFileEditorMode: String, CaseIterable {
    case edit, split, source, preview

    var title: String { rawValue.capitalized }
    var layout: MarkdownEditorLayout {
        switch self {
        case .edit, .preview: .preview
        case .source: .source
        case .split: .split
        }
    }
    var symbol: String {
        self == .edit ? "square.and.pencil" : layout.symbol
    }
}

/// The editor retains its native buffer and undo history while the preview
/// receives a debounced snapshot of the current, including unsaved, document.
struct MarkdownFileEditor: View {
    let session: FileEditorSession
    let documentKey: String
    let text: String
    let filename: String
    var active = true
    var revealID: UUID?
    @State private var previewSource: String
    @State private var sourceActivated = false
    @State private var mode = MarkdownFileEditorMode.edit
    @State private var scrollCoordinator = MarkdownScrollCoordinator()
    @Environment(\.colorScheme) private var colorScheme

    private var editing: Bool { mode == .edit }
    private var showingSource: Bool { mode == .source || mode == .split }
    private var showingPreview: Bool { mode == .preview || mode == .split }
    private var layout: MarkdownEditorLayout { mode.layout }

    init(
        session: FileEditorSession, documentKey: String, text: String, filename: String, active: Bool = true,
        revealID: UUID? = nil
    ) {
        self.session = session
        self.documentKey = documentKey
        self.text = text
        self.filename = filename
        self.active = active
        self.revealID = revealID
        _previewSource = State(initialValue: session.documentKey == documentKey ? session.currentText() : text)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("Markdown mode", selection: $mode) {
                    ForEach(MarkdownFileEditorMode.allCases, id: \.self) { option in
                        Label(option.title, systemImage: option.symbol).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("files.markdown.layout")
                .smokeTarget("files.markdown.layout")
                Spacer(minLength: 0)
            }
            .controlSize(.small)
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(DieterTheme.sidebar)
            .overlay(alignment: .bottom) { Divider() }
            MarkdownEditorSplitView(
                source: AnyView(sourcePane.environment(\.colorScheme, colorScheme)),
                preview: AnyView(previewPane.environment(\.colorScheme, colorScheme)), layout: layout,
                scrollCoordinator: scrollCoordinator, richEditing: editing
            )
            .accessibilityIdentifier("files.markdown.split")
            .smokeTarget("files.markdown.split")
        }
        .onChange(of: revealID) { _, _ in mode = .edit }
        .onChange(of: mode) { _, _ in
            if showingSource { sourceActivated = true }
            if showingPreview {
                if session.documentKey == documentKey { previewSource = session.currentText() }
            }
        }
        .task(id: "\(session.revision):\(active)") {
            guard active, showingPreview else { return }
            do {
                try await DieterTaskSleep.milliseconds(180)
                guard !Task.isCancelled, active, showingPreview, session.documentKey == documentKey else { return }
                previewSource = session.currentText()
            } catch { /* A newer edit owns the next preview. */  }
        }
    }

    private var sourcePane: some View {
        VStack(spacing: 0) {
            if layout == .split { paneHeader("Source", symbol: "chevron.left.forwardslash.chevron.right") }
            if sourceActivated {
                SyntaxHighlightedEditor(
                    session: session, documentKey: documentKey, text: text, filename: filename,
                    active: showingSource && active
                )
                .accessibilityIdentifier("files.editor")
                .smokeTarget("files.markdown.source")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var previewPane: some View {
        VStack(spacing: 0) {
            if layout == .split { paneHeader(editing ? "Rich text" : "Preview", symbol: "doc.richtext") }
            ZStack {
                // A hidden WebKit document still lays out and resizes charts.
                // Only mount the read-only renderer while it is visible.
                if active && showingPreview {
                    MarkdownFilePreview(source: previewSource, scrollCoordinator: scrollCoordinator)
                        .accessibilityIdentifier("files.markdown.preview")
                        .smokeTarget("files.markdown.preview")
                }
                NativeMarkdownEditor(
                    session: session, documentKey: documentKey, active: editing && active,
                    scrollCoordinator: scrollCoordinator
                )
                .opacity(editing ? 1 : 0)
                .allowsHitTesting(editing)
                .accessibilityHidden(!editing)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func paneHeader(_ title: String, symbol: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
            Text(title)
            Spacer(minLength: 0)
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 29)
        .background(DieterTheme.sidebar)
        .overlay(alignment: .bottom) { Divider() }
    }
}
