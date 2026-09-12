import AppKit
import DieterCore
import Foundation
import Observation

struct ConversationContentScope {
    let target: WorkspaceTarget
    let rootPath: String
    let client: any FilesRPC
}

/// Independent of the Files route. A hidden pane retains its unsaved buffer,
/// and every read/save stays bound to the machine and workspace that opened it.
@MainActor @Observable
final class ConversationContentModel {
    private(set) var files = FilesModel()
    private(set) var conversationID = ""
    private(set) var selection: ConversationContentLink?
    private(set) var isOpen = false
    private(set) var loading = false
    private(set) var error: String?
    private(set) var sourceURL: URL?
    private(set) var rootPath = ""
    private(set) var navigationID = UUID()
    private(set) var browserAllowsLoopback = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var openTask: Task<Void, Never>?
    @ObservationIgnored var validateWebURL: @MainActor (URL, String) throws -> Void = { _, _ in }
    @ObservationIgnored var onSaveFailure: (String) -> Void = { _ in }
    @ObservationIgnored var prepareScope: @MainActor (String) async throws -> ConversationContentScope = { _ in
        throw CocoaError(.fileReadNoPermission)
    }
    @ObservationIgnored var confirmUnsaved: @MainActor (String) async -> UnsavedChoice = { name in
        let alert = NSAlert()
        alert.messageText = "Save changes to “\(name)”?"
        alert.informativeText = "Save your edits before opening another item or closing this pane."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard Changes")
        alert.addButton(withTitle: "Cancel")
        let response: NSApplication.ModalResponse
        if let window = NSApp.keyWindow {
            response = await alert.beginSheetModal(for: window)
        } else {
            response = alert.runModal()
        }
        switch response {
        case .alertFirstButtonReturn: return .save
        case .alertSecondButtonReturn: return .discard
        default: return .cancel
        }
    }
    private(set) var confirming = false
    enum UnsavedChoice { case save, discard, cancel }

    func isPresented(for id: String?) -> Bool { isOpen && id == conversationID }

    func requestOpen(_ url: URL, conversationID id: String) {
        guard !confirming, !files.saving else { return }
        openTask?.cancel()
        generation &+= 1
        files.cancelContentRead()
        openTask = Task { _ = await open(url, conversationID: id) }
    }

    @discardableResult
    func open(_ url: URL, conversationID id: String) async -> Bool {
        guard !id.isEmpty, !confirming, !files.saving else { return false }
        if case .file = selection, sourceURL == url, conversationID == id, isOpen,
            !loading, !files.fileLoading, files.fileDocument != nil, error == nil, files.fileError == nil
        {
            navigationID = UUID()
            return true
        }
        let beforeConfirmation = generation
        guard await allowReplacement(), generation == beforeConfirmation, !Task.isCancelled else { return false }
        generation &+= 1
        let request = generation
        conversationID = id
        sourceURL = url
        navigationID = UUID()
        selection = nil
        error = nil
        loading = true
        isOpen = true
        // Detach the old renderer before rebinding. A late editor teardown must
        // never copy its buffer into the new document's session.
        files.cancelContentRead()
        files = FilesModel()
        defer { if generation == request { loading = false } }
        do {
            if ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                try validateWebURL(url, id)
                browserAllowsLoopback = (try? validateWebURL(URL(string: "http://localhost")!, id)) != nil
                selection = try ConversationContentLink.resolve(url, workspaceRoot: "")
                return true
            }
            let scope = try await prepareScope(id)
            guard request == generation, !Task.isCancelled else { return false }
            let link = try ConversationContentLink.resolve(url, workspaceRoot: scope.rootPath)
            files.bind(target: scope.target, client: scope.client)
            files.isLive = true
            rootPath = scope.rootPath
            selection = link
            if case .file(let path, _) = link { await files.openFile(path: path) }
            return request == generation
        } catch {
            guard request == generation, !Task.isCancelled else { return false }
            self.error = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func close() async -> Bool {
        let beforeConfirmation = generation
        guard !confirming, !files.saving, await allowReplacement(), generation == beforeConfirmation else {
            return false
        }
        generation &+= 1
        openTask?.cancel()
        files.cancelContentRead()
        isOpen = false
        loading = false
        selection = nil
        sourceURL = nil
        files = FilesModel()
        return true
    }

    /// Changing routes cancels pending opens but keeps an already edited file
    /// available when the user returns to this conversation.
    func suspend() {
        generation &+= 1
        openTask?.cancel()
        files.cancelContentRead()
        if loading { isOpen = false; loading = false }
    }

    private func allowReplacement() async -> Bool {
        guard files.fileEditorSession.isDirty else { return true }
        confirming = true
        defer { confirming = false }
        switch await confirmUnsaved(files.fileDocument?.name ?? files.selectedFilePath) {
        case .cancel: return false
        case .discard: return true
        case .save:
            await files.saveCurrentDocument()
            if files.fileEditorSession.isDirty, let error = files.fileError { onSaveFailure(error) }
            return !files.fileEditorSession.isDirty
        }
    }
}
