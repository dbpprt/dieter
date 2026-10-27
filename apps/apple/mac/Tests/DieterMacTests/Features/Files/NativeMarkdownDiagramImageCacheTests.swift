import AppKit
import MarkdownEngine
import Testing
@testable import DieterMacKit

@MainActor
private func cachedVector() throws -> RenderedCodeBlockResult {
    _ = NSApplication.shared
    let label = NSTextField(labelWithString: "Cached vector text")
    label.frame = NSRect(x: 0, y: 0, width: 320, height: 120)
    let data = label.dataWithPDF(inside: label.bounds)
    let representation = try #require(NSPDFImageRep(data: data))
    let image = NSImage(size: label.bounds.size)
    image.addRepresentation(representation)
    image.cacheMode = .never
    return RenderedCodeBlockResult(image: image, size: image.size)
}

private func cachedKey(_ code: String, width: Int = 320, theme: String = "light") -> NativeMarkdownDiagramKey {
    .init(code: code, language: "mermaid", width: width, theme: theme)
}

@MainActor
private func cacheEventually(_ predicate: () -> Bool) async -> Bool {
    for _ in 0..<1000 {
        if predicate() { return true }
        await Task.yield()
    }
    return predicate()
}

@Test @MainActor func nativeDiagramImageCacheEvictsLeastRecentlyUsedVectorsWithinBothLimits() throws {
    let vector = try cachedVector()
    let cache = NativeMarkdownDiagramImageCache(maximumEntries: 2)
    let a = cachedKey("a"), b = cachedKey("b"), c = cachedKey("c")
    cache.insert(vector, for: a)
    cache.insert(vector, for: b)
    #expect(cache.result(for: a)?.image === vector.image)
    cache.insert(vector, for: c)
    #expect(cache.result(for: b) == nil)
    #expect(cache.result(for: a)?.image === vector.image && cache.result(for: c)?.image === vector.image)
    #expect(cache.cachedCount == 2)

    let cost =
        try #require(vector.image.representations.first as? NSPDFImageRep).pdfRepresentation.count
        + a.sourceID.byteCount
    let bounded = NativeMarkdownDiagramImageCache(maximumBytes: cost * 2 - 1)
    bounded.insert(vector, for: a)
    bounded.insert(vector, for: b)
    #expect(bounded.cachedCount == 1 && bounded.result(for: a) == nil)
    #expect(bounded.cachedBytes == cost && bounded.result(for: b)?.image === vector.image)
    bounded.insert(vector, for: cachedKey(String(repeating: "x", count: cost * 3)))
    #expect(bounded.cachedBytes == cost && bounded.cachedCount == 1, "Oversized output cannot evict reusable vectors")
    bounded.insert(RenderedCodeBlockResult(image: NSImage(size: vector.size), size: vector.size), for: c)
    #expect(bounded.cachedCount == 1, "Placeholders and nonvector images are never reused")
}

@Test @MainActor func nativeDiagramReopeningUsesCompletedVectorsAndKeysWidthThemeAndSource() async throws {
    let vector = try cachedVector()
    let images = NativeMarkdownDiagramImageCache()
    var calls = 0
    let render: NativeMarkdownDiagramRenderer.Render = { _ in
        calls += 1; return vector
    }
    let first = NativeMarkdownDiagramRenderer(imageCache: images, render: render)
    let code = "graph LR; A-->B;"
    _ = first.request(code: code, language: "mermaid", availableWidth: 320)
    let ready = await cacheEventually { first.cachedCount == 1 }
    #expect(ready && calls == 1 && images.cachedCount == 1)
    first.dispose()
    let reopened = NativeMarkdownDiagramRenderer(imageCache: images, render: render)
    defer { reopened.dispose() }
    #expect(reopened.request(code: code, language: "mermaid", availableWidth: 320)?.image === vector.image)
    #expect(reopened.cachedCount == 1 && reopened.pendingCount == 0 && calls == 1 && reopened.reuseCount == 1)
    _ = reopened.request(code: code, language: "mermaid", availableWidth: 640)
    let wider = await cacheEventually { calls == 2 && reopened.cachedCount == 1 }
    #expect(wider)
    reopened.updateAppearance(try #require(NSAppearance(named: .darkAqua)))
    _ = reopened.request(code: code, language: "mermaid", availableWidth: 640)
    let dark = await cacheEventually { calls == 3 && reopened.cachedCount == 1 }
    #expect(dark)
    _ = reopened.request(code: "graph LR; A-->Changed;", language: "mermaid", availableWidth: 640)
    let edited = await cacheEventually { calls == 4 && reopened.cachedCount == 2 }
    #expect(edited)
    reopened.updateAppearance(try #require(NSAppearance(named: .aqua)))
    #expect(reopened.request(code: code, language: "mermaid", availableWidth: 320)?.image === vector.image)
    #expect(calls == 4 && reopened.pendingCount == 0, "Returning to the original theme reuses its exact vector")
}

@Test @MainActor func nativeDiagramFailuresAreRetriedByANewReaderInsteadOfEnteringTheReusableCache() async {
    _ = NSApplication.shared
    let images = NativeMarkdownDiagramImageCache()
    var calls = 0
    for _ in 0..<2 {
        let renderer = NativeMarkdownDiagramRenderer(
            sourceOnFailure: true, imageCache: images,
            render: { _ in
                calls += 1
                throw NSError(domain: "Renderer unavailable", code: 1)
            })
        _ = renderer.request(code: "graph LR; A-->B;", language: "mermaid", availableWidth: 320)
        let failed = await cacheEventually { renderer.failedCount == 1 }
        #expect(failed && images.cachedCount == 0)
        renderer.dispose()
    }
    #expect(calls == 2)
}

@Test @MainActor func nativeDiagramDetachedMailModelsReleaseTheirOwnCacheAndRejectLateInsertions() async throws {
    let vector = try cachedVector()
    let first = MailModel(), second = MailModel()
    #expect(first.diagramImages !== second.diagramImages)
    let key = cachedKey("graph LR; A-->B;")
    first.diagramImages.insert(vector, for: key)
    #expect(first.diagramImages.cachedCount == 1 && second.diagramImages.cachedCount == 0)

    var finish: CheckedContinuation<RenderedCodeBlockResult, Error>?
    let renderer = NativeMarkdownDiagramRenderer(
        imageCache: first.diagramImages,
        render: { _ in
            try await withCheckedThrowingContinuation { finish = $0 }
        })
    defer { renderer.dispose() }
    _ = renderer.request(code: "graph LR; Pending-->Result;", language: "mermaid", availableWidth: 320)
    let started = await cacheEventually { finish != nil }
    #expect(started)
    first.detach()
    #expect(
        first.diagramImages.cachedCount == 0 && first.diagramImages.cachedBytes == 0
            && first.diagramImages.reuseCount == 0)
    finish?.resume(returning: vector)
    let completed = await cacheEventually { renderer.cachedCount == 1 }
    #expect(completed && first.diagramImages.cachedCount == 0, "Detached readers cannot repopulate a cleared cache")
}

@Test func nativeDiagramSourceMembershipMatchesLiteralUTF8IncludingUnicodeAndEmbeddedNUL() {
    let cases: [(String, String, Bool)] = [
        ("", "", true), ("x", "", false), ("abcdef", "abc", false), ("ab", "xabz", true),
        ("🙂", "café 🙂", true), ("é", "e\u{301}", false), ("e\u{301}", "é", false),
        ("a\0b", "before a\0b after", true), ("ab", "a\0b", false),
        (String(repeating: "abc", count: 1000) + "end", String(repeating: "abc", count: 2000) + "end", true),
    ]
    for (code, document, expected) in cases {
        let source = NativeMarkdownDiagramSource(code: code, language: "mermaid")
        #expect(source.isPresent(in: document) == expected)
        let bridged = (NSMutableString(string: document) as String)
        #expect(source.isPresent(in: bridged) == expected)
    }
}

@Test @MainActor func nativeDiagramCacheKeysKeepByteDistinctJSONStringsSeparate() throws {
    let first = cachedKey("{\"text\":\"café\"}")
    let second = cachedKey("{\"text\":\"cafe\u{301}\"}")
    #expect(first.code == second.code, "Swift strings compare canonically equivalent text as equal")
    #expect(
        first != second && Set([first, second]).count == 2, "JavaScript/JSON field names and values are byte-sensitive")
    let images = NativeMarkdownDiagramImageCache()
    let vector = try cachedVector()
    images.insert(vector, for: first)
    #expect(images.result(for: second) == nil)
    let bridged = cachedKey(NSMutableString(string: first.code) as String)
    #expect(first == bridged && images.result(for: bridged)?.image === vector.image)
}
