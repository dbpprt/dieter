import AppKit
import DieterAPI
import Testing
@testable import DieterMac

@MainActor struct AttachmentMarkupTests {
    @Test func applyingMarkupChangesPixelsAndMetadataWithoutChangingOriginal() throws {
        let original = try fixture()
        let document = try AttachmentMarkupDocument(part: original)
        document.tool = .rectangle
        document.color = .red
        document.lineWidth = 8
        document.begin(at: CGPoint(x: 0.25, y: 0.25))
        document.move(to: CGPoint(x: 0.75, y: 0.75))
        document.finish()
        let edited = try document.renderedPart()
        let pixels = try #require(NSBitmapImageRep(data: edited.data))
        let before = try #require(NSBitmapImageRep(data: original.data))
        #expect(edited.data != original.data)
        #expect(edited.mediaType == "image/png" && edited.filename == "capture.png")
        #expect(edited.url.isEmpty && !edited.payloadRevision.isEmpty)
        #expect(pixels.pixelsWide == 320 && pixels.pixelsHigh == 180)
        // The original's top/bottom colors also catch accidental vertical
        // flips when combining a flipped native canvas with a PNG context.
        #expect(pixels.colorAt(x: 4, y: 4) == before.colorAt(x: 4, y: 4))
        #expect(pixels.colorAt(x: 4, y: 174) == before.colorAt(x: 4, y: 174))
        let marked = try #require(pixels.colorAt(x: 80, y: 90)?.usingColorSpace(.deviceRGB))
        #expect(marked.redComponent > marked.blueComponent)
        #expect(document.original == original)
    }

    @Test func undoRedoAndCancelKeepOriginalAttachmentBytes() throws {
        let original = try fixture()
        let document = try AttachmentMarkupDocument(part: original)
        for tool in AttachmentMarkupTool.allCases {
            document.tool = tool
            document.begin(at: .init(x: 0.15, y: 0.2))
            document.move(to: .init(x: 0.8, y: 0.65))
            document.finish()
        }
        #expect(document.strokes.count == AttachmentMarkupTool.allCases.count)
        document.undo()
        #expect(document.canRedo && document.strokes.count == 4)
        document.redo()
        #expect(document.strokes.count == 5)
        document.clear()
        #expect(!document.hasChanges && !document.canUndo && !document.canRedo)
        #expect(try document.renderedPart() == original)
    }

    @Test func nativeCanvasMapsDragToPixelsAndRejectsLetterboxClicks() throws {
        let document = try AttachmentMarkupDocument(part: fixture())
        let canvas = AttachmentMarkupCanvasView(document: document)
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 700, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = canvas
        defer { window.close() }
        canvas.frame = .init(x: 0, y: 0, width: 700, height: 600)
        let rect = canvas.imageRect
        for (type, point) in [
            (
                NSEvent.EventType.leftMouseDown,
                CGPoint(x: rect.minX + rect.width * 0.2, y: rect.minY + rect.height * 0.3)
            ),
            (.leftMouseDragged, CGPoint(x: rect.minX + rect.width * 0.7, y: rect.minY + rect.height * 0.8)),
            (.leftMouseUp, CGPoint(x: rect.minX + rect.width * 0.7, y: rect.minY + rect.height * 0.8)),
        ] {
            let event = try #require(
                NSEvent.mouseEvent(
                    with: type, location: canvas.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            switch type {
            case .leftMouseDown: canvas.mouseDown(with: event)
            case .leftMouseDragged: canvas.mouseDragged(with: event)
            default: canvas.mouseUp(with: event)
            }
        }
        let stroke = try #require(document.strokes.first)
        #expect(abs((stroke.points.first?.x ?? 0) - 0.2) < 0.001)
        #expect(abs((stroke.points.last?.y ?? 0) - 0.8) < 0.001)
        let outside = try #require(
            NSEvent.mouseEvent(
                with: .leftMouseDown, location: canvas.convert(.init(x: 1, y: 1), to: nil), modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        canvas.mouseDown(with: outside)
        #expect(document.pendingStroke == nil)
        canvas.frame.size = .init(width: 360, height: 270)
        #expect(document.strokes == [stroke], "Resizing must preserve original-pixel geometry")
    }

    @Test func replacementRejectsStaleOrOversizedAttachmentCollections() throws {
        let original = try fixture()
        var edited = original
        edited.data = Data([1, 2, 3])
        let replaced = try AttachmentMarkupReplacement.replacing(original, at: 0, with: edited, in: [original])
        #expect(replaced == [edited])
        #expect(throws: AttachmentMarkupError.self) {
            try AttachmentMarkupReplacement.replacing(original, at: 0, with: edited, in: [])
        }
        var other = original
        other.data = Data(repeating: 0, count: AttachmentLoader.maximumTotalBytes)
        #expect(throws: DieterAttachmentError.self) {
            try AttachmentMarkupReplacement.replacing(original, at: 0, with: edited, in: [original, other])
        }
    }

    private func fixture() throws -> Dieter_V1_MessagePart {
        let bitmap = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 320, pixelsHigh: 180, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0))
        let blue = NSColor(deviceRed: 0, green: 0, blue: 1, alpha: 1)
        let white = NSColor(deviceRed: 1, green: 1, blue: 1, alpha: 1)
        for y in 0..<180 {
            for x in 0..<320 { bitmap.setColor(y < 20 ? blue : white, atX: x, y: y) }
        }
        var part = Dieter_V1_MessagePart()
        part.type = "image"
        part.mediaType = "image/png"
        part.filename = "capture.jpg"
        part.data = try #require(bitmap.representation(using: .png, properties: [:]))
        return part
    }
}
