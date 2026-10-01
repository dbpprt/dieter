import AppKit
import DieterAPI
import DieterCore
import SharedCore
import Testing
@testable import DieterMac

private actor FilesFixture: FilesRPC {
    var saveRequest: Dieter_V1_SaveFileRequest?
    var pendingSave: CheckedContinuation<Dieter_V1_FileDocument, Error>?
    var pendingDelete: CheckedContinuation<Void, Error>?
    var saveCount = 0

    func listFiles(_ request: Dieter_V1_ListFilesRequest) async throws -> Dieter_V1_FileList {
        var value = Dieter_V1_FileList(); value.path = request.path; return value
    }
    func readFile(_ request: Dieter_V1_ReadFileRequest) async throws -> Dieter_V1_FileDocument {
        var value = Dieter_V1_FileDocument()
        value.path = request.path; value.name = request.path; value.content = request.projectID; value.revision = "1"
        return value
    }
    func saveFile(_ request: Dieter_V1_SaveFileRequest) async throws -> Dieter_V1_FileDocument {
        saveRequest = request; saveCount += 1
        return try await withCheckedThrowingContinuation { pendingSave = $0 }
    }
    func finishSave() {
        var value = Dieter_V1_FileDocument()
        value.path = saveRequest!.path; value.content = saveRequest!.content; value.revision = "2"
        pendingSave?.resume(returning: value); pendingSave = nil
    }
    func createFile(_ request: Dieter_V1_CreateFileRequest) async throws -> Dieter_V1_FileEntry { .init() }
    func moveFile(_ request: Dieter_V1_MoveFileRequest) async throws -> Dieter_V1_MoveFileResponse { .init() }
    func deleteFile(_ request: Dieter_V1_DeleteFileRequest) async throws {
        try await withCheckedThrowingContinuation { pendingDelete = $0 }
    }
    func finishDelete() { pendingDelete?.resume(); pendingDelete = nil }
    var saving: Bool { pendingSave != nil }
    var deleting: Bool { pendingDelete != nil }
}

@MainActor private func waitForFiles(_ condition: () async -> Bool) async throws {
    for _ in 0..<1_000 {
        if await condition() { return }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    throw CocoaError(.coderValueNotFound)
}

@Test @MainActor func filesSaveAcknowledgementPreservesNewerEditsAndSerializesSaves() async throws {
    let client = FilesFixture(), core = FilesCoreDouble.core(over: client), model = FilesModel()
    model.bind(target: .init(endpointID: "gateway#machine", projectID: "project"), core: core)
    model.isLive = true
    await model.openFile(path: "file.swift")
    let editor = NSTextView()
    model.fileEditorSession.attach(editor, documentKey: model.documentKey, initialText: "project")
    editor.string = "edit A"; model.fileEditorSession.didEdit(lineDelta: 0)
    let save = Task { await model.saveCurrentDocument() }
    try await waitForFiles { await client.saving }
    editor.string = "edit B"; model.fileEditorSession.didEdit(lineDelta: 0)
    await model.saveCurrentDocument()
    #expect(await client.saveCount == 1)
    await client.finishSave(); await save.value
    #expect(editor.string == "edit B")
    #expect(model.fileEditorSession.isDirty)
    #expect(model.fileDocument?.revision == "2")
    // SwiftUI updates must retain the same identity, including after reattachment.
    let replacement = NSTextView()
    model.fileEditorSession.attach(replacement, documentKey: model.documentKey, initialText: "edit A")
    #expect(replacement.string == "edit B")
    let secondSave = Task { await model.saveCurrentDocument() }
    try await waitForFiles { await client.saving }
    #expect(await client.saveRequest?.revision == "2")
    await client.finishSave(); await secondSave.value
    #expect(!model.fileEditorSession.isDirty)
}

@Test @MainActor func filesLateSaveCannotReplaceAnotherProjectDocument() async throws {
    let client = FilesFixture(), core = FilesCoreDouble.core(over: client), model = FilesModel()
    model.bind(target: .init(endpointID: "gateway#machine", projectID: "A"), core: core)
    model.isLive = true
    await model.openFile(path: "same.swift")
    let save = Task { await model.saveFile(content: "A changed") }
    try await waitForFiles { await client.saving }
    model.bind(target: .init(endpointID: "gateway#machine", projectID: "B"), core: core)
    await model.openFile(path: "same.swift")
    await client.finishSave()
    #expect(await save.value == nil)
    #expect(model.fileDocument?.content == "B")
    #expect(model.fileEditorSession.currentText() == "B")
}

@Test @MainActor func filesLateDeleteCannotClearTheCurrentDocument() async throws {
    let client = FilesFixture(), core = FilesCoreDouble.core(over: client), model = FilesModel()
    model.bind(target: .init(endpointID: "gateway#machine", projectID: "A"), core: core)
    model.isLive = true
    await model.openFile(path: "deleted.swift")
    let deletion = Task { await model.deleteFile(path: "deleted.swift", recursive: false) }
    try await waitForFiles { await client.deleting }
    await model.openFile(path: "retained.swift")
    await client.finishDelete(); await deletion.value
    #expect(model.fileDocument?.path == "retained.swift")
}

@Test @MainActor func filesFolderHistoryIsTheCoresAndTheModelStepsThroughIt() async throws {
    let core = ScriptedCoreClient(), model = FilesModel()
    core.handler = { command in
        var slice = ClientFilesSlice()
        slice.target = .with { $0.daemonID = "machine"; $0.projectID = "project" }
        switch command.files.action {
        case .navigate(let path)?: slice.directory = path.path; slice.canGoBack = true
        case .back?: slice.canGoForward = true
        default: break
        }
        return .with { $0.files = slice }
    }
    model.bind(target: .init(endpointID: "gateway#machine", projectID: "project"), core: core)
    await model.navigateFiles(to: "apps")
    #expect(model.filePath == "apps")
    #expect(model.fileNavigation == ProjectFileNavigation(canGoBack: true, canGoForward: false))
    await model.navigateFilesBack()
    #expect(model.filePath == "")
    #expect(model.fileNavigation == ProjectFileNavigation(canGoBack: false, canGoForward: true))
    #expect(
        core.commands.map(\.files.action) == [
            .bind(.with { $0.daemonID = "machine"; $0.projectID = "project" }),
            .navigate(.with { $0.path = "apps" }), .back(ClientFilesStep()),
        ])
}

@Test @MainActor func filesIgnoreTheSurfaceOfAPreviousTarget() async throws {
    let core = ScriptedCoreClient(), model = FilesModel()
    core.handler = { _ in .with { $0.done = ClientDone() } }
    model.bind(target: .init(endpointID: "gateway#machine", projectID: "B"), core: core)
    await model.loadFiles()
    let scope = try #require(core.commands.first?.files.scope)
    core.emit(.files, scope: scope) {
        $0.files = .with {
            $0.target = .with { $0.daemonID = "machine"; $0.projectID = "A" }
            $0.directory = "stale"
        }
    }
    #expect(model.filePath == "")
    core.emit(.files, scope: scope) {
        $0.files = .with {
            $0.target = .with { $0.daemonID = "machine"; $0.projectID = "B" }
            $0.directory = "current"
        }
    }
    #expect(model.filePath == "current")
}

@Test @MainActor func filesRefuseChangesWhileTheirWorkspaceIsNotLive() async throws {
    let client = FilesFixture(), core = FilesCoreDouble.core(over: client), model = FilesModel()
    model.bind(target: .init(endpointID: "gateway#machine", projectID: "project"), core: core)
    await model.openFile(path: "file.swift")
    #expect(model.fileDocument != nil)
    #expect(await model.saveFile(content: "changed") == nil)
    await model.createFile(path: "new.swift", directory: false)
    await model.deleteFile(path: "file.swift", recursive: false)
    #expect(await client.saveCount == 0)
    let changes = core.commands.filter {
        switch $0.files.action {
        case .save?, .create?, .delete?: true
        default: false
        }
    }
    #expect(changes.isEmpty)
}
