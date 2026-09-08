import AppKit
import DieterAPI
import Testing
@testable import DieterMac

@Test func captureBrowserURLKeepsOnlyWebPageURLs() {
    #expect(CaptureBrowserContext.validatedURL(" https://example.com/path?q=task#issue ") == "https://example.com/path?q=task#issue")
    #expect(CaptureBrowserContext.validatedURL("http://localhost:3000/issue") == "http://localhost:3000/issue")
    for value in ["", "Search or enter address", "file:///private/data", "javascript:alert(1)", "chrome://settings", "https://", "not a URL"] {
        #expect(CaptureBrowserContext.validatedURL(value) == nil)
    }
}

@Test func captureFromNonBrowserHasNoURL() async {
    let result = await CaptureBrowserContext.read(bundleID: "com.apple.finder", pid: nil)
    #expect(!result.browser)
    #expect(result.url.isEmpty)
}

@Test @MainActor func captureDoesNotReuseClipboardImageOnCancel() {
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    board.setData(bitmap.representation(using: .png, properties: [:])!, forType: .png)
    let count = board.changeCount
    #expect(TaskScreenCapture.capturedPNG(from: board, after: count) == nil)
    board.clearContents()
    board.setData(bitmap.tiffRepresentation!, forType: .tiff)
    let captured = TaskScreenCapture.capturedPNG(from: board, after: count)
    #expect(captured != nil)
    #expect(captured.flatMap { NSBitmapImageRep(data: $0) }?.pixelsWide == 2)
    board.clearContents()
    board.setString("Unrelated clipboard text", forType: .string)
    #expect(TaskScreenCapture.capturedPNG(from: board, after: count) == nil)
}

@Test func captureRoutesOnlyExactUnambiguousHostnames() {
    var project = Dieter_V1_Project(); project.id = "one"; project.hostnames = ["app.example.com", "localhost"]
    let browser = CaptureBrowserContext(url: "https://APP.example.com.:8443/path", browser: true)
    #expect(browser.matchingProjects([project]).map(\.id) == ["one"])
    #expect(CaptureBrowserContext(url: "https://app.example.com.evil.test", browser: true).matchingProjects([project]).isEmpty)
    #expect(CaptureBrowserContext(url: "https://example.com", browser: true).matchingProjects([project]).isEmpty)
    #expect(CaptureBrowserContext(url: "file:///app.example.com", browser: true).matchingProjects([project]).isEmpty)
    var other = project; other.id = "two"
    #expect(browser.matchingProjects([project, other]).count == 2)
    other.archived = true
    #expect(browser.matchingProjects([project, other]).map(\.id) == ["one"])
}

@Test func captureMatchesBoardHostnamesAcrossPathsAndPorts() {
    var board = Dieter_V1_Board(); board.id = "board"; board.hostnames = ["app.example.com"]
    #expect(CaptureBrowserContext(url: "https://app.example.com:8443/path", browser: true).matchingBoards([board]).map(\.id) == ["board"])
    #expect(CaptureBrowserContext(url: "https://other.example.com", browser: true).matchingBoards([board]).isEmpty)
}

@Test @MainActor func quickTaskDraftResetsForSubmissionAndNewAppSession() {
    let defaults = UserDefaults(suiteName: "quick-task-tests-" + UUID().uuidString)!
    let draft = QuickTaskFormState(defaults: defaults)
    draft.story = "Investigate this page"
    draft.sourceURL = "https://example.com/issue"
    draft.draftProjectID = "project"
    draft.draftBoardID = "board"
    draft.rememberHostname = true
    draft.provider = "codex"
    draft.model = "gpt-5.6-sol"
    draft.effort = "high"
    draft.providerOptions = ["fast_mode": "true"]
    draft.initialized = true
    let image = Dieter_V1_MessagePart()
    draft.attachments = [image]
    let newSession = QuickTaskFormState(defaults: defaults)
    #expect(newSession.draftProjectID == "project" && newSession.draftBoardID == "board")
    #expect(newSession.providerOptions["fast_mode"] == "true")
    #expect(newSession.provider == "codex" && newSession.model == "gpt-5.6-sol" && newSession.effort == "high")
    #expect(newSession.story.isEmpty && newSession.attachments.isEmpty)
    draft.reset()
    #expect(draft.story.isEmpty && draft.sourceURL.isEmpty && draft.attachments.isEmpty)
    #expect(draft.draftProjectID == "project" && draft.draftBoardID == "board")
    #expect(draft.providerOptions["fast_mode"] == "true" && !draft.rememberHostname && draft.initialized)
    draft.selectProject("second", boardIDs: ["first", "other"])
    #expect(draft.draftBoardID == "first")
    draft.draftBoardID = "other"
    draft.selectProject("project", boardIDs: ["board"])
    draft.selectProject("second", boardIDs: ["first", "other"])
    #expect(draft.draftBoardID == "other")
    draft.selectProject("second", boardIDs: ["first"])
    #expect(draft.draftBoardID == "first")
}
