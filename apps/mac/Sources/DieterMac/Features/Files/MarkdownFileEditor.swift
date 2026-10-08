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
    /// The mode picker's fixed width; its two segments split it evenly.
    static let pickerWidth: CGFloat = 200
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
                DieterSegmentedPicker(
                    title: "Markdown mode", selection: $mode, options: MarkdownFileEditorMode.allCases,
                    fillsWidth: true
                ) { option in
                    Label(option.title, systemImage: option.symbol)
                }
                .frame(width: MarkdownFileEditorMode.pickerWidth)
                .accessibilityIdentifier("files.markdown.layout")
                .smokeTarget("files.markdown.layout")
                .smokeTarget("files.markdown.layout.\(documentKey)")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .overlay(alignment: .bottom) { Rectangle().fill(DieterTheme.hairline).frame(height: 1) }
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
