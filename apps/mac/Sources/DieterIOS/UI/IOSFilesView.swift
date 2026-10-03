#if os(iOS)
    import DieterAPI
    import DieterShared
    import Observation
    import PDFKit
    import SharedCore
    import SwiftUI
    import UIKit

    /// The files sheet's editor buffer: the text being edited, kept apart from
    /// the surface so a large document is copied only when it opens or saves.
    @MainActor
    @Observable
    final class IOSFileEditorBuffer: FileEditorBuffer {
        private(set) var documentKey = ""
        private(set) var isDirty = false
        /// Advances with every edit and every prepared document.
        @ObservationIgnored private(set) var revision = 0
        /// Advances when the text is replaced from outside the editor, so the
        /// editor shows the new text.
        private(set) var loadRevision = 0
        @ObservationIgnored private(set) var text = ""

        init() {}

        func prepare(documentKey: String, text: String) {
            guard self.documentKey != documentKey || (!isDirty && self.text != text) else { return }
            self.documentKey = documentKey
            self.text = text
            isDirty = false
            revision &+= 1
            loadRevision &+= 1
        }

        /// The person changed the text in the editor.
        func edit(_ text: String) {
            guard text != self.text else { return }
            self.text = text
            if !isDirty { isDirty = true }
            revision &+= 1
        }

        func markSaved(documentKey: String, submittedText: String, editRevision: Int) {
            // A newer edit stays unsaved.
            guard self.documentKey == documentKey, revision == editRevision, text == submittedText else { return }
            isDirty = false
        }

        func currentText() -> String { text }
    }

    /// One files sheet's surface, with the editor buffer above.
    typealias IOSFilesModel = FilesSurfaceModel<IOSFileEditorBuffer>

    /// A conversation's or project's files on the machine that holds them:
    /// browse folders, read text, images, and PDFs, and edit text files. The
    /// shared core lists, reads, and saves; each sheet owns its own surface.
    struct IOSFilesView: View {
        @Environment(\.dismiss) private var dismiss
        @Environment(IOSAppModel.self) private var app
        let scope: IOSFileScope
        @State private var model = IOSFilesModel(scope: "ios-files-\(UUID().uuidString.lowercased())")
        @State private var pendingExit: FileExit?
        @State private var creating: CreateKind?
        @State private var newName = ""
        @State private var moving: Dieter_V1_FileEntry?
        @State private var moveDestination = ""
        @State private var deleting: Dieter_V1_FileEntry?

        private enum FileExit { case back, dismiss }
        private enum CreateKind: Identifiable {
            case file, folder
            var id: Self { self }
        }

        private var buffer: IOSFileEditorBuffer { model.fileEditorSession }
        private var machine: ClientMachineEntry? { app.machine(scope.machineID) }
        private var live: Bool { machine?.available == true }
        private var document: Dieter_V1_FileDocument? { model.fileDocument }
        /// A document is open, or opening.
        private var documentShown: Bool { document != nil || !model.selectedFilePath.isEmpty }
        private var dirty: Bool { document != nil && buffer.isDirty }

        var body: some View {
            @Bindable var model = model
            NavigationStack {
                content
                    .safeAreaInset(edge: .top, spacing: 0) { header }
                    .navigationTitle(title)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { toolbar }
                    .confirmationDialog(
                        "Save changes to this file?",
                        isPresented: Binding(get: { pendingExit != nil }, set: { if !$0 { pendingExit = nil } }),
                        titleVisibility: .visible
                    ) {
                        Button("Save Changes") {
                            Task { if await save() { finishExit() } }
                        }
                        .disabled(!live)
                        Button("Discard Changes", role: .destructive) {
                            self.model.fileEditorSession = IOSFileEditorBuffer()
                            finishExit()
                        }
                        Button("Keep Editing", role: .cancel) { pendingExit = nil }
                    } message: {
                        Text("Your changes have not been saved on \(scope.title).")
                    }
                    .alert(
                        creating == .folder ? "New folder" : "New file",
                        isPresented: Binding(get: { creating != nil }, set: { if !$0 { creating = nil } })
                    ) {
                        TextField(creating == .folder ? "Folder name" : "File name", text: $newName)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("ios.files.create-name")
                        Button("Cancel", role: .cancel) { newName = "" }
                        Button("Create") {
                            let name = newName, directory = creating == .folder
                            newName = ""
                            Task { await self.model.createFile(name: name, directory: directory) }
                        }
                        .accessibilityIdentifier("ios.files.create-confirm")
                    } message: {
                        Text(model.filePath.isEmpty ? "In \(scope.title)" : "In \(model.filePath)")
                    }
                    .alert(
                        "Move or rename",
                        isPresented: Binding(get: { moving != nil }, set: { if !$0 { moving = nil } })
                    ) {
                        TextField("Destination path", text: $moveDestination)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("Cancel", role: .cancel) { moving = nil }
                        Button("Move") {
                            guard let source = moving?.path else { return }
                            let destination = moveDestination
                            moving = nil
                            Task { await self.model.moveFile(source: source, destination: destination) }
                        }
                    } message: {
                        Text(moving?.path ?? "")
                    }
                    .confirmationDialog(
                        "Delete \(deleting?.name ?? "")?",
                        isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                        titleVisibility: .visible
                    ) {
                        if let entry = deleting {
                            Button("Delete", role: .destructive) {
                                deleting = nil
                                Task {
                                    await self.model.deleteFile(
                                        path: entry.path, recursive: entry.kind == "directory")
                                }
                            }
                        }
                        Button("Cancel", role: .cancel) { deleting = nil }
                    } message: {
                        Text("This removes it from the working tree on \(machine?.name ?? "its machine").")
                    }
                    .interactiveDismissDisabled(dirty || model.saving)
            }
            .accessibilityIdentifier("ios.files")
            .task {
                model.projectName = scope.title
                model.isLive = live
                model.fileScopeCardID = scope.cardID.isEmpty ? nil : scope.cardID
                model.bind(
                    target: WorkspaceTarget(
                        endpointID: IOSAppModel.endpointID(daemonID: scope.machineID), projectID: scope.projectID,
                        conversationID: scope.cardID, checkoutID: scope.checkoutID),
                    core: app.core)
                guard await model.loadFiles(), !scope.openPath.isEmpty else { return }
                await model.openFile(path: scope.openPath)
            }
            .onChange(of: live) { _, live in model.isLive = live }
        }

        private var title: String {
            if let document { return document.name }
            if !model.selectedFilePath.isEmpty { return (model.selectedFilePath as NSString).lastPathComponent }
            return model.filePath.isEmpty ? "Files" : (model.filePath as NSString).lastPathComponent
        }

        // MARK: - Header

        private var header: some View {
            VStack(alignment: .leading, spacing: 4) {
                Text(document?.path ?? (model.filePath.isEmpty ? scope.title : model.filePath))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("ios.files.path")
                if let document {
                    Text(
                        [model.typeLabel, SharedRules.shared.bytes(count: document.size), model.languageName]
                            .filter { !$0.isEmpty }.joined(separator: " · ")
                    )
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .accessibilityIdentifier("ios.files.document-details")
                }
                if !live {
                    Label(
                        machine.map { $0.unavailableMessage.isEmpty ? $0.detail : $0.unavailableMessage }
                            ?? "This machine is not available. Your edits stay here until you close the file.",
                        systemImage: "wifi.slash"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("ios.files.unavailable")
                }
                if model.showHiddenFiles, document == nil {
                    Text("Showing hidden files").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
        }

        // MARK: - Toolbar

        @ToolbarContentBuilder
        private var toolbar: some ToolbarContent {
            ToolbarItem(placement: .topBarLeading) {
                if documentShown || !model.filePath.isEmpty {
                    Button("Back", systemImage: "chevron.left") { requestExit(.back) }
                        .disabled(model.fileNavigationLoading || model.saving)
                        .accessibilityIdentifier("ios.files.back")
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let document, editable(document) {
                    Button {
                        Task { await save() }
                    } label: {
                        if model.saving { ProgressView() } else { Text("Save").fontWeight(.semibold) }
                    }
                    .disabled(!buffer.isDirty || !live || model.saving)
                    .accessibilityIdentifier("ios.files.save")
                }
                moreMenu
                Button("Done") { requestExit(.dismiss) }
                    .disabled(model.saving)
                    .accessibilityIdentifier("ios.files.done")
            }
        }

        private var moreMenu: some View {
            @Bindable var model = model
            return Menu("More", systemImage: "ellipsis.circle") {
                if let document {
                    Button("Move or rename…", systemImage: "folder") {
                        moving = entry(for: document)
                        moveDestination = document.path
                    }
                    .disabled(!live || model.saving)
                    Button("Delete…", systemImage: "trash", role: .destructive) { deleting = entry(for: document) }
                        .disabled(!live || model.saving)
                } else {
                    Button("New file…", systemImage: "doc.badge.plus") { creating = .file }
                        .disabled(!live)
                        .accessibilityIdentifier("ios.files.new-file")
                    Button("New folder…", systemImage: "folder.badge.plus") { creating = .folder }
                        .disabled(!live)
                    Toggle("Show hidden files", isOn: $model.showHiddenFiles)
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.loadFiles() } }
                        .disabled(model.fileNavigationLoading)
                }
            }
            .accessibilityIdentifier("ios.files.more")
        }

        private func entry(for document: Dieter_V1_FileDocument) -> Dieter_V1_FileEntry {
            .with {
                $0.path = document.path
                $0.name = document.name
                $0.kind = "file"
            }
        }

        // MARK: - Content

        @ViewBuilder
        private var content: some View {
            if let document {
                documentContent(document)
            } else if !model.selectedFilePath.isEmpty {
                documentFeedback
            } else if model.filesLoading, model.files.isEmpty {
                ProgressView("Loading files…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                listing
            }
        }

        private var listing: some View {
            List {
                ForEach(model.files, id: \.path) { entry in
                    IOSFileRow(entry: entry) {
                        Task {
                            if entry.kind == "directory" {
                                await model.navigateFiles(to: entry.path)
                            } else {
                                await model.openFile(path: entry.path)
                            }
                        }
                    }
                    .disabled(entry.kind == "directory" && model.fileNavigationLoading)
                    .contextMenu {
                        Button("Move or rename…", systemImage: "folder") {
                            moving = entry
                            moveDestination = entry.path
                        }
                        .disabled(!live)
                        Button("Delete…", systemImage: "trash", role: .destructive) { deleting = entry }
                            .disabled(!live)
                    }
                }
            }
            .listStyle(.plain)
            .overlay {
                if let error = model.filesError {
                    ContentUnavailableView {
                        Label("Couldn’t load files", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Try again") { Task { await model.loadFiles() } }
                            .accessibilityIdentifier("ios.files.retry")
                    }
                } else if model.files.isEmpty, !model.filesLoading {
                    ContentUnavailableView("Empty folder", systemImage: "folder")
                }
            }
            .refreshable { await model.loadFiles() }
            .accessibilityIdentifier("ios.files.list")
        }

        @ViewBuilder
        private var documentFeedback: some View {
            if let error = model.fileError {
                ContentUnavailableView {
                    Label("Couldn’t open the file", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try again") { Task { await model.openFile(path: model.selectedFilePath) } }
                }
            } else {
                ProgressView("Opening \((model.selectedFilePath as NSString).lastPathComponent)…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }

        private func renderer(_ document: Dieter_V1_FileDocument) -> ClientFileRenderer {
            ClientFileRenderer(
                rawValue: Int(
                    SharedRules.shared.fileRenderer(
                        path: document.name, mimeType: document.mimeType, binary: document.binary))) ?? .unsupported
        }

        private func editable(_ document: Dieter_V1_FileDocument) -> Bool {
            let renderer = renderer(document)
            return !document.binary && (renderer == .text || renderer == .markdown)
        }

        @ViewBuilder
        private func documentContent(_ document: Dieter_V1_FileDocument) -> some View {
            VStack(spacing: 0) {
                if model.conflict {
                    HStack(spacing: 10) {
                        Label(
                            model.fileError ?? "This file changed on disk.",
                            systemImage: "exclamationmark.arrow.triangle.2.circlepath"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                        Spacer(minLength: 8)
                        Button("Reload") { Task { await model.reloadDocument() } }
                            .font(.caption.weight(.semibold))
                            .disabled(!live || model.saving)
                            .accessibilityIdentifier("ios.files.reload")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.orange.opacity(0.1))
                } else if let error = model.fileError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .accessibilityIdentifier("ios.files.error")
                }
                switch renderer(document) {
                case .image:
                    IOSFileImagePreview(document: document)
                case .pdf:
                    IOSFilePDFPreview(data: document.binary ? document.data : Data(document.content.utf8))
                case .markdown, .text:
                    IOSSourceEditor(
                        buffer: buffer, documentKey: buffer.documentKey, loadRevision: buffer.loadRevision,
                        path: document.path, editable: !model.saving)
                default:
                    ContentUnavailableView(
                        "No preview available", systemImage: "doc",
                        description: Text(
                            "\(document.name) · \(model.typeLabel) · \(SharedRules.shared.bytes(count: document.size))"
                        ))
                }
            }
        }

        // MARK: - Actions

        @discardableResult
        private func save() async -> Bool {
            guard document != nil else { return false }
            if !buffer.isDirty { return true }
            hideKeyboard()
            return await model.saveFile(content: buffer.currentText()) != nil
        }

        private func requestExit(_ exit: FileExit) {
            pendingExit = exit
            if dirty {
                hideKeyboard()
            } else {
                finishExit()
            }
        }

        private func finishExit() {
            guard let exit = pendingExit else { return }
            pendingExit = nil
            switch exit {
            case .dismiss:
                dismiss()
            case .back:
                Task {
                    if documentShown {
                        await model.closeDocument()
                    } else {
                        await model.navigateToParent()
                    }
                }
            }
        }

        private func hideKeyboard() {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
    }

    /// A folder or file in the listing, with the core's icon kind.
    private struct IOSFileRow: View {
        let entry: Dieter_V1_FileEntry
        let open: () -> Void

        private var directory: Bool { entry.kind == "directory" }

        var body: some View {
            Button(action: open) {
                HStack(spacing: 12) {
                    Image(systemName: Self.symbol(name: entry.name, directory: directory))
                        .foregroundStyle(directory ? Color.accentColor : .secondary)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.name).foregroundStyle(.primary).lineLimit(2)
                        if !directory {
                            Text(SharedRules.shared.bytes(count: entry.size))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            .accessibilityIdentifier("ios.files.entry.\(entry.path)")
        }

        /// The SF Symbol of the core's icon kind for `name`.
        static func symbol(name: String, directory: Bool) -> String {
            let kind = ClientFileIconKind(
                rawValue: Int(SharedRules.shared.fileIconKind(name: name, directory: directory)))
            switch kind {
            case .directory: return "folder.fill"
            case .image: return "photo"
            case .markdown: return "doc.richtext"
            case .code: return "chevron.left.forwardslash.chevron.right"
            default: return "doc.text"
            }
        }
    }

    // MARK: - Previews

    /// An image file, fitted to the sheet and zoomable.
    private struct IOSFileImagePreview: View {
        let document: Dieter_V1_FileDocument
        @State private var image: UIImage?
        @State private var decoded = false
        @State private var scale: CGFloat = 1
        @GestureState private var magnification: CGFloat = 1

        var body: some View {
            Group {
                if let image {
                    ScrollView([.horizontal, .vertical]) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 1000)
                            .scaleEffect(min(6, max(1, scale * magnification)))
                            .padding(12)
                    }
                    .gesture(
                        MagnificationGesture()
                            .updating($magnification) { value, state, _ in state = value }
                            .onEnded { value in scale = min(6, max(1, scale * value)) }
                    )
                    .onTapGesture(count: 2) { withAnimation { scale = scale > 1 ? 1 : 2 } }
                    .accessibilityElement()
                    .accessibilityLabel(document.name)
                    .accessibilityAddTraits(.isImage)
                    .accessibilityIdentifier("ios.files.image")
                } else if decoded {
                    ContentUnavailableView(
                        "No preview available", systemImage: "photo",
                        description: Text("\(document.name) · \(SharedRules.shared.bytes(count: document.size))"))
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .task(id: document.path + ":" + document.revision) {
                let bytes = document.binary ? document.data : Data(document.content.utf8)
                let decodedImage = await Task.detached(priority: .userInitiated) { UIImage(data: bytes) }.value
                image = decodedImage
                decoded = true
            }
        }
    }

    /// A PDF file in PDFKit's view.
    private struct IOSFilePDFPreview: UIViewRepresentable {
        let data: Data

        final class Coordinator {
            var data: Data?
        }

        func makeCoordinator() -> Coordinator { Coordinator() }

        func makeUIView(context: Context) -> PDFView {
            let view = PDFView()
            view.autoScales = true
            view.displayMode = .singlePageContinuous
            view.accessibilityIdentifier = "ios.files.pdf"
            return view
        }

        func updateUIView(_ view: PDFView, context: Context) {
            guard context.coordinator.data != data else { return }
            context.coordinator.data = data
            view.document = PDFDocument(data: data)
        }
    }

    // MARK: - Source editor

    /// The text editor of a text or Markdown file: monospaced, with the shared
    /// core's syntax highlighting, and a keyboard bar to put the keyboard away.
    private struct IOSSourceEditor: UIViewRepresentable {
        let buffer: IOSFileEditorBuffer
        let documentKey: String
        /// Read so the view reloads when the buffer's text is replaced.
        let loadRevision: Int
        let path: String
        let editable: Bool

        func makeCoordinator() -> Coordinator { Coordinator() }

        func makeUIView(context: Context) -> UITextView {
            let view = UITextView()
            view.autocorrectionType = .no
            view.autocapitalizationType = .none
            view.smartQuotesType = .no
            view.smartDashesType = .no
            view.smartInsertDeleteType = .no
            view.spellCheckingType = .no
            view.alwaysBounceVertical = true
            view.keyboardDismissMode = .interactive
            view.backgroundColor = .clear
            view.textContainerInset = UIEdgeInsets(top: 12, left: 10, bottom: 24, right: 10)
            view.typingAttributes = Coordinator.baseAttributes
            view.delegate = context.coordinator
            view.accessibilityIdentifier = "ios.files.editor"
            view.accessibilityLabel = "File contents"
            let toolbar = UIToolbar()
            toolbar.sizeToFit()
            let done = UIBarButtonItem(
                title: "Done", style: .done, target: context.coordinator,
                action: #selector(Coordinator.dismissKeyboard))
            done.accessibilityIdentifier = "ios.files.keyboard-done"
            toolbar.items = [UIBarButtonItem(systemItem: .flexibleSpace), done]
            view.inputAccessoryView = toolbar
            context.coordinator.view = view
            return view
        }

        func updateUIView(_ view: UITextView, context: Context) {
            let coordinator = context.coordinator
            coordinator.buffer = buffer
            coordinator.path = path
            if view.isEditable != editable { view.isEditable = editable }
            if coordinator.documentKey != documentKey || coordinator.loadRevision != loadRevision {
                coordinator.documentKey = documentKey
                coordinator.loadRevision = loadRevision
                coordinator.load(buffer.currentText(), into: view)
            }
        }

        static func dismantleUIView(_ view: UITextView, coordinator: Coordinator) {
            coordinator.highlight?.cancel()
        }

        @MainActor
        final class Coordinator: NSObject, UITextViewDelegate {
            /// The most characters the core lexes; longer documents stay plain.
            static let highlightLimit = 200_000
            static let font = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
            static let boldFont = UIFont.monospacedSystemFont(ofSize: 14, weight: .semibold)
            static var baseAttributes: [NSAttributedString.Key: Any] {
                [.font: font, .foregroundColor: UIColor.label]
            }

            weak var view: UITextView?
            var buffer: IOSFileEditorBuffer?
            var path = ""
            var documentKey = ""
            var loadRevision = -1
            var highlight: Task<Void, Never>?

            func load(_ text: String, into view: UITextView) {
                highlight?.cancel()
                let attributed = NSMutableAttributedString(string: text, attributes: Self.baseAttributes)
                Self.apply(Self.spans(text, path: path), to: attributed)
                view.attributedText = attributed
                view.typingAttributes = Self.baseAttributes
            }

            func textViewDidChange(_ textView: UITextView) {
                buffer?.edit(textView.text)
                scheduleHighlight()
            }

            @objc func dismissKeyboard() {
                view?.resignFirstResponder()
            }

            /// Re-highlights shortly after typing pauses.
            private func scheduleHighlight() {
                highlight?.cancel()
                highlight = Task { [weak self] in
                    do { try await DieterTaskSleep.milliseconds(250) } catch { return }
                    guard let self, let view = self.view, view.markedTextRange == nil else { return }
                    let spans = Self.spans(view.text, path: self.path)
                    let selection = view.selectedRange
                    view.textStorage.beginEditing()
                    view.textStorage.setAttributes(
                        Self.baseAttributes, range: NSRange(location: 0, length: view.textStorage.length))
                    Self.apply(spans, to: view.textStorage)
                    view.textStorage.endEditing()
                    view.selectedRange = selection
                    view.typingAttributes = Self.baseAttributes
                }
            }

            /// The core's (start, length, kind) triples for `text`.
            private static func spans(_ text: String, path: String) -> [Int32] {
                guard (text as NSString).length <= highlightLimit else { return [] }
                return ClientSyntaxHighlights(
                    rules: SharedRules.shared.syntaxHighlights(text: text, path: path, offset: 0)
                ).spans
            }

            private static func apply(_ spans: [Int32], to text: NSMutableAttributedString) {
                let full = NSRange(location: 0, length: text.length)
                var index = 0
                while index + 2 < spans.count {
                    let span = NSIntersectionRange(
                        NSRange(location: Int(spans[index]), length: Int(spans[index + 1])), full)
                    let kind = ClientSyntaxKind(rawValue: Int(spans[index + 2])) ?? .unspecified
                    index += 3
                    guard span.length > 0, let color = color(for: kind) else { continue }
                    text.addAttribute(.foregroundColor, value: color, range: span)
                    if kind == .keyword || kind == .heading { text.addAttribute(.font, value: boldFont, range: span) }
                }
            }

            private static func color(for kind: ClientSyntaxKind) -> UIColor? {
                switch kind {
                case .keyword, .heading, .tag: .systemPurple
                case .string: .systemGreen
                case .comment: .secondaryLabel
                case .number, .constant, .annotation, .emphasis: .systemOrange
                case .function, .link: .systemBlue
                case .type: .systemTeal
                case .property, .attribute, .variable: .systemPink
                default: nil
                }
            }
        }
    }
#endif
