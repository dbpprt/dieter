import AppKit
import MarkdownEngine
import Testing
@testable import DieterMac

@MainActor
private final class DiagramLifecycleWork {
    private(set) var keys: [NativeMarkdownDiagramKey] = []
    private var pending: [NativeMarkdownDiagramKey: CheckedContinuation<RenderedCodeBlockResult, Error>] = [:]

    func render(_ key: NativeMarkdownDiagramKey) async throws -> RenderedCodeBlockResult {
        keys.append(key)
        return try await withCheckedThrowingContinuation { pending[key] = $0 }
    }

    func finish(_ key: NativeMarkdownDiagramKey) {
        let image = NSImage(size: NSSize(width: 100, height: 40))
        pending.removeValue(forKey: key)?.resume(returning: RenderedCodeBlockResult(image: image, size: image.size))
    }

    func cancelAll() {
        let continuations = Array(pending.values)
        pending.removeAll()
        for continuation in continuations { continuation.resume(throwing: CancellationError()) }
    }
}

@MainActor
private func diagramLifecycleEventually(_ predicate: () -> Bool) async -> Bool {
    for _ in 0..<1000 {
        if predicate() { return true }
        await Task.yield()
    }
    return predicate()
}

@Test @MainActor func nativeDiagramSourceEditsReclaimOldVersionsAndRetainUnchangedPreviews() async throws {
    _ = NSApplication.shared
    var calls = 0
    let image = NSImage(size: NSSize(width: 100, height: 40))
    let renderer = NativeMarkdownDiagramRenderer(
        maximumEntries: 2,
        render: { _ in
            calls += 1
            return RenderedCodeBlockResult(image: image, size: image.size)
        })
    defer { renderer.dispose() }
    let unchanged = "graph LR; Keep-->This;"
    for index in 0..<60 {
        let edited = "graph LR; A-->Version_\(index);"
        renderer.synchronizeSource("```mermaid\n\(unchanged)\n```\n\n```mermaid\n\(edited)\n```")
        _ = renderer.request(code: unchanged, language: "mermaid", availableWidth: 320)
        _ = renderer.request(code: edited, language: "mermaid", availableWidth: 320)
        let ready = await diagramLifecycleEventually { renderer.cachedCount == 2 && renderer.pendingCount == 0 }
        #expect(ready)
        let current = try #require(renderer.request(code: edited, language: "mermaid", availableWidth: 320))
        #expect(current.image === image, "An edited block must not become a permanent cache-limit placeholder")
        #expect(calls == index + 2, "Unchanged diagram images survive edits to another block")
    }
    renderer.synchronizeSource("No diagram remains.")
    #expect(renderer.cachedCount == 0 && renderer.cachedBytes == 0)
    #expect(renderer.request(code: unchanged, language: "mermaid", availableWidth: 320) == nil)
}

@Test @MainActor func nativeDiagramSourceRemovalCancelsObsoleteWorkWithoutAdmittingItsLateResult() async throws {
    _ = NSApplication.shared
    let work = DiagramLifecycleWork()
    let renderer = NativeMarkdownDiagramRenderer(render: work.render)
    defer { renderer.dispose(); work.cancelAll() }
    let old = "graph LR; Old-->Diagram;"
    let next = "graph LR; Current-->Diagram;"
    renderer.synchronizeSource(old)
    _ = renderer.request(code: old, language: "mermaid", availableWidth: 320)
    let firstStarted = await diagramLifecycleEventually { work.keys.count == 1 }
    #expect(firstStarted)
    let first = try #require(work.keys.first)
    renderer.synchronizeSource(next)
    _ = renderer.request(code: next, language: "mermaid", availableWidth: 320)
    let replacementStarted = await diagramLifecycleEventually { work.keys.count == 2 }
    #expect(replacementStarted, "New source must not wait for an obsolete render to finish")
    work.finish(first)
    let replacement = try #require(work.keys.last)
    work.finish(replacement)
    let ready = await diagramLifecycleEventually { renderer.cachedCount == 1 }
    #expect(ready)
    #expect(renderer.request(code: old, language: "mermaid", availableWidth: 320) == nil)
    #expect(renderer.request(code: next, language: "mermaid", availableWidth: 320)?.image.size.height == 40)
}

@Test @MainActor func nativeDiagramDisposalDropsQueuedWorkAndIgnoresLateCompletions() async throws {
    _ = NSApplication.shared
    let work = DiagramLifecycleWork()
    let renderer = NativeMarkdownDiagramRenderer(render: work.render)
    defer { renderer.dispose(); work.cancelAll() }
    _ = renderer.request(code: "graph LR; A-->B;", language: "mermaid", availableWidth: 320)
    _ = renderer.request(code: "graph LR; C-->D;", language: "mermaid", availableWidth: 320)
    let started = await diagramLifecycleEventually { work.keys.count == 1 }
    #expect(started)
    let first = try #require(work.keys.first)
    renderer.dispose()
    work.finish(first)
    for _ in 0..<20 { await Task.yield() }
    #expect(work.keys.count == 1, "Closing a document must not start its queued diagram")
    #expect(renderer.cachedCount == 0 && renderer.cachedBytes == 0 && renderer.pendingCount == 0)
    #expect(renderer.request(code: "graph LR; C-->D;", language: "mermaid", availableWidth: 320) == nil)
    // A retained SwiftUI control may be mounted again with a fresh source.
    renderer.synchronizeSource("graph LR; Reopened-->Document;")
    #expect(renderer.request(code: "graph LR; Reopened-->Document;", language: "mermaid", availableWidth: 320) != nil)
}

@Test @MainActor func nativeDiagramHidingPausesWorkAndResumesWithoutDiscardingCompletedPreviews() async throws {
    _ = NSApplication.shared
    let work = DiagramLifecycleWork()
    let renderer = NativeMarkdownDiagramRenderer(render: work.render)
    defer { renderer.dispose(); work.cancelAll() }
    let first = "graph LR; Cached-->Diagram;"
    let second = "graph LR; Active-->Diagram;"
    let third = "graph LR; Queued-->Diagram;"
    renderer.synchronizeSource([first, second, third].joined(separator: "\n"))
    _ = renderer.request(code: first, language: "mermaid", availableWidth: 320)
    let firstStarted = await diagramLifecycleEventually { work.keys.count == 1 }
    #expect(firstStarted)
    work.finish(try #require(work.keys.first))
    let firstFinished = await diagramLifecycleEventually { renderer.cachedCount == 1 }
    #expect(firstFinished)
    let image = try #require(renderer.request(code: first, language: "mermaid", availableWidth: 320)?.image)
    _ = renderer.request(code: second, language: "mermaid", availableWidth: 320)
    _ = renderer.request(code: third, language: "mermaid", availableWidth: 320)
    let secondStarted = await diagramLifecycleEventually { work.keys.count == 2 }
    #expect(secondStarted)
    renderer.setActive(false)
    work.finish(try #require(work.keys.last))
    for _ in 0..<20 { await Task.yield() }
    #expect(renderer.cachedCount == 1 && work.keys.count == 2)
    #expect(renderer.request(code: first, language: "mermaid", availableWidth: 320)?.image === image)
    #expect(renderer.request(code: second, language: "mermaid", availableWidth: 320) == nil)
    // Source edits while hidden remove obsolete pending work before resuming.
    renderer.synchronizeSource([first, third].joined(separator: "\n"))
    renderer.setActive(true)
    let resumed = await diagramLifecycleEventually { work.keys.count == 3 }
    #expect(resumed)
    let last = try #require(work.keys.last)
    #expect(last.code == third)
    work.finish(last)
    let ready = await diagramLifecycleEventually { renderer.cachedCount == 2 }
    #expect(ready)
    #expect(renderer.request(code: first, language: "mermaid", availableWidth: 320)?.image === image)
}
