import AppKit
import MarkdownEngine
import Testing
@testable import DieterMac

@MainActor
private final class ControlledDiagramRendering {
    private(set) var keys: [NativeMarkdownDiagramKey] = []
    private var pending: [NativeMarkdownDiagramKey: CheckedContinuation<RenderedCodeBlockResult, Error>] = [:]

    func render(_ key: NativeMarkdownDiagramKey) async throws -> RenderedCodeBlockResult {
        keys.append(key)
        return try await withCheckedThrowingContinuation { pending[key] = $0 }
    }

    func finish(_ key: NativeMarkdownDiagramKey, image: NSImage) {
        pending.removeValue(forKey: key)?.resume(returning: RenderedCodeBlockResult(image: image, size: image.size))
    }
}

@MainActor
private func diagramEventually(_ predicate: () -> Bool) async -> Bool {
    // All work is injected and actor-local. Yield to its worker without any
    // WebKit process, display timing, or fixed-duration sleeps.
    for _ in 0..<1000 {
        if predicate() { return true }
        await Task.yield()
    }
    return predicate()
}

@Test @MainActor func nativeDiagramRendererCachesCompletedImagesAndDeduplicatesPendingRequests() async throws {
    _ = NSApplication.shared
    let controlled = ControlledDiagramRendering()
    let renderer = NativeMarkdownDiagramRenderer(render: controlled.render)
    let original = renderer.fingerprint()
    let loading = try #require(renderer.request(code: "graph LR; A-->B", language: "mermaid", availableWidth: 420))
    for _ in 0..<20 {
        let repeated = try #require(
            renderer.request(code: "graph LR; A-->B", language: "mermaid", availableWidth: 420.9))
        #expect(repeated.image === loading.image)
    }
    let started = await diagramEventually { controlled.keys.count == 1 }
    #expect(started)
    let key = try #require(controlled.keys.first)
    #expect(key.width == 420)
    let finishedImage = NSImage(size: NSSize(width: 420, height: 180))
    controlled.finish(key, image: finishedImage)
    let completed = await diagramEventually { renderer.cachedCount == 1 }
    #expect(completed)
    let cached = try #require(renderer.request(code: key.code, language: key.language, availableWidth: 420))
    #expect(cached.image === finishedImage)
    #expect(cached.size == NSSize(width: 420, height: 180))
    #expect(controlled.keys.count == 1 && renderer.pendingCount == 0)
    #expect(renderer.fingerprint() != original)
}

@Test @MainActor func nativeDiagramRendererRejectsStaleWidthAndAppearanceCompletions() async throws {
    _ = NSApplication.shared
    for changesTheme in [false, true] {
        let controlled = ControlledDiagramRendering()
        let renderer = NativeMarkdownDiagramRenderer(render: controlled.render)
        _ = renderer.request(code: "graph LR; A-->B", language: "mermaid", availableWidth: 320)
        let firstStarted = await diagramEventually { controlled.keys.count == 1 }
        #expect(firstStarted)
        let old = try #require(controlled.keys.first)
        if changesTheme {
            renderer.updateAppearance(try #require(NSAppearance(named: .darkAqua)))
        }
        let width: CGFloat = changesTheme ? 320 : 640
        _ = renderer.request(code: old.code, language: old.language, availableWidth: width)
        let staleImage = NSImage(size: NSSize(width: 320, height: 90))
        controlled.finish(old, image: staleImage)
        let nextStarted = await diagramEventually { controlled.keys.count == 2 }
        #expect(nextStarted)
        #expect(renderer.cachedCount == 0, "An old-width or old-theme completion cannot populate the current cache")
        let latest = try #require(controlled.keys.last)
        #expect(latest.width == Int(width))
        #expect(latest.theme == (changesTheme ? "dark" : "light"))
        let latestImage = NSImage(size: NSSize(width: width, height: 200))
        controlled.finish(latest, image: latestImage)
        let completed = await diagramEventually { renderer.cachedCount == 1 }
        #expect(completed)
        let rendered = try #require(renderer.request(code: old.code, language: old.language, availableWidth: width))
        #expect(rendered.image === latestImage)
        #expect(rendered.image !== staleImage)
        #expect(controlled.keys.count == 2)
    }
}

@Test @MainActor func nativeDiagramRendererBoundsAdmissionDuringRepeatedNativeRestyling() async throws {
    _ = NSApplication.shared
    var keys: [NativeMarkdownDiagramKey] = []
    let image = NSImage(size: NSSize(width: 20, height: 10))
    let renderer = NativeMarkdownDiagramRenderer(
        maximumEntries: 3,
        render: { key in
            keys.append(key)
            return RenderedCodeBlockResult(image: image, size: image.size)
        })
    // A synchronous layout pass asks for more blocks than the cache admits.
    // Repeated passes must neither queue duplicates nor churn recent images.
    for _ in 0..<5 {
        for index in 0..<24 {
            _ = renderer.request(code: "graph LR; A-->B\(index)", language: "mermaid", availableWidth: 320)
        }
    }
    #expect(renderer.pendingCount == 3)
    let completed = await diagramEventually { renderer.cachedCount == 3 && renderer.pendingCount == 0 }
    #expect(completed)
    #expect(keys.count == 3)
    for _ in 0..<5 {
        for index in 0..<24 {
            _ = renderer.request(code: "graph LR; A-->B\(index)", language: "mermaid", availableWidth: 320)
        }
    }
    #expect(renderer.cachedCount == 3 && renderer.pendingCount == 0)
    #expect(keys.count == 3)
}

@Test @MainActor func nativeDiagramRendererRejectsInvalidInputsBeforeCallingItsRenderer() {
    _ = NSApplication.shared
    var calls = 0
    let renderer = NativeMarkdownDiagramRenderer(render: { _ in
        calls += 1
        return RenderedCodeBlockResult(image: NSImage(size: .zero), size: .zero)
    })
    for width in [CGFloat.zero, -.infinity, .infinity, .nan, -1] {
        #expect(renderer.request(code: "graph LR; A-->B", language: "mermaid", availableWidth: width) == nil)
    }
    #expect(renderer.request(code: "anything", language: "html", availableWidth: 320) == nil)
    let oversized = renderer.request(
        code: String(repeating: "é", count: 500_001), language: "mermaid", availableWidth: 320)
    #expect(oversized?.image.accessibilityDescription?.contains("1 MB") == true)
    #expect(calls == 0 && renderer.cachedCount == 0 && renderer.pendingCount == 0)
}

@Test @MainActor func nativeDiagramRendererFitsEveryReportChartWithinTheBitmapBudget() async throws {
    _ = NSApplication.shared
    let size = NSSize(width: 900, height: 500)
    var keys: [NativeMarkdownDiagramKey] = []
    let budget = 512 * 1024
    let renderer = NativeMarkdownDiagramRenderer(
        maximumBytes: budget,
        render: { key in
            keys.append(key)
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 1800, pixelsHigh: 1000,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 1800 * 4, bitsPerPixel: 32)!
            let context = NSGraphicsContext(bitmapImageRep: bitmap)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            NSColor.systemBlue.setFill()
            NSRect(x: 0, y: 0, width: 1800, height: 1000).fill()
            NSGraphicsContext.restoreGraphicsState()
            bitmap.size = size
            let image = NSImage(size: size)
            image.addRepresentation(bitmap)
            return RenderedCodeBlockResult(image: image, size: size)
        })
    defer { renderer.dispose() }
    let sources = (0..<9).map { "{\"mark\":\"bar\",\"data\":{\"values\":[{\"value\":\($0)}]}}" }
    renderer.synchronizeSource(sources.map { "```vega-lite\n\($0)\n```" }.joined(separator: "\n"))
    for source in sources {
        _ = renderer.request(code: source, language: "vega-lite", availableWidth: size.width)
    }
    let completed = await diagramEventually { renderer.cachedCount == sources.count }
    #expect(completed)
    #expect(renderer.cachedBytes <= budget)
    // The report has seven large charts; exercise more than that with a much
    // smaller budget. Every result must remain a real, correctly sized image.
    for source in sources {
        let result = try #require(renderer.request(code: source, language: "vega-lite", availableWidth: size.width))
        #expect(result.size == size && result.image.size == size)
        #expect(result.image.accessibilityDescription?.contains("Preview limit") != true)
        let bitmap = try #require(result.image.representations.first as? NSBitmapImageRep)
        let color = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2))
        #expect(color.alphaComponent > 0.9)
        #expect(bitmap.pixelsWide < 1800 && bitmap.pixelsHigh < 1000)
    }
    for _ in 0..<10 {
        for source in sources { _ = renderer.request(code: source, language: "vega-lite", availableWidth: size.width) }
    }
    #expect(keys.count == sources.count, "Cache pressure must never rerender a completed chart")
    #expect(renderer.pendingCount == 0 && renderer.cachedBytes <= budget)
}

@Test @MainActor func nativeDiagramRendererDrainsMoreThanSixteenChartsWithoutAnotherLayoutRequest() async {
    _ = NSApplication.shared
    var calls = 0
    let image = NSImage(size: NSSize(width: 100, height: 40))
    let renderer = NativeMarkdownDiagramRenderer(render: { _ in
        calls += 1
        return RenderedCodeBlockResult(image: image, size: image.size)
    })
    defer { renderer.dispose() }
    for index in 0..<24 {
        _ = renderer.request(code: "graph LR; Item_\(index)-->Done;", language: "mermaid", availableWidth: 320)
    }
    #expect(renderer.pendingCount == 24)
    let completed = await diagramEventually { renderer.cachedCount == 24 }
    #expect(completed && calls == 24 && renderer.pendingCount == 0)
}
