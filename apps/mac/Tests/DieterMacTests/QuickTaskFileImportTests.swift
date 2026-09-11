import AppKit
import DieterAPI
import Testing
@testable import DieterMac

@MainActor
struct QuickTaskFileImportTests {
    @Test func boardButtonOverridesRememberedDestinationWithoutReplacingDraftSettings() {
        let draft = makeDraft()
        draft.selectBoardContext(projectID: "old-project", boardID: "old-board")
        draft.initialized = true
        draft.story = "Keep my unfinished task"
        draft.sourceURL = "https://example.com/page"
        draft.provider = "codex"
        draft.model = "gpt-5.6-sol"
        draft.effort = "high"
        draft.providerOptions = ["fast_mode": "true"]
        draft.attachments = [part("existing.txt")]
        draft.selectBoardContext(projectID: "current-project", boardID: "current-board")
        // Popover initialization reconciles available boards on every open.
        draft.selectProject("current-project", boardIDs: ["first-board", "current-board"])
        #expect(draft.draftProjectID == "current-project" && draft.draftBoardID == "current-board")
        #expect(draft.story == "Keep my unfinished task" && draft.sourceURL == "https://example.com/page")
        #expect(draft.provider == "codex" && draft.model == "gpt-5.6-sol" && draft.effort == "high")
        #expect(draft.providerOptions == ["fast_mode": "true"] && draft.attachments.count == 1)
        draft.selectProject("old-project", boardIDs: ["old-board", "other"])
        #expect(draft.draftBoardID == "old-board", "Global project selection still remembers each project's board")
    }

    @Test func fileSelectionLoadsIntoTheRetainedDraftAfterPopoverDismissal() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("notes.txt")
        try Data("Actual selected file".utf8).write(to: file)
        let draft = makeDraft()
        draft.story = "A draft survives the picker"
        draft.attachments = [part("existing.txt")]
        var presented = true
        let loader = AttachmentLoader()
        await draft.importFiles(
            pick: {
                presented = false; return [file]
            },
            load: { try await loader.parts(urls: $0) },
            restorePresentation: { presented = true })
        #expect(presented && draft.attachmentImportID == nil)
        #expect(draft.story == "A draft survives the picker")
        #expect(draft.attachments.map(\.filename) == ["existing.txt", "notes.txt"])
        #expect(draft.attachments.last?.data == Data("Actual selected file".utf8))
        #expect(draft.attachmentError == nil)
    }

    @Test func cancelledAndFailedImportsRestoreTheDraftWithoutRemovingAttachments() async {
        let draft = makeDraft()
        draft.story = "Keep this"
        draft.attachments = [part("existing.txt")]
        var completions = 0
        await draft.importFiles(
            pick: { nil },
            load: { _ in
                Issue.record("Cancel must not load files"); return []
            },
            restorePresentation: { completions += 1 })
        #expect(completions == 1 && draft.attachmentError == nil)
        await draft.importFiles(
            pick: { [URL(fileURLWithPath: "/fixture/invalid")] },
            load: { _ in throw DieterAttachmentError.notAFile("invalid") },
            restorePresentation: { completions += 1 })
        #expect(completions == 2 && draft.attachmentError != nil)
        #expect(draft.story == "Keep this" && draft.attachments.map(\.filename) == ["existing.txt"])
        #expect(draft.attachmentImportID == nil)
    }

    @Test func delayedUploadMergesWithCurrentAttachmentsAndIgnoresDuplicateRequests() async throws {
        let draft = makeDraft()
        draft.attachments = [part("first.txt")]
        let gate = QuickTaskLoadGate()
        var completions = 0
        let operation = Task { @MainActor in
            await draft.importFiles(
                pick: { [URL(fileURLWithPath: "/fixture/selected.txt")] },
                load: { _ in await gate.wait() }, restorePresentation: { completions += 1 })
        }
        try await waitForLoad(gate)
        await draft.importFiles(
            pick: {
                Issue.record("A second picker must not open"); return nil
            }, load: { _ in [] },
            restorePresentation: { completions += 1 })
        try draft.appendAttachments([part("pasted.txt")], generation: draft.intakeGeneration)
        gate.finish([part("selected.txt")])
        await operation.value
        #expect(draft.attachments.map(\.filename) == ["first.txt", "pasted.txt", "selected.txt"])
        #expect(completions == 1)
    }

    @Test func resettingDraftRejectsAnOlderUploadAndDoesNotReopenTheSubmittedForm() async throws {
        let draft = makeDraft()
        draft.story = "Old task"
        let gate = QuickTaskLoadGate()
        var reopened = false
        let operation = Task { @MainActor in
            await draft.importFiles(
                pick: { [URL(fileURLWithPath: "/fixture/selected.txt")] },
                load: { _ in await gate.wait() }, restorePresentation: { reopened = true })
        }
        try await waitForLoad(gate)
        let oldGeneration = draft.intakeGeneration
        draft.reset()
        draft.story = "New task"
        try draft.appendAttachments([part("old-drop.txt")], generation: oldGeneration)
        gate.finish([part("old-upload.txt")])
        await operation.value
        #expect(draft.story == "New task" && draft.attachments.isEmpty)
        #expect(!reopened && draft.attachmentImportID == nil)
    }

    private func makeDraft() -> QuickTaskFormState {
        QuickTaskFormState(defaults: UserDefaults(suiteName: "quick-task-import-" + UUID().uuidString)!)
    }

    private func part(_ filename: String) -> Dieter_V1_MessagePart {
        var part = Dieter_V1_MessagePart()
        part.type = "file"
        part.filename = filename
        part.mediaType = "text/plain"
        part.data = Data(filename.utf8)
        return part
    }

    private func waitForLoad(_ gate: QuickTaskLoadGate) async throws {
        for _ in 0..<100 {
            if gate.continuation != nil { return }
            await Task.yield()
        }
        try #require(gate.continuation != nil)
    }
}

@MainActor
private final class QuickTaskLoadGate {
    var continuation: CheckedContinuation<[Dieter_V1_MessagePart], Never>?

    func wait() async -> [Dieter_V1_MessagePart] {
        await withCheckedContinuation { continuation = $0 }
    }

    func finish(_ parts: [Dieter_V1_MessagePart]) {
        continuation?.resume(returning: parts)
        continuation = nil
    }
}
