import DieterAPI
import DieterCore
import Foundation
import GRPCCore
import Observation

/// Owns one file surface. Every completion belongs to a binding and read generation.
@MainActor @Observable
final class FilesModel {
    private(set) var target = WorkspaceTarget(endpointID: "", projectID: "")
    var projectName = "Project"
    var projectPath = ""
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
    var showHiddenFiles = false
    private(set) var saving = false
    @ObservationIgnored private var client: (any FilesRPC)?
    private(set) var fileScopeGeneration: UInt64 = 0
    @ObservationIgnored private(set) var fileListingGeneration: UInt64 = 0
    @ObservationIgnored private var fileReadGeneration: UInt64 = 0
    @ObservationIgnored private let fileListingRead = OwnedRead<Dieter_V1_FileList>()
    @ObservationIgnored private let fileContentRead = OwnedRead<Dieter_V1_FileDocument>()

    var documentKey: String { target.documentKey(path: selectedFilePath) }

    func bind(target: WorkspaceTarget, client: (any FilesRPC)?) {
        guard self.target != target || self.client !== client else { return }
        let sameTarget = self.target == target
        self.target = target
        self.client = client
        fileScopeGeneration &+= 1
        fileListingGeneration &+= 1
        fileReadGeneration &+= 1
        fileListingRead.cancel(); fileContentRead.cancel()
        fileNavigationLoading = false; filesLoading = false; fileLoading = false; saving = false
        filesError = nil; fileError = nil
        if !sameTarget {
            fileEditorSession = FileEditorSession()
            selectedFilePath = ""; filePath = ""; files = []; fileDocument = nil; fileNavigation.reset()
        }
    }

    func returnToProjectRoot() async {
        fileScopeCardID = nil
        var root = target
        root.conversationID = ""
        bind(target: root, client: client)
        await loadFiles()
    }

    @discardableResult
    func loadFiles(path: String? = nil) async -> Bool {
        guard let rpc = client, !target.projectID.isEmpty else { return false }
        let destination = path ?? filePath
        var request = Dieter_V1_ListFilesRequest(); request.projectID = target.projectID; request.path = destination;
        request.showHidden = showHiddenFiles
        request.cardID = target.conversationID
        fileListingGeneration &+= 1
        let generation = fileListingGeneration
        filesLoading = true
        filesError = nil
        defer { if generation == fileListingGeneration { filesLoading = false } }
        let readRequest = request
        do {
            let listing = try await fileListingRead.value(
                key:
                    "\(ObjectIdentifier(rpc)):\(request.projectID):\(request.cardID):\(destination):\(request.showHidden)"
            ) {
                try await rpc.listFiles(readRequest)
            }
            guard self.client === rpc, fileListingGeneration == generation,
                target.projectID == request.projectID, target.conversationID == request.cardID
            else { return false }
            files = listing.entries
            filePath = listing.path
            return true
        } catch {
            guard self.client === rpc, fileListingGeneration == generation,
                target.projectID == request.projectID, target.conversationID == request.cardID
            else { return false }
            if !DieterRPCFailure.isCancellation(error) { filesError = DieterRPCFailure.message(for: error) }
            return false
        }
    }

    func navigateFiles(to destination: String) async {
        guard destination != filePath, !fileNavigationLoading else { return }
        fileNavigationLoading = true
        let scope = fileScopeGeneration
        defer { if scope == fileScopeGeneration { fileNavigationLoading = false } }
        let previousNavigation = fileNavigation
        fileNavigation.recordNavigation(from: filePath, to: destination)
        if !(await loadFiles(path: destination)), scope == fileScopeGeneration { fileNavigation = previousNavigation }
    }

    func navigateFilesBack() async {
        guard !fileNavigationLoading else { return }
        fileNavigationLoading = true
        let scope = fileScopeGeneration
        defer { if scope == fileScopeGeneration { fileNavigationLoading = false } }
        let previousNavigation = fileNavigation
        guard let destination = fileNavigation.goBack(from: filePath) else { return }
        if !(await loadFiles(path: destination)), scope == fileScopeGeneration { fileNavigation = previousNavigation }
    }

    func navigateFilesForward() async {
        guard !fileNavigationLoading else { return }
        fileNavigationLoading = true
        let scope = fileScopeGeneration
        defer { if scope == fileScopeGeneration { fileNavigationLoading = false } }
        let previousNavigation = fileNavigation
        guard let destination = fileNavigation.goForward(from: filePath) else { return }
        if !(await loadFiles(path: destination)), scope == fileScopeGeneration { fileNavigation = previousNavigation }
    }

    func openFile(path: String) async {
        guard let rpc = client else { return }
        var request = Dieter_V1_ReadFileRequest(); request.projectID = target.projectID; request.path = path;
        request.cardID = target.conversationID
        fileReadGeneration &+= 1
        let generation = fileReadGeneration
        if selectedFilePath != path { fileDocument = nil }
        selectedFilePath = path
        fileLoading = true
        fileError = nil
        defer { if generation == fileReadGeneration { fileLoading = false } }
        let readRequest = request
        do {
            let document = try await fileContentRead.value(
                key: "\(ObjectIdentifier(rpc)):\(request.projectID):\(request.cardID):\(path)"
            ) {
                try await rpc.readFile(readRequest)
            }
            guard self.client === rpc, generation == fileReadGeneration, target.projectID == request.projectID,
                target.conversationID == request.cardID
            else { return }
            fileDocument = document
            fileEditorSession.prepare(documentKey: documentKey, text: document.content)
        } catch {
            guard self.client === rpc, generation == fileReadGeneration, target.projectID == request.projectID,
                target.conversationID == request.cardID
            else { return }
            if let rpcError = error as? RPCError, rpcError.code == .notFound {
                fileError =
                    "“\((path as NSString).lastPathComponent)” could not be found. Refresh the folder or select another file."
            } else if !DieterRPCFailure.isCancellation(error) {
                fileError = DieterRPCFailure.message(for: error)
            }
        }
    }

    @discardableResult
    func saveFile(content: String) async -> Dieter_V1_FileDocument? {
        guard let client, let document = fileDocument, !saving else { return nil }
        var request = Dieter_V1_SaveFileRequest()
        request.projectID = target.projectID; request.cardID = target.conversationID
        request.path = document.path; request.revision = document.revision; request.content = content
        let scope = fileScopeGeneration
        let generation = fileReadGeneration
        let key = documentKey
        let editor = fileEditorSession
        let editRevision = editor.revision
        saving = true
        defer { if scope == fileScopeGeneration { saving = false } }
        do {
            var saved = try await client.saveFile(request)
            guard owns(scope), generation == fileReadGeneration else { return nil }
            if saved.mimeType.isEmpty { saved.mimeType = document.mimeType }
            editor.markSaved(documentKey: key, submittedText: content, editRevision: editRevision)
            fileDocument = saved
            return saved
        } catch {
            guard owns(scope), generation == fileReadGeneration else { return nil }
            if !DieterRPCFailure.isCancellation(error) { fileError = DieterRPCFailure.message(for: error) }
            return nil
        }
    }

    func saveCurrentDocument() async {
        _ = await saveFile(content: fileEditorSession.currentText())
    }

    func createFile(path: String, directory: Bool) async {
        guard let client else { return }
        let scope = fileScopeGeneration
        var request = Dieter_V1_CreateFileRequest()
        request.projectID = target.projectID; request.cardID = target.conversationID
        request.path = path; request.kind = directory ? "directory" : "file"
        do {
            _ = try await client.createFile(request)
            guard owns(scope) else { return }
            await loadFiles()
        } catch { report(error, scope: scope) }
    }

    func deleteFile(path: String, recursive: Bool) async {
        guard let client else { return }
        let scope = fileScopeGeneration
        var request = Dieter_V1_DeleteFileRequest()
        request.projectID = target.projectID; request.cardID = target.conversationID
        request.path = path; request.recursive = recursive
        do {
            try await client.deleteFile(request)
            guard owns(scope) else { return }
            invalidateDocument(under: path)
            await loadFiles()
        } catch { report(error, scope: scope) }
    }

    func moveFile(source: String, destination: String) async {
        guard let client else { return }
        let scope = fileScopeGeneration
        var request = Dieter_V1_MoveFileRequest()
        request.projectID = target.projectID; request.cardID = target.conversationID
        request.source = source; request.destination = destination
        do {
            _ = try await client.moveFile(request)
            guard owns(scope) else { return }
            invalidateDocument(under: source)
            await loadFiles()
        } catch { report(error, scope: scope) }
    }

    private func invalidateDocument(under path: String) {
        guard selectedFilePath == path || selectedFilePath.hasPrefix(path + "/") else { return }
        fileReadGeneration &+= 1
        fileContentRead.cancel()
        fileDocument = nil; selectedFilePath = ""; fileLoading = false
    }

    private func owns(_ scope: UInt64) -> Bool { scope == fileScopeGeneration && !Task.isCancelled }
    private func report(_ error: Error, scope: UInt64) {
        guard owns(scope), !DieterRPCFailure.isCancellation(error) else { return }
        filesError = DieterRPCFailure.message(for: error)
    }
}
