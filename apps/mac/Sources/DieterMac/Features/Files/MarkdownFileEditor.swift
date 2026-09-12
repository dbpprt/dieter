import SwiftUI

enum MarkdownFileEditorMode: String, CaseIterable {
    case edit, source

    var title: String { rawValue.capitalized }
    var layout: MarkdownEditorLayout {
        switch self {
        case .edit: .preview
        case .source: .source
        }
    }
    var symbol: String {
        self == .edit ? "square.and.pencil" : layout.symbol
    }
}

/// Rich text and source share one document buffer. Retaining both native hosts
/// preserves selection and undo history when switching between them.
struct MarkdownFileEditor: View {
    let session: FileEditorSession
    let documentKey: String
    let text: String
    let filename: String
    var active = true
    var revealID: UUID?
    @State private var sourceActivated = false
    @State private var mode = MarkdownFileEditorMode.edit
    @State private var scrollCoordinator = MarkdownScrollCoordinator()
    @Environment(\.colorScheme) private var colorScheme

    private var editing: Bool { mode == .edit }
    private var showingSource: Bool { mode == .source }
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
                .smokeTarget("files.markdown.layout.\(documentKey)")
                Spacer(minLength: 0)
            }
            .controlSize(.small)
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(DieterTheme.sidebar)
            .overlay(alignment: .bottom) { Divider() }
            MarkdownEditorSplitView(
                source: AnyView(sourcePane.environment(\.colorScheme, colorScheme)),
                preview: AnyView(richTextPane.environment(\.colorScheme, colorScheme)), layout: layout,
                scrollCoordinator: scrollCoordinator, richEditing: editing
            )
            .accessibilityIdentifier("files.markdown.split")
            .smokeTarget("files.markdown.split")
        }
        .onChange(of: revealID) { _, _ in mode = .edit }
        .onChange(of: mode) { _, _ in
            if showingSource { sourceActivated = true }
        }
    }

    private var sourcePane: some View {
        VStack(spacing: 0) {
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

    private var richTextPane: some View {
        NativeMarkdownEditor(
            session: session, documentKey: documentKey, active: editing && active,
            scrollCoordinator: scrollCoordinator
        )
        .allowsHitTesting(editing)
        .accessibilityHidden(!editing)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
