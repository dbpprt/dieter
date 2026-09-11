import AppKit
import DieterAPI
import Testing
@testable import DieterMac

@Test func captureBrowserURLKeepsOnlyWebPageURLs() {
    #expect(
        CaptureBrowserContext.validatedURL(" https://example.com/path?q=task#issue ")
            == "https://example.com/path?q=task#issue")
    #expect(CaptureBrowserContext.validatedURL("http://localhost:3000/issue") == "http://localhost:3000/issue")
    for value in [
        "", "Search or enter address", "file:///private/data", "javascript:alert(1)", "chrome://settings", "https://",
        "not a URL",
    ] {
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
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
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
    #expect(
        CaptureBrowserContext(url: "https://app.example.com.evil.test", browser: true).matchingProjects([project])
            .isEmpty)
    #expect(CaptureBrowserContext(url: "https://example.com", browser: true).matchingProjects([project]).isEmpty)
    #expect(CaptureBrowserContext(url: "file:///app.example.com", browser: true).matchingProjects([project]).isEmpty)
    var other = project; other.id = "two"
    #expect(browser.matchingProjects([project, other]).count == 2)
    other.archived = true
    #expect(browser.matchingProjects([project, other]).map(\.id) == ["one"])
}

@Test func captureMatchesBoardHostnamesAcrossPathsAndPorts() {
    var board = Dieter_V1_Board(); board.id = "board"; board.hostnames = ["app.example.com"]
    #expect(
        CaptureBrowserContext(url: "https://app.example.com:8443/path", browser: true).matchingBoards([board]).map(\.id)
            == ["board"])
    #expect(CaptureBrowserContext(url: "https://other.example.com", browser: true).matchingBoards([board]).isEmpty)
}

@Test func captureSavedAddressRetainsExplicitPorts() {
    #expect(CaptureBrowserContext.hostname("http://127.0.0.1:4018/commitments/3") == "127.0.0.1:4018")
    #expect(CaptureBrowserContext.hostname("http://LOCALHOST.:04018/path?q=value") == "localhost:4018")
    #expect(CaptureBrowserContext.hostname("https://staging.example.com/commitments/3/data") == "staging.example.com")
    #expect(CaptureBrowserContext.hostname("https://example.com:443/path") == "example.com:443")
    #expect(CaptureBrowserContext.hostname("http://[::1]:4018/path") == "[::1]:4018")
    #expect(CaptureBrowserContext.hostname("http://[::1]/path") == "::1")
    #expect(CaptureBrowserContext.hostname("http://[0:0:0:0:0:0:0:1]:4018/path") == "[::1]:4018")
    #expect(CaptureBrowserContext.hostname("http://[::ffff:127.0.0.1]:4018/path") == "127.0.0.1:4018")
    #expect(CaptureBrowserContext.hostname("http://[::192.0.2.1]:4018/path") == "[::c000:201]:4018")
    #expect(CaptureBrowserContext.hostname("http://127.0.0.1:65536/path") == nil)
    #expect(CaptureBrowserContext.hostname("http://127.0.0.1:0/path") == nil)
}

@Test func captureRoutesLocalAppsByPortBeforeLegacyHostMappings() {
    var main = Dieter_V1_Board(); main.id = "main"; main.projectID = "adops"; main.hostnames = ["127.0.0.1"]
    var vms = main; vms.id = "vms"; vms.hostnames = ["127.0.0.1:4018"]
    var other = main; other.id = "other"; other.hostnames = ["127.0.0.1:4019"]
    let browser = CaptureBrowserContext(url: "http://127.0.0.1:4018/commitments/3", browser: true)
    #expect(browser.matchingBoards([main, other, vms]).map(\.id) == ["vms"])
    #expect(
        CaptureBrowserContext(url: "http://127.0.0.1:4019/different/path", browser: true)
            .matchingBoards([main, other, vms]).map(\.id) == ["other"])
    #expect(
        CaptureBrowserContext(url: "http://127.0.0.1:4020/path", browser: true)
            .matchingBoards([main, other, vms]).map(\.id) == ["main"])
    #expect(browser.matchingBoards([other]).isEmpty)
    main.hostnames = vms.hostnames
    // Equal specificity remains ambiguous; order must not silently pick a board.
    #expect(Set(browser.matchingBoards([main, other, vms]).map(\.id)) == ["main", "vms"])
    main.hostnames = []
    #expect(browser.matchingBoards([main, other, vms]).map(\.id) == ["vms"])
}

@Test func captureRoutingUsesEffectiveDefaultPortsAndBracketedIPv6() {
    var http = Dieter_V1_Board(); http.id = "http"; http.hostnames = ["example.com:80"]
    var https = http; https.id = "https"; https.hostnames = ["example.com:443"]
    #expect(
        CaptureBrowserContext(url: "http://example.com/path", browser: true)
            .matchingBoards([https, http]).map(\.id) == ["http"])
    #expect(
        CaptureBrowserContext(url: "https://example.com/path", browser: true)
            .matchingBoards([https, http]).map(\.id) == ["https"])
    var ipv6 = http; ipv6.id = "ipv6"; ipv6.hostnames = ["[::1]:4018"]
    #expect(
        CaptureBrowserContext(url: "http://[::1]:4018/path", browser: true)
            .matchingBoards([ipv6]).map(\.id) == ["ipv6"])
    #expect(CaptureBrowserContext(url: "http://[::1]:4019/path", browser: true).matchingBoards([ipv6]).isEmpty)
    #expect(
        CaptureBrowserContext(url: "http://[0:0:0:0:0:0:0:1]:4018/path", browser: true)
            .matchingBoards([ipv6]).map(\.id) == ["ipv6"])
    ipv6.hostnames = ["127.0.0.1:4018"]
    #expect(
        CaptureBrowserContext(url: "http://[::ffff:7f00:1]:4018/path", browser: true)
            .matchingBoards([ipv6]).map(\.id) == ["ipv6"])
}

@Test func captureProjectPortRoutingIgnoresArchivedProjects() {
    var general = Dieter_V1_Project(); general.id = "general"; general.hostnames = ["localhost"]
    var precise = general; precise.id = "precise"; precise.hostnames = ["localhost:4018"]
    let browser = CaptureBrowserContext(url: "http://localhost:4018/path", browser: true)
    #expect(browser.matchingProjects([general, precise]).map(\.id) == ["precise"])
    precise.archived = true
    #expect(browser.matchingProjects([general, precise]).map(\.id) == ["general"])
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
