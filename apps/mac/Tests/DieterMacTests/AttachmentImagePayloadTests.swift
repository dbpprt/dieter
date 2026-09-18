import AppKit
import DieterAPI
import Testing
@testable import DieterMac

@Test func inlineAttachmentImageCacheKeysAreBoundedAndContentAddressed() {
    var first = Dieter_V1_MessagePart()
    first.type = "image"
    first.filename = "fixture.png"
    first.mediaType = "image/png"
    first.url = "data:image/png;base64," + String(repeating: "A", count: 200_000)
    var second = first
    second.url.removeLast()
    second.url.append("B")

    let firstKey = AttachmentImagePayload.cacheKey(for: first) as String
    let secondKey = AttachmentImagePayload.cacheKey(for: second) as String
    #expect(firstKey.count < 160)
    #expect(!firstKey.contains(first.url))
    #expect(firstKey != secondKey)

    first.payloadRevision = "payload-42"
    let revisionKey = AttachmentImagePayload.cacheKey(for: first) as String
    #expect(revisionKey.contains("payload-42"))
    #expect(revisionKey.count < 160)
}

@Test @MainActor func attachmentImageCacheChargesDecodedPixelMemory() throws {
    let representation = try #require(
        NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 100, pixelsHigh: 50,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    let image = NSImage(size: NSSize(width: 100, height: 50))
    image.addRepresentation(representation)
    #expect(AttachmentImagePayload.cacheCost(image: image, encodedByteCount: 64) >= 20_000)
}
