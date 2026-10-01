import DieterAPI
import DieterCore
import Foundation
import Observation
import OSLog
import SharedCore

/// One file surface: a folder and the open document of a project checkout or
/// a conversation's workspace. The shared core lists, reads, and saves on the
/// machine that holds the files; the editor buffer stays native.
@MainActor @Observable
final class FilesModel {
    private(set) var target = WorkspaceTarget(endpointID: "", projectID: "")
    var projectName = "Project"
    var projectPath = ""
    /// Whether the files can change now; a surface that lost its workspace
    /// still shows what it read.
    var isLive = false
    var fileScopeCardID: String?
    var fileEditorSession = FileEditorSession()
    var files: [Dieter_V1_FileEntry] = []
    var fileDocument: Dieter_V1_FileDocument?
    var selectedFilePath = ""
    var filePath = ""
    var fileNavigation = ProjectFileNavigation()
    var fileNavigationLoading = false
    var filesLoading = false
    var fileLoading = false
    var filesError: String?
    var fileError: String?
    var showHiddenFiles = false {
        didSet {
            guard showHiddenFiles != oldValue, !folding else { return }
            let on = showHiddenFiles
            send { $0.showHidden = .with { $0.on = on } }
        }
    }
    /// The last save met a newer version on disk; the edits stay in the editor.
    private(set) var conflict = false
    private(set) var saving = false
    private(set) var fileScopeGeneration: UInt64 = 0
    @ObservationIgnored private(set) var fileListingGeneration: UInt64 = 0
    @ObservationIgnored private var core: CoreClient?
    @ObservationIgnored private let scope = "files-\(UUID().uuidString)"
    @ObservationIgnored private var subscription: SliceSubscription?
    /// The target the core was last told to bind; slices for another are stale.
    @ObservationIgnored private var bound = ClientFilesTarget()
    /// The latest command sent without waiting (a bind, a toggle, a close);
    /// later commands wait for it, so they reach the core in order and none
    /// reaches a previous target.
    @ObservationIgnored private var queued: Task<Void, Never>?
    @ObservationIgnored private var folding = false

    var documentKey: String { target.documentKey(path: selectedFilePath) }

    /// Points the surface at `target` through `core`; a new target starts
    /// with an empty folder and editor.
    func bind(target: WorkspaceTarget, core: CoreClient?) {
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
        fileListingGeneration &+= 1
        fileEditorSession = FileEditorSession()
        selectedFilePath = ""; filePath = ""; files = []; fileDocument = nil
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

    /// Stops observing; the core closes the surface.
    func unbind() {
        subscription?.close()
        subscription = nil
    }

    private func fold(_ slice: ClientFilesSlice) {
        guard slice.target == bound else { return }
        folding = true
        defer { folding = false }
        if files != slice.entries {
            files = slice.entries
            fileListingGeneration &+= 1
        }
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
                MacPerformanceSignposts.measure("Prepare file editor", log: MacPerformanceSignposts.editor) {
                    fileEditorSession.prepare(documentKey: documentKey, text: document.content)
                }
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
            if document || failure.kind == .conflict { fileError = failure.message } else { filesError = failure.message }
            return nil
        } catch {
            return nil
        }
    }

    /// Cancels a read in progress without discarding a loaded editor buffer.
    func cancelContentRead() {
        guard fileLoading, fileDocument == nil else { return }
        send { $0.close = ClientFilesStep() }
    }

    func returnToProjectRoot() async {
        fileScopeCardID = nil
        var root = target
        root.conversationID = ""
        bind(target: root, core: core)
        await loadFiles()
    }

    @discardableResult
    func loadFiles(path: String? = nil) async -> Bool {
        guard !target.projectID.isEmpty else { return false }
        guard await run({ command in command.load = .with { $0.path = path ?? "" } }) != nil else { return false }
        return filesError == nil
    }

    func navigateFiles(to destination: String) async {
        guard destination != filePath, !fileNavigationLoading else { return }
        await run { command in command.navigate = .with { $0.path = destination } }
    }

    func navigateFilesBack() async {
        guard fileNavigation.canGoBack, !fileNavigationLoading else { return }
        await run { $0.back = ClientFilesStep() }
    }

    func navigateFilesForward() async {
        guard fileNavigation.canGoForward, !fileNavigationLoading else { return }
        await run { $0.forward = ClientFilesStep() }
    }

    func openFile(path: String) async {
        let log = MacPerformanceSignposts.editor
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
    func saveFile(content: String) async -> Dieter_V1_FileDocument? {
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

    func saveCurrentDocument() async {
        _ = await saveFile(content: fileEditorSession.currentText())
    }

    /// Replaces the open document with the version on disk, dropping conflicting edits.
    func reloadDocument() async {
        await run(document: true) { $0.reload = ClientFilesStep() }
    }

    func createFile(path: String, directory: Bool) async {
        guard isLive else { return }
        let name = path.hasPrefix(filePath + "/") ? String(path.dropFirst(filePath.count + 1)) : path
        await run { command in
            command.create = .with {
                $0.name = filePath.isEmpty ? path : name
                $0.directory = directory
            }
        }
    }

    func deleteFile(path: String, recursive: Bool) async {
        guard isLive else { return }
        await run { command in
            command.delete = .with {
                $0.path = path
                $0.recursive = recursive
            }
        }
    }

    func moveFile(source: String, destination: String) async {
        guard isLive else { return }
        await run { command in
            command.move = .with {
                $0.source = source
                $0.destination = destination
            }
        }
    }
}
