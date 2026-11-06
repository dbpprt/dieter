import AppKit
import Testing
@testable import DieterMacKit

@Test func markdownPreviewResourcesResolveInsidePackagedAppWithoutCheckoutFallback() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let app = root.appendingPathComponent("Dieter.app")
    let contents = app.appendingPathComponent("Contents")
    let resources = contents.appendingPathComponent("Resources")
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    let info: [String: String] = ["CFBundleIdentifier": "com.getdieter.export-test", "CFBundlePackageType": "APPL"]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        .write(to: contents.appendingPathComponent("Info.plist"))
    let application = try #require(Bundle(url: app))
    #expect(MarkdownPreviewResources.directory(in: application) == nil)

    let bundled = resources.appendingPathComponent("DieterMac_DieterMacKit.bundle")
    let preview = bundled.appendingPathComponent("MarkdownPreview")
    try FileManager.default.createDirectory(at: preview, withIntermediateDirectories: true)
    let source = try #require(MarkdownPreviewResources.directory)
    for filename in ["index.html", "app.js", "app.css", "LICENSES.txt"] {
        try FileManager.default.copyItem(
            at: source.appendingPathComponent(filename), to: preview.appendingPathComponent(filename))
    }
    let resolved = try #require(MarkdownPreviewResources.directory(in: application))
    #expect(resolved.resolvingSymlinksInPath() == preview.resolvingSymlinksInPath())
    #expect(try Data(contentsOf: resolved.appendingPathComponent("app.js")).isEmpty == false)
}

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
