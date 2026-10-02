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
