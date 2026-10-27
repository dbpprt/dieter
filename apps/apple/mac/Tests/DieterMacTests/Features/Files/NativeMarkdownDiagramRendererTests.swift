import AppKit
import MarkdownEngine
import PDFKit
import Testing
@testable import DieterMacKit

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

@Test @MainActor func nativeDiagramRendererKeepsVectorReportSharpWithinTheCacheBudget() async throws {
    _ = NSApplication.shared
    let size = NSSize(width: 900, height: 500)
    let view = NSTextField(labelWithString: "Chart detail remains vector text")
    view.frame = NSRect(origin: .zero, size: size)
    let data = view.dataWithPDF(inside: view.bounds)
    let representation = try #require(NSPDFImageRep(data: data))
    let image = NSImage(size: size)
    image.addRepresentation(representation)
    image.cacheMode = .never
    var calls = 0
    let budget = 512 * 1024
    let renderer = NativeMarkdownDiagramRenderer(
        maximumBytes: budget,
        render: { _ in
            calls += 1
            return RenderedCodeBlockResult(image: image, size: size)
        })
    defer { renderer.dispose() }
    let sources = (0..<24).map { "graph LR; Item_\($0)-->Done;" }
    renderer.synchronizeSource(sources.joined(separator: "\n"))
    for source in sources { _ = renderer.request(code: source, language: "mermaid", availableWidth: size.width) }
    let completed = await diagramEventually { renderer.cachedCount == sources.count }
    #expect(completed)
    #expect(renderer.cachedBytes <= budget)
    for _ in 0..<10 {
        for source in sources {
            let result = try #require(renderer.request(code: source, language: "mermaid", availableWidth: size.width))
            #expect(result.size == size && result.image.size == size)
            #expect(result.image === image, "Cache pressure must not replace vectors with low resolution bitmaps")
            let pdf = try #require(result.image.representations.first as? NSPDFImageRep)
            #expect(pdf.pdfRepresentation == data)
            #expect(PDFDocument(data: data)?.string?.contains("Chart detail remains vector text") == true)
        }
    }
    #expect(calls == sources.count && renderer.failedCount == 0 && renderer.pendingCount == 0)
}

@Test @MainActor func nativeDiagramRendererFallsBackWithoutBlurringOrRetryingWhenOutputExceedsBudget() async throws {
    _ = NSApplication.shared
    for sourceOnFailure in [false, true] {
        var calls = 0
        let renderer = NativeMarkdownDiagramRenderer(
            maximumBytes: 1024, sourceOnFailure: sourceOnFailure,
            render: { _ in
                calls += 1
                let image = NSImage(size: NSSize(width: 900, height: 500))
                image.addRepresentation(
                    NSBitmapImageRep(
                        bitmapDataPlanes: nil, pixelsWide: 1800, pixelsHigh: 1000,
                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                        colorSpaceName: .deviceRGB, bytesPerRow: 7200, bitsPerPixel: 32)!)
                return RenderedCodeBlockResult(image: image, size: image.size)
            })
        defer { renderer.dispose() }
        let code = "graph LR; Large-->Output;"
        _ = renderer.request(code: code, language: "mermaid", availableWidth: 900)
        let completed = await diagramEventually { renderer.failedCount == 1 }
        #expect(completed && renderer.cachedCount == 0 && renderer.cachedBytes <= 1024)
        for _ in 0..<10 {
            let result = renderer.request(code: code, language: "mermaid", availableWidth: 900)
            if sourceOnFailure {
                #expect(result == nil && renderer.shouldRevealSource(code: code, language: "mermaid"))
            } else {
                #expect(result?.image.accessibilityDescription?.contains("memory limit") == true)
            }
        }
        #expect(calls == 1 && renderer.pendingCount == 0)
    }
}

@Test @MainActor func nativeDiagramRendererOverlapsTwoIndependentBlocksAndBoundsThePool() async throws {
    _ = NSApplication.shared
    let controlled = ControlledDiagramRendering()
    let renderer = NativeMarkdownDiagramRenderer(render: controlled.render)
    defer { renderer.dispose() }
    let image = NSImage(size: NSSize(width: 100, height: 40))
    for index in 0..<6 {
        _ = renderer.request(code: "graph LR; Item_\(index)-->Done;", language: "mermaid", availableWidth: 320)
    }
    let started = await diagramEventually { controlled.keys.count == 2 }
    #expect(started && renderer.pendingCount == 4, "Two blocks start before either completes")
    // A slow first diagram cannot block the second result or its replacement.
    for (completedIndex, keyIndex) in [1, 0, 2, 3, 4, 5].enumerated() {
        let available = await diagramEventually { controlled.keys.count > keyIndex }
        #expect(available)
        controlled.finish(try #require(controlled.keys.dropFirst(keyIndex).first), image: image)
        let completed = await diagramEventually { renderer.cachedCount == completedIndex + 1 }
        #expect(completed)
        #expect(controlled.keys.count <= min(6, completedIndex + 3), "Completion admits only one replacement")
    }
    #expect(controlled.keys.count == 6 && renderer.pendingCount == 0)
}

@Test @MainActor func nativeDiagramRendererSuspendsAndResumesEveryActiveSlot() async throws {
    _ = NSApplication.shared
    let controlled = ControlledDiagramRendering()
    let renderer = NativeMarkdownDiagramRenderer(render: controlled.render)
    defer { renderer.dispose() }
    let image = NSImage(size: NSSize(width: 100, height: 40))
    for index in 0..<3 {
        _ = renderer.request(code: "graph LR; Item_\(index)-->Done;", language: "mermaid", availableWidth: 320)
    }
    let started = await diagramEventually { controlled.keys.count == 2 }
    #expect(started)
    let stale = controlled.keys
    renderer.setActive(false)
    for key in stale { controlled.finish(key, image: image) }
    _ = await diagramEventually { renderer.pendingCount == 3 }
    #expect(renderer.cachedCount == 0 && renderer.pendingCount == 3)
    renderer.setActive(true)
    let resumed = await diagramEventually { controlled.keys.count == 4 }
    #expect(resumed)
    for key in controlled.keys.dropFirst(2) { controlled.finish(key, image: image) }
    let lastStarted = await diagramEventually { controlled.keys.count == 5 }
    #expect(lastStarted)
    controlled.finish(try #require(controlled.keys.last), image: image)
    let completed = await diagramEventually { renderer.cachedCount == 3 }
    #expect(completed)
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

@Test @MainActor func nativeDiagramWebRendererRendersBundledMermaidWithoutNetwork() async throws {
    _ = NSApplication.shared
    let renderer = NativeMarkdownDiagramWebRenderer()
    defer { renderer.dispose() }
    for theme in ["light", "dark"] {
        let result = try await renderer.render(
            .init(
                code: "flowchart LR\n  Capture --> Review", language: "mermaid", width: 620, theme: theme))
        #expect(result.size.width > 0 && result.size.height > 0)
        #expect(result.image.accessibilityDescription == "mermaid diagram. Click to edit source.")
        #expect(result.image.representations.count == 1)
        #expect(result.image.representations.first is NSPDFImageRep)
        let bitmap = try #require(result.image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
        // Rendering must produce visible diagram pixels rather than an empty snapshot.
        var visible = false
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 4) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 4) {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.5 {
                    let brightness = (color.redComponent + color.greenComponent + color.blueComponent) / 3
                    if theme == "dark" ? brightness > 0.4 : brightness < 0.7 { visible = true }
                }
            }
        }
        #expect(visible)
    }
}

@Test @MainActor func nativeDiagramVectorCapturesKeepTransparentMarginsAndExplicitBackgrounds() async throws {
    _ = NSApplication.shared
    let renderer = NativeMarkdownDiagramWebRenderer()
    defer { renderer.dispose() }
    for theme in ["light", "dark"] {
        for language in ["vega-lite", "vega"] {
            for background in ["null", "omitted", "\"#ffffff\""] {
                let property = background == "omitted" ? "" : "\"background\":\(background),"
                let content =
                    language == "vega-lite"
                    ? "\"data\":{\"values\":[{\"x\":\"A\",\"y\":2}]},\"mark\":\"bar\",\"encoding\":{\"x\":{\"field\":\"x\",\"type\":\"nominal\"},\"y\":{\"field\":\"y\",\"type\":\"quantitative\"}},\"config\":{\"view\":{\"fill\":null}}"
                    : "\"marks\":[{\"type\":\"rect\",\"encode\":{\"enter\":{\"x\":{\"value\":20},\"y\":{\"value\":20},\"width\":{\"value\":40},\"height\":{\"value\":30},\"fill\":{\"value\":\"steelblue\"}}}}]"
                let result = try await renderer.render(
                    .init(
                        code: "{\(property)\"width\":240,\"height\":100,\"padding\":20,\(content)}",
                        language: language, width: 320, theme: theme))
                let bitmap = try #require(result.image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
                let corner = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: 2)?.usingColorSpace(.deviceRGB))
                if background == "\"#ffffff\"" {
                    #expect(corner.alphaComponent > 0.99)
                    #expect(corner.redComponent > 0.99 && corner.greenComponent > 0.99 && corner.blueComponent > 0.99)
                } else {
                    #expect(
                        corner.alphaComponent < 0.01,
                        "\(language), \(theme), \(background): vector capture must keep alpha")
                }
            }
        }
    }
}

@MainActor
private func waitForDiagramReport(_ renderer: NativeMarkdownDiagramRenderer, count: Int) async -> Bool {
    let (events, continuation) = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let observer = NotificationCenter.default.addObserver(
        forName: renderer.renderingDidChangeNotification!, object: nil, queue: .main
    ) { _ in
        MainActor.assumeIsolated {
            if renderer.cachedCount + renderer.failedCount >= count {
                continuation.yield(renderer.cachedCount == count && renderer.failedCount == 0)
                continuation.finish()
            }
        }
    }
    let deadline = Task { @MainActor in
        do { try await Task.sleep(for: .seconds(30)) } catch { return }
        continuation.yield(false)
        continuation.finish()
    }
    defer {
        deadline.cancel()
        NotificationCenter.default.removeObserver(observer)
        continuation.finish()
    }
    for await completed in events { return completed }
    return false
}

@Test(arguments: [256, 4096]) @MainActor
func nativeDiagramLargeReportRetainsVectorTextWithSerialAndParallelWorkers(points: Int) async throws {
    _ = NSApplication.shared
    let sources = try (0..<24).map { index in
        let values = (0..<points).map { ["x": $0, "y": ($0 * 17 + index * 7) % 100] }
        let spec: [String: Any] = [
            "title": "Report chart \(index)", "background": NSNull(), "width": 900, "height": 300,
            "data": ["values": values], "mark": "line",
            "encoding": ["x": ["field": "x", "type": "quantitative"], "y": ["field": "y", "type": "quantitative"]],
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: spec, options: .sortedKeys), as: UTF8.self)
    }
    for concurrency in [1, 2] {
        let images = NativeMarkdownDiagramImageCache()
        let renderer = NativeMarkdownDiagramRenderer(maximumConcurrentRenders: concurrency, imageCache: images)
        defer { renderer.dispose() }
        renderer.synchronizeSource(sources.joined(separator: "\n"))
        let start = ContinuousClock.now
        for source in sources { _ = renderer.request(code: source, language: "vega-lite", availableWidth: 900) }
        let completed = await waitForDiagramReport(renderer, count: sources.count)
        let duration = start.duration(to: .now)
        #expect(completed, "Every chart completes without another layout request")
        #expect(renderer.cachedBytes < 24 * 1024 * 1024 && renderer.pendingCount == 0)
        for (index, source) in sources.enumerated() {
            let result = try #require(renderer.request(code: source, language: "vega-lite", availableWidth: 900))
            let pdf = try #require(result.image.representations.first as? NSPDFImageRep)
            #expect(PDFDocument(data: pdf.pdfRepresentation)?.string?.contains("Report chart \(index)") == true)
            #expect(result.image.representations.count == 1 && result.image.cacheMode == .never)
            if let directory = ProcessInfo.processInfo.environment["DIETER_TEST_DIAGRAM_EVIDENCE"], index == 0 {
                let url = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                try pdf.pdfRepresentation.write(
                    to: url.appendingPathComponent("chart-\(points)-points-\(concurrency)-workers.pdf"))
            }
        }
        let coldBytes = renderer.cachedBytes
        renderer.dispose()
        let reopened = NativeMarkdownDiagramRenderer(maximumConcurrentRenders: concurrency, imageCache: images)
        defer { reopened.dispose() }
        reopened.synchronizeSource(sources.joined(separator: "\n"))
        let warmStart = ContinuousClock.now
        for source in sources { _ = reopened.request(code: source, language: "vega-lite", availableWidth: 900) }
        let warmDuration = warmStart.duration(to: .now)
        #expect(reopened.cachedCount == sources.count && reopened.pendingCount == 0 && reopened.failedCount == 0)
        #expect(reopened.cachedBytes == coldBytes)
        print(
            "DIAGRAM_REOPEN points=\(points) workers=\(concurrency) charts=\(sources.count) duration=\(warmDuration) cachedBytes=\(reopened.cachedBytes)"
        )
        print(
            "DIAGRAM_REPORT points=\(points) workers=\(concurrency) charts=\(sources.count) duration=\(duration) cachedBytes=\(coldBytes)"
        )
    }
}
