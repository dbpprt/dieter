import AppKit
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
