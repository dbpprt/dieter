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

private actor ConversationContentTerminalFixture: TerminalsRPC {
    private(set) var listings: [(String, String)] = []
    private(set) var closes = 0
    func terminals(projectID: String, cardID: String) async throws -> Dieter_V1_TerminalsResponse {
        listings.append((projectID, cardID))
        var terminal = Dieter_V1_Terminal()
        terminal.id = "workspace-shell"; terminal.name = "Shell"; terminal.status = "running"
        terminal.columns = 100; terminal.rows = 30
        var response = Dieter_V1_TerminalsResponse(); response.terminals = [terminal]
        return response
    }
    func createTerminal(_ request: Dieter_V1_CreateTerminalRequest) async throws -> Dieter_V1_Terminal { .init() }
    func watchTerminal(id: String, after: UInt64, receive: @escaping @Sendable (Dieter_V1_TerminalFrame) async -> Void)
        async throws
    {
        try await Task.sleep(for: .seconds(60))
    }
    func writeTerminal(id: String, data: Data) async throws -> Dieter_V1_Terminal { .init() }
    func resizeTerminal(id: String, columns: Int, rows: Int) async throws -> Dieter_V1_Terminal { .init() }
    func renameTerminal(id: String, name: String) async throws -> Dieter_V1_Terminal { .init() }
    func closeTerminal(id: String) async throws { closes += 1 }
}

private actor ConversationContentProjectReviewFixture: ProjectChangesRPC {
    private(set) var projectReads: [String] = []
    private(set) var diffReads: [Dieter_V1_GetDiffRequest] = []
    func changeset(projectID: String) async throws -> Dieter_V1_Changeset {
        projectReads.append(projectID)
        var file = Dieter_V1_ChangedFile(); file.path = "source.swift"; file.unstaged = true
        var value = Dieter_V1_Changeset(); value.projectID = projectID; value.revision = "r1"; value.files = [file]
        return value
    }
    func fileDiff(_ request: Dieter_V1_GetDiffRequest) async throws -> Dieter_V1_FileDiff {
        diffReads.append(request)
        var value = Dieter_V1_FileDiff(); value.projectID = request.projectID
        value.path = request.path; value.revision = request.expectedRevision; value.patch = "+change"
        return value
    }
    func startGitOperation(_ request: Dieter_V1_StartGitOperationRequest) async throws -> Dieter_V1_GitOperation {
        .init()
    }
    func gitOperation(id: String) async throws -> Dieter_V1_GitOperation { .init() }
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

    @Test func newTabsKeepDirtyDocumentsAndCancelProtectsClosing() async throws {
        let client = ConversationContentFilesFixture(), content = model(client)
        let original = try url("docs/plan.md")
        #expect(await content.open(original, conversationID: "card-A"))
        edit(content)
        let session = content.files.fileEditorSession
        var names: [String] = []
        content.confirmUnsaved = { name in
            names.append(name); return .cancel
        }

        let originalTab = try #require(content.selectedTabID)
        #expect(await content.open(try url("https://example.com"), conversationID: "card-A"))
        #expect(names.isEmpty)
        #expect(content.tabs.count == 2)
        #expect(!(await content.closeTab(originalTab)))
        #expect(!(await content.close()))
        content.selectTab(originalTab)
        #expect(names == ["plan.md", "plan.md"])
        #expect(content.sourceURL == original)
        #expect(content.selection == .file(path: "docs/plan.md", line: nil))
        #expect(content.isOpen)
        #expect(content.files.fileEditorSession === session)
        #expect(session.currentText() == "Unsaved draft")
        #expect(session.isDirty)
        #expect(await client.saves.isEmpty)
    }

    @Test func closingATabSavesItsOpeningRevisionAndWorkspace() async throws {
        let client = ConversationContentFilesFixture(), content = model(client)
        #expect(await content.open(try url("docs/plan.md"), conversationID: "card-A"))
        edit(content, text: "Saved draft")
        let session = content.files.fileEditorSession
        let fileTab = try #require(content.selectedTabID)
        content.confirmUnsaved = { _ in .save }
        let destination = try url("https://example.com/docs")

        #expect(await content.open(destination, conversationID: "card-A"))
        #expect(await client.saves.isEmpty)
        #expect(await content.closeTab(fileTab))

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

        #expect(!(await content.closeTab(try #require(content.selectedTabID))))

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

    @Test func canonicalFileAliasesSelectOneTabAndRevealTheNewLine() async throws {
        let client = ConversationContentFilesFixture(), content = model(client)
        #expect(await content.open(try url("docs/./plan.md#L2"), conversationID: "card-A"))
        let tab = try #require(content.selectedTab)
        edit(content)
        #expect(await content.open(try url("file:///remote/worktrees/card-A/docs/plan.md:9"), conversationID: "card-A"))
        #expect(content.tabs.count == 1)
        #expect(content.selectedTab === tab)
        #expect(content.selection == .file(path: "docs/plan.md", line: 9))
        #expect(tab.dirty)
        #expect(await client.reads.count == 1)
    }

    @Test func multipleDocumentsKeepIndependentBuffersAndHiddenPaneRestoresThem() async throws {
        let client = ConversationContentFilesFixture(), content = model(client)
        #expect(await content.open(try url("first.md"), conversationID: "card-A"))
        edit(content, text: "First draft")
        let first = try #require(content.selectedTab)
        #expect(await content.open(try url("second.md"), conversationID: "card-A"))
        edit(content, text: "Second draft")
        let second = try #require(content.selectedTab)
        content.selectTab(first.id)
        #expect(content.files.fileEditorSession.currentText() == "First draft")
        content.hide()
        #expect(!content.isOpen)
        #expect(content.tabs.count == 2)
        content.showEmpty(conversationID: "card-A")
        #expect(content.isOpen)
        #expect(content.selectedTab === first)
        #expect(second.files.fileEditorSession.currentText() == "Second draft")
        #expect(first.dirty && second.dirty)
    }

    @Test func relativeLinksUseTheOpeningDocumentDirectory() async throws {
        let client = ConversationContentFilesFixture(), content = model(client)
        #expect(await content.open(try url("docs/plans/first.md"), conversationID: "card-A"))
        #expect(
            await content.open(
                try url("../references.md#L4"), conversationID: "card-A", relativeTo: "docs/plans/first.md"))
        #expect(content.selection == .file(path: "docs/references.md", line: 4))
        #expect(await client.reads.last?.path == "docs/references.md")
    }

    @Test func tabLimitRejectsNewItemsWithoutEvictingDirtyBuffers() async throws {
        let client = ConversationContentFilesFixture(), content = model(client)
        #expect(await content.open(try url("draft.md"), conversationID: "card-A"))
        edit(content)
        let first = try #require(content.selectedTab)
        for index in 1..<ConversationContentModel.maximumTabs {
            #expect(await content.open(try url("file-\(index).md"), conversationID: "card-A"))
        }
        let selected = content.selectedTabID
        #expect(!(await content.open(try url("overflow.md"), conversationID: "card-A")))
        #expect(content.tabs.count == 12)
        #expect(content.selectedTabID == selected)
        #expect(content.error?.contains("Close a tab") == true)
        #expect(first.dirty)
        #expect(first.files.fileEditorSession.currentText() == "Unsaved draft")
        #expect(await content.open(try url("draft.md#L2"), conversationID: "card-A"))
        #expect(content.selectedTab === first)
    }

    @Test func browserTabsRetainTheirOwnSessionAndDoNotPromptForFileEdits() async throws {
        let client = ConversationContentFilesFixture(), content = model(client)
        #expect(await content.open(try url("draft.md"), conversationID: "card-A"))
        edit(content)
        #expect(await content.openPanel(.browser, conversationID: "card-A"))
        let first = try #require(content.selectedTab)
        #expect(first.selection == nil)
        #expect(await content.openPanel(.browser, conversationID: "card-A"))
        let second = try #require(content.selectedTab)
        #expect(first.browser !== second.browser)
        content.selectTab(first.id)
        #expect(content.selectedTab?.browser === first.browser)
        #expect(content.tabs.first?.dirty == true)
    }

    @Test func closingOneCleanTabKeepsOtherTabIdentities() async throws {
        let client = ConversationContentFilesFixture(), content = model(client)
        #expect(await content.open(try url("one.md"), conversationID: "card-A"))
        let first = try #require(content.selectedTab)
        #expect(await content.open(try url("two.md"), conversationID: "card-A"))
        let second = try #require(content.selectedTab)
        #expect(await content.closeTab(first.id))
        #expect(content.tabs.count == 1)
        #expect(content.selectedTab === second)
        #expect(await content.closeTab(second.id))
        #expect(content.tabs.isEmpty)
        #expect(content.isOpen)  // Empty pane remains a useful launcher.
    }

    @Test func terminalWatchIsScopedAndStoppingItsTabNeverClosesTheShell() async throws {
        let client = ConversationContentFilesFixture(), terminalClient = ConversationContentTerminalFixture()
        let content = ConversationContentModel()
        content.prepareScope = { id in
            var value = self.scope(client, cardID: id)
            value.terminalsClient = terminalClient
            return value
        }
        #expect(await content.openPanel(.terminal, conversationID: "card-A"))
        let tab = try #require(content.selectedTab)
        #expect(tab.terminals.active)
        #expect(tab.terminals.selectedTerminalID == "workspace-shell")
        let request = try #require(await terminalClient.listings.first)
        #expect(request.0 == "project-A" && request.1 == "card-A")
        #expect(await content.openPanel(.browser, conversationID: "card-A"))
        #expect(!tab.terminals.active)
        content.selectTab(tab.id)
        #expect(tab.terminals.active)
        content.hide()
        #expect(!tab.terminals.active)
        content.showEmpty(conversationID: "card-A")
        #expect(tab.terminals.active)
        #expect(await content.closeTab(tab.id))
        #expect(!tab.terminals.active)
        #expect(await terminalClient.closes == 0)
    }

    @Test func sameCardOnAnotherEndpointCannotReuseThePreviousDocument() async throws {
        let client = ConversationContentFilesFixture(), content = model(client)
        var endpoint = "machine-A"
        content.currentEndpointID = { _ in endpoint }
        content.prepareScope = { id in
            .init(
                target: .init(endpointID: endpoint, projectID: "project", conversationID: id), rootPath: "/workspace",
                client: client)
        }
        #expect(await content.open(try url("plan.md"), conversationID: "card-A"))
        let old = try #require(content.selectedTab)
        edit(content)
        endpoint = "machine-B"
        content.confirmUnsaved = { _ in .cancel }
        #expect(!(await content.open(try url("plan.md"), conversationID: "card-A")))
        #expect(content.selectedTab === old)
        content.confirmUnsaved = { _ in .discard }
        #expect(await content.open(try url("plan.md"), conversationID: "card-A"))
        #expect(content.selectedTab !== old)
        #expect(content.files.target.endpointID == "machine-B")
        #expect(await client.reads.count == 2)
    }

    @Test func reconnectRebindsEveryRetainedEditorWithoutReplacingDirtyBuffers() async throws {
        let firstClient = ConversationContentFilesFixture(), nextClient = ConversationContentFilesFixture()
        var currentClient = firstClient
        let content = ConversationContentModel()
        content.prepareScope = { id in self.scope(currentClient, cardID: id) }
        #expect(await content.open(try url("first.md"), conversationID: "card-A"))
        edit(content, text: "Keep first edits")
        let first = try #require(content.selectedTab)
        #expect(await content.open(try url("second.md"), conversationID: "card-A"))
        edit(content, text: "Keep second edits")
        let second = try #require(content.selectedTab)
        let firstSession = first.files.fileEditorSession, secondSession = second.files.fileEditorSession
        content.invalidateTransports()
        #expect(!first.files.isLive && !second.files.isLive)
        await first.files.saveCurrentDocument()
        #expect(await firstClient.saves.isEmpty)
        currentClient = nextClient
        await content.refreshBindings()
        #expect(first.files.fileEditorSession === firstSession)
        #expect(second.files.fileEditorSession === secondSession)
        #expect(firstSession.currentText() == "Keep first edits")
        #expect(secondSession.currentText() == "Keep second edits")
        await first.files.saveCurrentDocument()
        await second.files.saveCurrentDocument()
        #expect(await firstClient.saves.isEmpty)
        let writes = await nextClient.saves
        #expect(writes.map(\.path) == ["first.md", "second.md"])
        #expect(
            writes.allSatisfy { $0.cardID == "card-A" && $0.projectID == "project-A" && $0.revision == "revision-1" })
        #expect(!firstSession.isDirty && !secondSession.isDirty)
    }

    @Test func projectModeReviewUsesItsOwnProjectClientWithoutCardChangesetRPC() async throws {
        let files = ConversationContentFilesFixture(), projectClient = ConversationContentProjectReviewFixture()
        let content = ConversationContentModel()
        let globalRoute = ProjectChangesModel()
        globalRoute.bind(projectID: "unrelated-project", client: projectClient)
        content.prepareScope = { id in
            var value = self.scope(files, cardID: id)
            value.workspaceMode = "project"
            value.projectChangesClient = projectClient
            // No WorktreeRPC: project mode must not require or call it.
            return value
        }
        #expect(await content.openPanel(.review, conversationID: "card-A"))
        let tab = try #require(content.selectedTab)
        #expect(tab.usesProjectReview)
        #expect(tab.projectReview !== globalRoute)
        await tab.projectReview.refresh()
        await tab.projectReview.waitForDiff()
        #expect(await projectClient.projectReads == ["project-A"])
        let request = try #require(await projectClient.diffReads.first)
        #expect(request.projectID == "project-A")
        #expect(request.cardID.isEmpty)
        #expect(globalRoute.projectID == "unrelated-project")
        #expect(globalRoute.changes == nil)
        #expect(content.isPresented(for: "card-A"))
    }

    @Test func reconnectResumesScopedTerminalWatchUsingTheNewClient() async throws {
        let files = ConversationContentFilesFixture()
        let first = ConversationContentTerminalFixture(), next = ConversationContentTerminalFixture()
        var terminalClient = first
        let content = ConversationContentModel()
        content.prepareScope = { id in
            var value = self.scope(files, cardID: id); value.terminalsClient = terminalClient; return value
        }
        #expect(await content.openPanel(.terminal, conversationID: "card-A"))
        let tab = try #require(content.selectedTab)
        content.invalidateTransports()
        #expect(!tab.terminals.active)
        terminalClient = next
        await content.refreshBindings()
        #expect(content.selectedTab === tab)
        #expect(tab.terminals.active)
        #expect(await next.listings.count == 1)
        #expect(await first.closes == 0)
        #expect(await next.closes == 0)
        content.suspend()
        #expect(!tab.terminals.active)
        content.resume()
        #expect(tab.terminals.active)
        content.hide()
    }

    @Test func workspaceRootChangeDetachesOldClientsAndProtectsAnEditedFile() async throws {
        let client = ConversationContentFilesFixture(), content = model(client)
        #expect(await content.open(try url("plan.md"), conversationID: "card-A"))
        edit(content)
        let tab = try #require(content.selectedTab)
        let moved = ConversationContentScope(target: tab.files.target, rootPath: "/new/worktree", client: client)
        content.rebindRetainedTabs(scope: moved)
        #expect(!tab.files.isLive)
        #expect(tab.error?.contains("workspace moved") == true)
        await tab.files.saveCurrentDocument()
        #expect(await client.saves.isEmpty)
        #expect(tab.dirty)
    }

    @Test func presentedTitleSurvivesOrdinaryFileLinkFocus() async throws {
        let client = ConversationContentFilesFixture(), content = model(client)
        let link = try url("plan.md")
        #expect(await content.open(link, conversationID: "card-A", presentationTitle: "  Implementation plan  "))
        let tab = try #require(content.selectedTab)
        #expect(tab.title == "Implementation plan")
        #expect(await content.open(try url("./plan.md#L3"), conversationID: "card-A"))
        #expect(content.selectedTab === tab)
        #expect(tab.title == "Implementation plan")
    }

    @Test func inactiveTerminalCoordinatorDoesNotSendInputOrDelayedResize() async throws {
        var sends = 0, resizes = 0
        let coordinator = RemoteTerminalSurface.Coordinator(
            terminalID: "scoped-shell", send: { _ in sends += 1 }, resize: { _, _ in resizes += 1 })
        let view = RemoteTerminalView(frame: .zero, font: .monospacedSystemFont(ofSize: 13, weight: .regular))
        coordinator.active = false
        coordinator.send(source: view, data: [0x61][...])
        coordinator.sizeChanged(source: view, newCols: 80, newRows: 24)
        try await Task.sleep(for: .milliseconds(160))
        #expect(sends == 0 && resizes == 0)
        coordinator.active = true
        coordinator.sizeChanged(source: view, newCols: 100, newRows: 30)
        // Switching away before the debounce fires must also cancel its effect.
        coordinator.active = false
        try await Task.sleep(for: .milliseconds(160))
        #expect(resizes == 0)
    }

    @Test func successfulRebindClearsStaleConnectionAndWorkspaceErrorsWithoutLosingEdits() async throws {
        let client = ConversationContentFilesFixture(), content = model(client)
        #expect(await content.open(try url("plan.md"), conversationID: "card-A"))
        edit(content, text: "Retained through reconnect")
        let tab = try #require(content.selectedTab)
        let session = tab.files.fileEditorSession
        var unavailable = true
        content.prepareScope = { id in
            if unavailable { throw CocoaError(.fileReadNoPermission) }
            return self.scope(client, cardID: id)
        }
        await content.refreshBindings()
        #expect(content.error != nil)
        let moved = ConversationContentScope(target: tab.files.target, rootPath: "/moved/worktree", client: client)
        content.rebindRetainedTabs(scope: moved)
        #expect(tab.error != nil)
        #expect(!tab.files.isLive)
        unavailable = false
        await content.refreshBindings()
        #expect(content.error == nil)
        #expect(tab.error == nil)
        #expect(tab.files.isLive)
        #expect(tab.files.fileEditorSession === session)
        #expect(session.isDirty)
        #expect(session.currentText() == "Retained through reconnect")
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<1_000 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw CocoaError(.coderValueNotFound)
    }
}
