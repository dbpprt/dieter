import AppKit
import DieterAPI
import Foundation
import Testing
import UniformTypeIdentifiers
@testable import DieterMacKit

/// Files, pasted images, and pasteboards becoming composer attachments.
struct AttachmentIntakeTests {
    @Test @MainActor func macAttachmentSelectionPreservesBytesAndEnforcesTheSharedLimit() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "dieter-mac-attachments-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appending(path: "fixture.png")
        let document = root.appending(path: "notes.txt")
        try Data("png fixture".utf8).write(to: image)
        try Data("hello".utf8).write(to: document)

        let store = DieterStore(liveEnvironment: false)
        let parts = try await store.attachmentParts([image, document])
        #expect(parts.count == 2)
        #expect(parts[0].filename == "fixture.png")
        #expect(parts[0].mediaType == "image/png")
        #expect(parts[0].data == Data("png fixture".utf8))
        #expect(parts[1].filename == "notes.txt")

        var rejected = false
        do {
            _ = try await store.attachmentParts([image], appendingTo: Array(repeating: parts[0], count: 4))
        } catch {
            rejected = true
        }
        #expect(rejected)
    }

    @Test @MainActor func pastedMacImageBecomesAPngAttachmentWithoutALocalFileURL() async throws {
        let png = try #require(
            Data(
                base64Encoded:
                    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        let provider = NSItemProvider(item: png as NSData, typeIdentifier: UTType.png.identifier)
        let store = DieterStore(liveEnvironment: false)

        let parts = try await store.attachmentParts([provider])

        #expect(parts.count == 1)
        #expect(parts[0].type == "file")
        #expect(parts[0].mediaType == "image/png")
        #expect(parts[0].filename == "attached-image", "an unnamed paste is named by the core")
        #expect(parts[0].data == png)
    }

    @Test @MainActor func pastedMacTIFFScreenshotIsNormalizedToPortablePNG() async throws {
        let image = NSImage(size: NSSize(width: 2, height: 2))
        image.lockFocus()
        NSColor.systemPurple.setFill()
        NSRect(x: 0, y: 0, width: 2, height: 2).fill()
        image.unlockFocus()
        let tiff = try #require(image.tiffRepresentation)
        let provider = NSItemProvider(item: tiff as NSData, typeIdentifier: UTType.tiff.identifier)
        let store = DieterStore(liveEnvironment: false)

        let parts = try await store.attachmentParts([provider])

        #expect(parts[0].mediaType == "image/png")
        #expect(parts[0].filename == "attached-image", "an unnamed paste is named by the core")
        #expect(NSImage(data: parts[0].data) != nil)
    }

    @Test @MainActor func pasteboardImageDataBecomesAComposerAttachment() async throws {
        let png = try #require(
            Data(
                base64Encoded:
                    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("dieter-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setData(png, forType: NSPasteboard.PasteboardType(UTType.png.identifier))
        let store = DieterStore(liveEnvironment: false)

        let input = try #require(store.pasteboardAttachmentInput(pasteboard))
        let parts = try await store.attachmentParts(input)

        #expect(parts.count == 1)
        #expect(parts[0].type == "file")
        #expect(parts[0].mediaType == "image/png")
        #expect(parts[0].filename == "attached-image", "an unnamed paste is named by the core")
        #expect(parts[0].data == png)
    }

    @Test @MainActor func pasteboardWithOnlyTextIsLeftForTheFocusedTextView() async throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("dieter-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("plain text", forType: .string)
        let store = DieterStore(liveEnvironment: false)

        #expect(store.pasteboardAttachmentInput(pasteboard) == nil)
        #expect(!store.attachPasteboard(pasteboard))
        #expect(store.composerAttachments.isEmpty)
    }

    @Test func embeddedMacImageAttachmentsProvidePreviewImages() throws {
        let png = try #require(
            Data(
                base64Encoded:
                    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        var dataPart = Dieter_V1_MessagePart()
        dataPart.type = "image"
        dataPart.mediaType = "image/png"
        dataPart.data = png
        #expect(AttachmentImagePayload.image(from: dataPart) != nil)

        var dataURLPart = Dieter_V1_MessagePart()
        dataURLPart.type = "image"
        dataURLPart.url = "data:image/png;base64,\(png.base64EncodedString())"
        #expect(AttachmentImagePayload.image(from: dataURLPart) != nil)
    }

    @Test @MainActor func pasteboardFileURLsAttachTheUnderlyingFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "dieter-mac-pasteboard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "diagram.png")
        try Data("png fixture".utf8).write(to: file)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("dieter-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.writeObjects([file as NSURL])
        let store = DieterStore(liveEnvironment: false)

        #expect(store.attachPasteboard(pasteboard))
        let deadline = Date().addingTimeInterval(1)
        while store.composerAttachments.isEmpty, Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let attachment = try #require(store.composerAttachments.first)
        #expect(attachment.filename == "diagram.png")
        #expect(attachment.data == Data("png fixture".utf8))
    }
}
