import AppKit
import Testing
@testable import DieterMac

@Test func markdownPreviewResourcesAreBundledAndRestrictAssetReads() throws {
    let directory = try #require(MarkdownPreviewResources.directory)
    for filename in ["index.html", "app.js", "app.css", "LICENSES.txt"] {
        let data = try Data(contentsOf: directory.appendingPathComponent(filename))
        #expect(!data.isEmpty, "Missing renderer resource: \(filename)")
    }
    #expect(MarkdownPreviewResources.filename(for: MarkdownPreviewResources.documentURL) == "index.html")
    #expect(MarkdownPreviewResources.filename(for: URL(string: "dieter-markdown://preview/app.js")!) == "app.js")
    for address in [
        "file:///etc/passwd", "https://preview/app.js", "dieter-markdown://other/app.js",
        "dieter-markdown://preview/secrets.txt", "dieter-markdown://preview/%2e%2e/secrets.txt",
        "dieter-markdown://preview/app.js?file=/etc/passwd", "dieter-markdown://user@preview/app.js",
        "dieter-markdown://preview:4018/app.js",
    ] {
        #expect(MarkdownPreviewResources.filename(for: URL(string: address)!) == nil, "Allowed \(address)")
    }
}

@Test func markdownPreviewOnlyOpensWebLinksAfterActivation() {
    let document = MarkdownPreviewResources.documentURL
    #expect(MarkdownPreviewNavigation.decide(url: document, userActivated: false, mainFrame: true) == .document)
    #expect(MarkdownPreviewNavigation.decide(url: document, userActivated: false, mainFrame: false) == .cancel)
    for address in ["https://example.com/guide", "http://localhost:4018/task"] {
        let url = URL(string: address)!
        #expect(MarkdownPreviewNavigation.decide(url: url, userActivated: true, mainFrame: true) == .externalLink)
        #expect(MarkdownPreviewNavigation.decide(url: url, userActivated: false, mainFrame: true) == .cancel)
    }
    for address in ["file:///tmp/document.md", "javascript:alert(1)", "data:text/html,hello", "mailto:a@example.com"] {
        #expect(
            MarkdownPreviewNavigation.decide(url: URL(string: address)!, userActivated: true, mainFrame: true)
                == .cancel)
    }
}

@Test func markdownPreviewCoalescesLoadingEditsAndRejectsOldCompletions() throws {
    var state = MarkdownPreviewRenderState()
    #expect(state.update(source: "first", theme: "light") == nil)
    #expect(state.update(source: "latest", theme: "light") == nil)
    let loadedRequest = state.loaded()
    let loaded = try #require(loadedRequest)
    #expect(loaded.source == "latest")
    let editedRequest = state.update(source: "unsaved edit", theme: "light")
    let edited = try #require(editedRequest)
    #expect(!state.accepts(loaded.revision))
    #expect(state.accepts(edited.revision))
    #expect(state.update(source: "unsaved edit", theme: "light") == nil)
    let darkRequest = state.update(source: "unsaved edit", theme: "dark")
    let dark = try #require(darkRequest)
    #expect(dark.source == edited.source && dark.theme == "dark")
    #expect(!state.accepts(edited.revision))
    state.dispose()
    #expect(!state.accepts(dark.revision))
    #expect(state.loaded() == nil)
    #expect(state.update(source: "late completion", theme: "light") == nil)
}

@Test func markdownRichEditsAcknowledgeTheirOwnEchoAndRejectStaleDocuments() throws {
    var state = MarkdownPreviewRenderState()
    _ = state.update(source: "original", theme: "light", editing: true)
    let request = state.loaded()
    let loaded = try #require(request)
    #expect(state.edited(source: "**edited**", revision: loaded.revision) == true)
    #expect(state.edited(source: "**edited twice**", revision: loaded.revision) == true)
    #expect(state.update(source: "**edited twice**", theme: "light", editing: true) == nil)
    #expect(state.latest?.revision == loaded.revision)
    let newer = state.update(source: "source edit", theme: "light", editing: true)
    #expect(newer != nil)
    #expect(state.edited(source: "late rich edit", revision: loaded.revision) == false)
    #expect(state.latest?.source == "source edit")
    let previewRequest = state.update(source: "source edit", theme: "light", editing: false)
    let preview = try #require(previewRequest)
    #expect(state.edited(source: "unexpected", revision: preview.revision) == false)
    state.dispose()
    #expect(state.edited(source: "detached", revision: preview.revision) == false)
}

@Test @MainActor func markdownClipboardKeepsExplicitFormatsAndSelectionPayload() throws {
    let payload = try #require(
        MarkdownClipboardPayload(body: [
            "markdown": "**Selected** text", "html": "<p><strong>Selected</strong> text</p>",
            "text": "Selected text",
        ]))
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    payload.write(to: pasteboard, richText: true)
    #expect(pasteboard.string(forType: .html) == payload.html)
    #expect(pasteboard.string(forType: .string) == "Selected text")
    payload.write(to: pasteboard, richText: false)
    #expect(pasteboard.string(forType: .string) == "**Selected** text")
    #expect(pasteboard.string(forType: .html) == nil)
    #expect(MarkdownClipboardPayload(body: ["markdown": "incomplete"]) == nil)
}
