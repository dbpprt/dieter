import AppKit
import DieterAPI
import DieterCore
import GRPCCore
import Testing
@testable import DieterMac

private actor ConversationContentFilesFixture: FilesRPC {
    private(set) var reads: [Dieter_V1_ReadFileRequest] = []
    private(set) var saves: [Dieter_V1_SaveFileRequest] = []
    let conflicts: Bool
    let holdFirstRead: Bool
    var pendingRead: CheckedContinuation<Void, Never>?

    init(conflicts: Bool = false, holdFirstRead: Bool = false) {
        self.conflicts = conflicts
        self.holdFirstRead = holdFirstRead
    }

    func listFiles(_ request: Dieter_V1_ListFilesRequest) async throws -> Dieter_V1_FileList { .init() }
    func readFile(_ request: Dieter_V1_ReadFileRequest) async throws -> Dieter_V1_FileDocument {
        reads.append(request)
        if holdFirstRead, reads.count == 1 {
            await withCheckedContinuation { pendingRead = $0 }
        }
        var document = Dieter_V1_FileDocument()
        document.path = request.path
        document.name = (request.path as NSString).lastPathComponent
        document.content = "Original \(request.cardID)/\(request.path)"
        document.mimeType = "text/markdown"
        document.revision = "revision-1"
        return document
    }
    func finishFirstRead() { pendingRead?.resume(); pendingRead = nil }
    func saveFile(_ request: Dieter_V1_SaveFileRequest) async throws -> Dieter_V1_FileDocument {
        saves.append(request)
        if conflicts { throw RPCError(code: .aborted, message: "File changed since it was opened.") }
        var document = Dieter_V1_FileDocument()
        document.path = request.path
        document.name = (request.path as NSString).lastPathComponent
        document.content = request.content
        document.revision = "revision-2"
        return document
    }
    func createFile(_ request: Dieter_V1_CreateFileRequest) async throws -> Dieter_V1_FileEntry { .init() }
    func deleteFile(_ request: Dieter_V1_DeleteFileRequest) async throws {}
    func moveFile(_ request: Dieter_V1_MoveFileRequest) async throws -> Dieter_V1_MoveFileResponse { .init() }
}

@Suite @MainActor struct ConversationContentModelTests {
    @Test func repeatedCodeLinkRevealsItsLineAgainWithoutAnotherRead() async throws {
        let client = ConversationContentFilesFixture(), content = model(client)
        let destination = try url("main.swift#L2")
        #expect(await content.open(destination, conversationID: "card-A"))
        let navigation = content.navigationID
        let session = content.files.fileEditorSession
        #expect(await content.open(destination, conversationID: "card-A"))
        #expect(content.navigationID != navigation)
        #expect(content.files.fileEditorSession === session)
        #expect(await client.reads.count == 1)
    }

    @Test func clickingTheSameLinkDuringLoadingRestartsAndFinishesTheRead() async throws {
        let client = ConversationContentFilesFixture(holdFirstRead: true)
        let content = model(client)
        let destination = try url("plan.md")
        content.requestOpen(destination, conversationID: "card-A")
        for _ in 0..<1000 {
            if await client.pendingRead != nil { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(await client.pendingRead != nil)
        content.requestOpen(destination, conversationID: "card-A")
        for _ in 0..<1000 {
            if !content.loading, content.files.fileDocument != nil { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        await client.finishFirstRead()
        #expect(await client.reads.count == 2)
        #expect(!content.loading)
        #expect(content.files.fileDocument?.path == "plan.md")
        #expect(content.isPresented(for: "card-A"))
    }

    private func scope(
        _ client: ConversationContentFilesFixture, cardID: String = "card-A"
    ) -> ConversationContentScope {
        .init(
            target: .init(endpointID: "remote-machine", projectID: "project-A", conversationID: cardID),
            rootPath: "/remote/worktrees/\(cardID)", client: client)
    }

    private func model(_ client: ConversationContentFilesFixture) -> ConversationContentModel {
        let result = ConversationContentModel()
        result.prepareScope = { id in self.scope(client, cardID: id) }
        return result
    }

    private func url(_ value: String) throws -> URL { try #require(URL(string: value)) }

    private func edit(_ model: ConversationContentModel, text: String = "Unsaved draft") {
        #expect(model.files.fileEditorSession.applyReplacement(text, documentKey: model.files.documentKey))
    }

    @Test func opensInTheConversationWorkspaceWithoutChangingTheFilesRoute() async throws {
        let client = ConversationContentFilesFixture()
        let filesRoute = FilesModel()
        let routeTarget = WorkspaceTarget(endpointID: "local-machine", projectID: "different-project")
        filesRoute.bind(target: routeTarget, client: client)
        await filesRoute.openFile(path: "other.md")
        let routeSession = filesRoute.fileEditorSession
        let content = model(client)

        #expect(await content.open(try url("docs/plan.md#L9"), conversationID: "card-A"))

        let requests = await client.reads
        let request = try #require(requests.last)
        #expect(request.projectID == "project-A")
        #expect(request.cardID == "card-A")
        #expect(request.path == "docs/plan.md")
        #expect(content.files.target.endpointID == "remote-machine")
        #expect(content.rootPath == "/remote/worktrees/card-A")
        #expect(content.selection == .file(path: "docs/plan.md", line: 9))
        #expect(content.isPresented(for: "card-A"))
        #expect(!content.isPresented(for: "card-B"))
        #expect(content.files !== filesRoute)
        #expect(filesRoute.target == routeTarget)
        #expect(filesRoute.selectedFilePath == "other.md")
        #expect(filesRoute.fileEditorSession === routeSession)
    }

    @Test func cancelKeepsTheDirtyDocumentWhenNavigatingOrClosing() async throws {
        let client = ConversationContentFilesFixture(), content = model(client)
        let original = try url("docs/plan.md")
        #expect(await content.open(original, conversationID: "card-A"))
        edit(content)
        let session = content.files.fileEditorSession
        var names: [String] = []
        content.confirmUnsaved = { name in
            names.append(name); return .cancel
        }

        #expect(!(await content.open(try url("https://example.com"), conversationID: "card-A")))
        #expect(!(await content.close()))

        #expect(names == ["plan.md", "plan.md"])
        #expect(content.sourceURL == original)
        #expect(content.selection == .file(path: "docs/plan.md", line: nil))
        #expect(content.isOpen)
        #expect(content.files.fileEditorSession === session)
        #expect(session.currentText() == "Unsaved draft")
        #expect(session.isDirty)
        #expect(await client.saves.isEmpty)
    }

    @Test func saveUsesTheOpeningRevisionAndWorkspaceBeforeNavigating() async throws {
        let client = ConversationContentFilesFixture(), content = model(client)
        #expect(await content.open(try url("docs/plan.md"), conversationID: "card-A"))
        edit(content, text: "Saved draft")
        let session = content.files.fileEditorSession
        content.confirmUnsaved = { _ in .save }
        let destination = try url("https://example.com/docs")

        #expect(await content.open(destination, conversationID: "card-A"))

        let saves = await client.saves
        let saved = try #require(saves.first)
        #expect(saves.count == 1)
        #expect(saved.projectID == "project-A")
        #expect(saved.cardID == "card-A")
        #expect(saved.path == "docs/plan.md")
        #expect(saved.revision == "revision-1")
        #expect(saved.content == "Saved draft")
        #expect(!session.isDirty)
        #expect(content.selection == .web(destination))
        #expect(content.files.fileDocument == nil)
    }

    @Test func discardOpensTheNextDocumentWithoutSavingOrCarryingItsBuffer() async throws {
        let client = ConversationContentFilesFixture(), content = model(client)
        #expect(await content.open(try url("docs/first.md"), conversationID: "card-A"))
        edit(content)
        let oldSession = content.files.fileEditorSession
        content.confirmUnsaved = { _ in .discard }

        #expect(await content.open(try url("docs/second.md"), conversationID: "card-B"))

        #expect(await client.saves.isEmpty)
        #expect(content.conversationID == "card-B")
        #expect(content.files.fileEditorSession !== oldSession)
        #expect(content.files.fileEditorSession.currentText() == "Original card-B/docs/second.md")
        #expect(!content.files.fileEditorSession.isDirty)
        #expect(content.selection == .file(path: "docs/second.md", line: nil))
        #expect(await content.close())
        #expect(!content.isOpen)
        #expect(content.selection == nil)
    }

    @Test func saveConflictPreservesTheDirtyBufferAndTextSelection() async throws {
        let client = ConversationContentFilesFixture(conflicts: true), content = model(client)
        let original = try url("docs/plan.md")
        #expect(await content.open(original, conversationID: "card-A"))
        let files = content.files, session = files.fileEditorSession
        let editor = NSTextView()
        session.attach(editor, documentKey: files.documentKey, initialText: session.currentText())
        edit(content, text: "Unsaved conflict draft")
        let selection = NSRange(location: 8, length: 8)
        editor.setSelectedRange(selection)
        content.confirmUnsaved = { _ in .save }

        #expect(!(await content.open(try url("https://example.com"), conversationID: "card-A")))

        #expect(content.files === files)
        #expect(content.sourceURL == original)
        #expect(content.selection == .file(path: "docs/plan.md", line: nil))
        #expect(session.currentText() == "Unsaved conflict draft")
        #expect(session.isDirty)
        #expect(editor.selectedRange() == selection)
        #expect(files.fileDocument?.revision == "revision-1")
        #expect(files.fileError?.contains("File changed") == true)
        #expect(!content.confirming)
        #expect(!files.saving)
        session.detach(editor)
    }

    @Test func staleScopeCompletionCannotReplaceANewerObject() async throws {
        let client = ConversationContentFilesFixture(), content = model(client)
        var pending: CheckedContinuation<ConversationContentScope, Error>?
        content.prepareScope = { id in
            if id == "old-card" {
                return try await withCheckedThrowingContinuation { pending = $0 }
            }
            return self.scope(client, cardID: id)
        }
        let oldURL = try url("old.md"), newURL = try url("new.md")
        let oldOpen = Task { await content.open(oldURL, conversationID: "old-card") }
        try await waitUntil { pending != nil }
        #expect(await content.open(newURL, conversationID: "new-card"))
        pending?.resume(returning: scope(client, cardID: "old-card"))

        #expect(!(await oldOpen.value))
        #expect(content.sourceURL == newURL)
        #expect(content.conversationID == "new-card")
        #expect(content.files.fileDocument?.content == "Original new-card/new.md")
        #expect(content.isPresented(for: "new-card"))
        #expect(!content.loading)
        let reads = await client.reads
        #expect(reads.map(\.cardID) == ["new-card"])
    }

    @Test func suspendRetainsTheDirtyBufferForReturningToTheConversation() async throws {
        let client = ConversationContentFilesFixture(), content = model(client)
        let original = try url("docs/plan.md")
        #expect(await content.open(original, conversationID: "card-A"))
        edit(content)
        let session = content.files.fileEditorSession
        var confirmations = 0
        content.confirmUnsaved = { _ in
            confirmations += 1; return .cancel
        }

        content.suspend()
        #expect(await content.open(original, conversationID: "card-A"))

        #expect(content.files.fileEditorSession === session)
        #expect(session.currentText() == "Unsaved draft")
        #expect(session.isDirty)
        #expect(confirmations == 0)
        #expect(await client.reads.count == 1)
    }

    @Test func suspendPreventsALateScopeCompletionFromOpeningThePane() async throws {
        let client = ConversationContentFilesFixture(), content = model(client)
        var pending: CheckedContinuation<ConversationContentScope, Error>?
        content.prepareScope = { _ in try await withCheckedThrowingContinuation { pending = $0 } }
        let target = try url("docs/plan.md")
        let opening = Task { await content.open(target, conversationID: "card-A") }
        try await waitUntil { pending != nil }

        content.suspend()
        pending?.resume(returning: scope(client))

        #expect(!(await opening.value))
        #expect(!content.isOpen)
        #expect(!content.loading)
        #expect(content.selection == nil)
        #expect(await client.reads.isEmpty)
    }

    @Test func suspendInvalidatesNavigationAwaitingUnsavedConfirmation() async throws {
        let client = ConversationContentFilesFixture(), content = model(client)
        let original = try url("docs/plan.md")
        #expect(await content.open(original, conversationID: "card-A"))
        edit(content)
        let session = content.files.fileEditorSession
        var pending: CheckedContinuation<ConversationContentModel.UnsavedChoice, Never>?
        content.confirmUnsaved = { _ in await withCheckedContinuation { pending = $0 } }
        let destination = try url("https://example.com")
        let opening = Task { await content.open(destination, conversationID: "card-B") }
        try await waitUntil { pending != nil }

        content.suspend()
        pending?.resume(returning: .discard)

        #expect(!(await opening.value))
        #expect(content.sourceURL == original)
        #expect(content.conversationID == "card-A")
        #expect(content.files.fileEditorSession === session)
        #expect(session.isDirty)
        #expect(session.currentText() == "Unsaved draft")
        #expect(!content.isPresented(for: "card-B"))
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<1_000 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw CocoaError(.coderValueNotFound)
    }
}
