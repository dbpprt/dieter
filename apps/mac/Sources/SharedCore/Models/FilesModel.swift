import DieterAPI
import Foundation
import Observation
import OSLog

/// Editor signposts, under the app's own subsystem.
private let editorSignposts = OSLog(subsystem: Bundle.main.bundleIdentifier ?? "com.dbpprt.dieter", category: "Editor")

/// The native editor buffer of a files surface: the text being edited, kept
/// apart from the surface's state so a large document is copied only when it
/// opens or saves.
@MainActor
package protocol FileEditorBuffer: AnyObject {
    init()
    /// Advances with every edit and every prepared document.
    var revision: Int { get }
    /// Shows `text` as `documentKey`'s content unless it is that document with unsaved edits.
    func prepare(documentKey: String, text: String)
    /// Marks the buffer clean when `submittedText` is still what it holds at `editRevision`.
    func markSaved(documentKey: String, submittedText: String, editRevision: Int)
    func currentText() -> String
}

/// Folder history, as the shared core reports it for one files surface.
package struct ProjectFileNavigation: Equatable, Sendable {
    package var canGoBack = false
    package var canGoForward = false

    package init(canGoBack: Bool = false, canGoForward: Bool = false) {
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
    }
}

/// One file surface: a folder and the open document of a project checkout or
/// a conversation's workspace. The shared core lists, reads, and saves on the
/// machine that holds the files; the editor buffer stays native.
@MainActor @Observable
package final class FilesSurfaceModel<Editor: FileEditorBuffer> {
    package private(set) var target = WorkspaceTarget(endpointID: "", projectID: "")
    package var projectName = "Project"
    package var projectPath = ""
    /// Whether the files can change now; a surface that lost its workspace
    /// still shows what it read.
    package var isLive = false
    package var fileScopeCardID: String?
    package var fileEditorSession = Editor()
    package var files: [Dieter_V1_FileEntry] = []
    package var fileDocument: Dieter_V1_FileDocument?
    package var selectedFilePath = ""
    package var filePath = ""
    package var fileNavigation = ProjectFileNavigation()
    package var fileNavigationLoading = false
    package var filesLoading = false
    package var fileLoading = false
    package var filesError: String?
    package var fileError: String?
    package var showHiddenFiles = false {
        didSet {
            guard showHiddenFiles != oldValue, !folding else { return }
            let on = showHiddenFiles
            send { $0.showHidden = .with { $0.on = on } }
        }
    }
    /// The last save met a newer version on disk; the edits stay in the editor.
    package private(set) var conflict = false
    package private(set) var saving = false
    package private(set) var fileScopeGeneration: UInt64 = 0
    @ObservationIgnored private var core: CoreClient?
    @ObservationIgnored package let scope: String
    @ObservationIgnored private var subscription: SliceSubscription?
    /// The target the core was last told to bind; slices for another are stale.
    @ObservationIgnored private var bound = ClientFilesTarget()
    /// The latest command sent without waiting (a bind, a toggle, a close);
    /// later commands wait for it, so they reach the core in order and none
    /// reaches a previous target.
    @ObservationIgnored private var queued: Task<Void, Never>?
    @ObservationIgnored private var folding = false

    /// The open document's identity across targets, as the core keys it; "" without a target.
    package private(set) var documentKey = ""
    /// The open document's language, e.g. "Swift" or "Plain text".
    package private(set) var languageName = ""
    /// The open document's type, e.g. "Markdown" or its media type.
    package private(set) var typeLabel = ""

    /// `scope` names the surface in the core; each view needs its own.
    package init(scope: String = "files-\(UUID().uuidString)") {
        self.scope = scope
    }

    /// Points the surface at `target` through `core`; a new target starts
    /// with an empty folder and editor.
    package func bind(target: WorkspaceTarget, core: CoreClient?) {
        if subscription == nil, let core {
            self.core = core
            subscription = SliceSubscription(client: core, slice: .files, scope: scope) { [weak self] update in
                guard let self, case .files(let slice) = update.value else { return }
                self.fold(slice)
            }
        }
        guard self.target != target else { return }
        self.target = target
        fileScopeGeneration &+= 1
        fileEditorSession = Editor()
        selectedFilePath = ""; filePath = ""; files = []; fileDocument = nil
        documentKey = ""; languageName = ""; typeLabel = ""
        fileNavigation = ProjectFileNavigation()
        filesError = nil; fileError = nil
        bound = ClientFilesTarget.with {
            $0.daemonID = target.daemonID
            $0.projectID = target.projectID
            $0.checkoutID = target.checkoutID
            $0.cardID = target.conversationID
        }
        let bind = bound
        send { $0.bind = bind }
    }

    private func fold(_ slice: ClientFilesSlice) {
        guard slice.target == bound else { return }
        folding = true
        defer { folding = false }
        // The editor is prepared under the key, so it settles first.
        if documentKey != slice.documentKey { documentKey = slice.documentKey }
        if languageName != slice.languageName { languageName = slice.languageName }
        if typeLabel != slice.typeLabel { typeLabel = slice.typeLabel }
        if files != slice.entries { files = slice.entries }
        if filePath != slice.directory { filePath = slice.directory }
        if showHiddenFiles != slice.showHidden { showHiddenFiles = slice.showHidden }
        if filesLoading != slice.listingLoading { filesLoading = slice.listingLoading }
        if fileNavigationLoading != slice.listingLoading { fileNavigationLoading = slice.listingLoading }
        let listingError = slice.listingError.isEmpty ? nil : slice.listingError
        if filesError != listingError { filesError = listingError }
        if selectedFilePath != slice.selectedPath { selectedFilePath = slice.selectedPath }
        if !slice.documentUnchanged {
            let document = slice.hasDocument ? slice.document : nil
            if fileDocument != document { fileDocument = document }
            if let document, !document.binary {
                let signpost = OSSignpostID(log: editorSignposts)
                os_signpost(.begin, log: editorSignposts, name: "Prepare file editor", signpostID: signpost)
                fileEditorSession.prepare(documentKey: documentKey, text: document.content)
                os_signpost(.end, log: editorSignposts, name: "Prepare file editor", signpostID: signpost)
            }
        }
        if fileLoading != slice.documentLoading { fileLoading = slice.documentLoading }
        let documentError = slice.documentError.isEmpty ? nil : slice.documentError
        if fileError != documentError { fileError = documentError }
        if conflict != slice.conflict { conflict = slice.conflict }
        if saving != slice.saving { saving = slice.saving }
        let navigation = ProjectFileNavigation(canGoBack: slice.canGoBack, canGoForward: slice.canGoForward)
        if fileNavigation != navigation { fileNavigation = navigation }
    }

    /// Sends a files command without waiting for it, after those sent before.
    private func send(_ build: @escaping (inout ClientFilesCommand) -> Void) {
        let previous = queued
        queued = Task { [weak self] in
            await previous?.value
            await self?.run(afterQueued: false, build)
        }
    }

    /// Reads this target's files for an HTML preview, through the core.
    package var htmlPreviewRead: HTMLPreviewRead {
        let target = target
        return { [weak self] path in
            guard let core = self?.core else { throw CancellationError() }
            return try await core.htmlPreviewRead(target: target)(path)
        }
    }

    /// Runs a files command and folds the surface it returns, so callers read
    /// its effect at once. A failure shows on the folder, or on the document
    /// for document commands; a save conflict keeps the editor's text.
    @discardableResult
    private func run(
        document: Bool = false, afterQueued: Bool = true, _ build: (inout ClientFilesCommand) -> Void
    ) async -> ClientResult? {
        guard let core else { return nil }
        if afterQueued, let queued { await queued.value }
        var files = ClientFilesCommand()
        files.scope = scope
        build(&files)
        let command = ClientCommand.with { $0.files = files }
        let generation = fileScopeGeneration
        do {
            let result = try await core.dispatch(command)
            if case .files(let slice) = result.result { fold(slice) }
            return result
        } catch let failure as CoreFailure {
            guard generation == fileScopeGeneration else { return nil }
            if failure.kind == .conflict { conflict = true }
            if document || failure.kind == .conflict {
                fileError = failure.message
            } else {
                filesError = failure.message
            }
            return nil
        } catch {
            return nil
        }
    }

    /// Cancels a read in progress without discarding a loaded editor buffer.
    package func cancelContentRead() {
        guard fileLoading, fileDocument == nil else { return }
        send { $0.close = ClientStep() }
    }

    /// Closes the open document, keeping the folder; the editor keeps its
    /// buffer, so reopening the document shows any edits it still holds.
    package func closeDocument() async {
        await run { $0.close = ClientStep() }
    }

    package func returnToProjectRoot() async {
        fileScopeCardID = nil
        var root = target
        root.conversationID = ""
        bind(target: root, core: core)
        await loadFiles()
    }

    @discardableResult
    package func loadFiles(path: String? = nil) async -> Bool {
        guard !target.projectID.isEmpty else { return false }
        guard await run({ command in command.load = .with { $0.path = path ?? "" } }) != nil else { return false }
        return filesError == nil
    }

    package func navigateFiles(to destination: String) async {
        guard destination != filePath, !fileNavigationLoading else { return }
        await run { command in command.navigate = .with { $0.path = destination } }
    }

    package func navigateFilesBack() async {
        guard fileNavigation.canGoBack, !fileNavigationLoading else { return }
        await run { $0.back = ClientStep() }
    }

    package func navigateFilesForward() async {
        guard fileNavigation.canGoForward, !fileNavigationLoading else { return }
        await run { $0.forward = ClientStep() }
    }

    package func openFile(path: String) async {
        let log = editorSignposts
        let signpostID = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: "Open file", signpostID: signpostID)
        defer { os_signpost(.end, log: log, name: "Open file", signpostID: signpostID) }
        if selectedFilePath != path {
            selectedFilePath = path
            fileDocument = nil
        }
        await run(document: true) { command in command.open = .with { $0.path = path } }
    }

    @discardableResult
    package func saveFile(content: String) async -> Dieter_V1_FileDocument? {
        guard isLive, fileDocument != nil, !saving else { return nil }
        let key = documentKey
        let generation = fileScopeGeneration
        let editor = fileEditorSession
        let editRevision = editor.revision
        // A save that returns after the surface moved on belongs to another document.
        let result = await run(document: true) { command in command.save = .with { $0.text = content } }
        guard case .fileDocument(let saved)? = result?.result, generation == fileScopeGeneration, key == documentKey
        else { return nil }
        editor.markSaved(documentKey: key, submittedText: content, editRevision: editRevision)
        fileDocument = saved
        return saved
    }

    package func saveCurrentDocument() async {
        _ = await saveFile(content: fileEditorSession.currentText())
    }

    /// Replaces the open document with the version on disk after a save
    /// conflict, dropping the edits that conflicted with it.
    package func reloadDocument() async {
        let key = documentKey
        let generation = fileScopeGeneration
        guard await run(document: true, { $0.reload = ClientStep() }) != nil,
            generation == fileScopeGeneration, key == documentKey, let document = fileDocument
        else { return }
        // The editor keeps unsaved text across folds; a fresh session takes the disk version.
        let editor = Editor()
        if !document.binary { editor.prepare(documentKey: key, text: document.content) }
        fileEditorSession = editor
    }

    /// Creates `name` in the current folder; the core joins the path.
    package func createFile(name: String, directory: Bool) async {
        guard isLive else { return }
        await run { command in
            command.create = .with {
                $0.name = name
                $0.directory = directory
            }
        }
    }

    /// Opens the current folder's parent.
    package func navigateToParent() async {
        guard !filePath.isEmpty, !fileNavigationLoading else { return }
        await run { $0.parent = ClientStep() }
    }

    package func deleteFile(path: String, recursive: Bool) async {
        guard isLive else { return }
        await run { command in
            command.delete = .with {
                $0.path = path
                $0.recursive = recursive
            }
        }
    }

    package func moveFile(source: String, destination: String) async {
        guard isLive else { return }
        await run { command in
            command.move = .with {
                $0.source = source
                $0.destination = destination
            }
        }
    }
}
