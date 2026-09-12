import AppKit
import DieterAPI
import ImageIO
import Observation
import SwiftUI
import UniformTypeIdentifiers

enum AttachmentMarkupTool: String, CaseIterable, Identifiable {
    case pen, highlighter, arrow, rectangle, ellipse
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .pen: "pencil.tip"
        case .highlighter: "highlighter"
        case .arrow: "arrow.up.right"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        }
    }
}

enum AttachmentMarkupColor: String, CaseIterable, Identifiable {
    case red, yellow, blue, green, white, black
    var id: String { rawValue }
    var color: NSColor {
        switch self {
        case .red: .systemRed
        case .yellow: .systemYellow
        case .blue: .systemBlue
        case .green: .systemGreen
        case .white: .white
        case .black: .black
        }
    }
}

struct AttachmentMarkupStroke: Equatable {
    let tool: AttachmentMarkupTool
    let color: AttachmentMarkupColor
    let width: CGFloat
    var points: [CGPoint]
}

enum AttachmentMarkupError: LocalizedError {
    case invalidImage, imageTooLarge, attachmentChanged
    var errorDescription: String? {
        switch self {
        case .invalidImage: "This image could not be opened for markup."
        case .imageTooLarge: "This image is too large to annotate."
        case .attachmentChanged: "The attachment changed while you were editing. Open it again to annotate it."
        }
    }
}

/// Coordinates are normalized to the original pixels, independent of the
/// window size. Only Apply creates new attachment bytes; no source file is read
/// or overwritten by the editor.
@MainActor @Observable
final class AttachmentMarkupDocument {
    let original: Dieter_V1_MessagePart
    let image: NSImage
    let pixelSize: CGSize
    var tool: AttachmentMarkupTool = .pen
    var color: AttachmentMarkupColor = .red
    var lineWidth: CGFloat = 3
    private(set) var strokes: [AttachmentMarkupStroke] = []
    private(set) var pendingStroke: AttachmentMarkupStroke?
    private var redoStrokes: [AttachmentMarkupStroke] = []
    var hasChanges: Bool { !strokes.isEmpty }
    var canUndo: Bool { !strokes.isEmpty }
    var canRedo: Bool { !redoStrokes.isEmpty }

    init(part: Dieter_V1_MessagePart) throws {
        let data = AttachmentImagePayload.data(from: part)
        guard let data, let source = CGImageSourceCreateWithData(data as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int,
            width > 0, height > 0
        else { throw AttachmentMarkupError.invalidImage }
        guard width <= 16_384, height <= 16_384, width * height <= 40_000_000 else {
            throw AttachmentMarkupError.imageTooLarge
        }
        // Apply camera/image orientation once; the annotated PNG has ordinary
        // pixel coordinates even when the attachment was JPEG/HEIC.
        guard
            let cgImage = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: max(width, height),
                ] as CFDictionary)
        else { throw AttachmentMarkupError.invalidImage }
        original = part
        pixelSize = CGSize(width: cgImage.width, height: cgImage.height)
        image = NSImage(cgImage: cgImage, size: pixelSize)
    }

    func begin(at point: CGPoint) {
        pendingStroke = AttachmentMarkupStroke(tool: tool, color: color, width: lineWidth, points: [clamp(point)])
    }

    func move(to point: CGPoint) {
        guard var stroke = pendingStroke else { return }
        let point = clamp(point)
        if stroke.tool == .pen || stroke.tool == .highlighter {
            if let last = stroke.points.last, hypot(point.x - last.x, point.y - last.y) < 0.0005 { return }
            // Bound freehand memory even during a very long mouse gesture.
            guard stroke.points.count < 20_000 else { return }
            stroke.points.append(point)
        } else {
            stroke.points = [stroke.points[0], point]
        }
        pendingStroke = stroke
    }

    func finish() {
        guard let stroke = pendingStroke else { return }
        pendingStroke = nil
        guard strokes.count < 500 else { return }
        strokes.append(stroke)
        redoStrokes.removeAll()
    }

    func undo() {
        pendingStroke = nil
        if let stroke = strokes.popLast() { redoStrokes.append(stroke) }
    }

    func redo() {
        if let stroke = redoStrokes.popLast() { strokes.append(stroke) }
    }

    func clear() { strokes.removeAll(); redoStrokes.removeAll(); pendingStroke = nil }
    func cancelGesture() { pendingStroke = nil }

    func renderedPart() throws -> Dieter_V1_MessagePart {
        guard hasChanges else { return original }
        guard
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(pixelSize.width), pixelsHigh: Int(pixelSize.height),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: bitmap)
        else { throw AttachmentMarkupError.invalidImage }
        bitmap.size = pixelSize
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: CGRect(origin: .zero, size: pixelSize))
        context.cgContext.translateBy(x: 0, y: pixelSize.height)
        context.cgContext.scaleBy(x: 1, y: -1)
        for stroke in strokes { Self.draw(stroke, in: CGRect(origin: .zero, size: pixelSize)) }
        NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw AttachmentMarkupError.invalidImage
        }
        guard data.count <= AttachmentLoader.maximumBytes else {
            throw DieterAttachmentError.fileTooLarge(original.filename)
        }
        var result = original
        result.data = data
        result.url = ""
        result.type = "image"
        result.mediaType = "image/png"
        let basename = (original.filename as NSString).deletingPathExtension
        result.filename = (basename.isEmpty ? "Annotated image" : basename) + ".png"
        result.payloadRevision = UUID().uuidString
        return result
    }

    static func draw(_ stroke: AttachmentMarkupStroke, in rect: CGRect) {
        guard let first = stroke.points.first else { return }
        func projected(_ point: CGPoint) -> CGPoint {
            CGPoint(x: rect.minX + point.x * rect.width, y: rect.minY + point.y * rect.height)
        }
        let start = projected(first)
        let end = projected(stroke.points.last ?? first)
        // The chosen width is expressed at a 600-point image scale.
        let width = stroke.width * min(rect.width, rect.height) / 600
        let path = NSBezierPath()
        path.lineWidth = stroke.tool == .highlighter ? width * 5 : width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        stroke.color.color.withAlphaComponent(stroke.tool == .highlighter ? 0.35 : 1).setStroke()
        switch stroke.tool {
        case .pen, .highlighter:
            path.move(to: start)
            for point in stroke.points.dropFirst() { path.line(to: projected(point)) }
            if stroke.points.count == 1 { path.line(to: CGPoint(x: start.x + 0.1, y: start.y)) }
        case .arrow:
            path.move(to: start); path.line(to: end)
            let angle = atan2(end.y - start.y, end.x - start.x)
            let length = max(width * 4, min(rect.width, rect.height) * 0.025)
            for offset in [-CGFloat.pi / 6, CGFloat.pi / 6] {
                path.move(to: end)
                path.line(to: CGPoint(x: end.x - length * cos(angle + offset), y: end.y - length * sin(angle + offset)))
            }
        case .rectangle, .ellipse:
            let bounds = CGRect(
                x: min(start.x, end.x), y: min(start.y, end.y),
                width: abs(end.x - start.x), height: abs(end.y - start.y))
            path.append(stroke.tool == .rectangle ? NSBezierPath(rect: bounds) : NSBezierPath(ovalIn: bounds))
        }
        path.stroke()
    }

    private func clamp(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(1, max(0, point.x)), y: min(1, max(0, point.y)))
    }
}

struct AttachmentMarkupCanvas: NSViewRepresentable {
    let document: AttachmentMarkupDocument
    func makeNSView(context: Context) -> AttachmentMarkupCanvasView {
        AttachmentMarkupCanvasView(document: document)
    }
    func updateNSView(_ view: AttachmentMarkupCanvasView, context: Context) {
        let _ = document.strokes
        let _ = document.pendingStroke
        view.document = document
        view.needsDisplay = true
    }
}

@MainActor final class AttachmentMarkupCanvasView: NSView {
    var document: AttachmentMarkupDocument
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    var imageRect: CGRect {
        let inset = bounds.insetBy(dx: 12, dy: 12)
        guard inset.width > 0, inset.height > 0 else { return .zero }
        let scale = min(inset.width / document.pixelSize.width, inset.height / document.pixelSize.height)
        let size = CGSize(width: document.pixelSize.width * scale, height: document.pixelSize.height * scale)
        return CGRect(
            x: inset.midX - size.width / 2, y: inset.midY - size.height / 2, width: size.width, height: size.height)
    }

    init(document: AttachmentMarkupDocument) {
        self.document = document
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Image markup canvas")
        setAccessibilityHelp("Drag to draw with the selected tool. Use Undo to remove the last mark.")
        setAccessibilityIdentifier("attachment.markup.canvas")
    }
    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill(); bounds.fill()
        document.image.draw(
            in: imageRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: imageRect).addClip()
        for stroke in document.strokes { AttachmentMarkupDocument.draw(stroke, in: imageRect) }
        if let stroke = document.pendingStroke { AttachmentMarkupDocument.draw(stroke, in: imageRect) }
        NSGraphicsContext.restoreGraphicsState()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard imageRect.contains(point) else { return }
        window?.makeFirstResponder(self)
        document.begin(at: normalized(point))
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        document.move(to: normalized(convert(event.locationInWindow, from: nil)))
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        document.move(to: normalized(convert(event.locationInWindow, from: nil)))
        document.finish()
        needsDisplay = true
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, document.pendingStroke != nil {
            document.cancelGesture(); needsDisplay = true; return
        }
        super.keyDown(with: event)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.modifierFlags.contains(.command),
            event.charactersIgnoringModifiers?.lowercased() == "z"
        else {
            return super.performKeyEquivalent(with: event)
        }
        if event.modifierFlags.contains(.shift) { document.redo() } else { document.undo() }
        needsDisplay = true
        return true
    }
    override func resetCursorRects() { addCursorRect(imageRect, cursor: .crosshair) }
    private func normalized(_ point: CGPoint) -> CGPoint {
        let rect = imageRect
        guard rect.width > 0, rect.height > 0 else { return .zero }
        return CGPoint(x: (point.x - rect.minX) / rect.width, y: (point.y - rect.minY) / rect.height)
    }
}

/// Shared by every attachment composer and the capture window's right pane.
struct AttachmentMarkupEditor: View {
    let part: Dieter_V1_MessagePart
    let apply: (Dieter_V1_MessagePart) throws -> Void
    var cancel: (() -> Void)?
    @State private var document: AttachmentMarkupDocument?
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            if let document {
                tools(document).padding(10)
                Divider()
                AttachmentMarkupCanvas(document: document)
                    .frame(minHeight: 220, maxHeight: .infinity)
                    .smokeTarget("attachment.markup.canvas")
                Divider()
                if let error { Text(error).font(.caption).foregroundStyle(.orange).padding(8) }
                HStack {
                    Text("\(Int(document.pixelSize.width)) × \(Int(document.pixelSize.height))")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") {
                        document.clear(); cancel?()
                    }
                    .accessibilityIdentifier("attachment.markup.cancel").smokeTarget("attachment.markup.cancel")
                    Button("Apply") {
                        do {
                            guard document.original == part else { throw AttachmentMarkupError.attachmentChanged }
                            try apply(document.renderedPart())
                            document.clear()
                        } catch { self.error = error.localizedDescription }
                    }
                    .buttonStyle(.borderedProminent).disabled(!document.hasChanges)
                    .accessibilityIdentifier("attachment.markup.apply").smokeTarget("attachment.markup.apply")
                }
                .padding(10)
            } else {
                ContentUnavailableView(
                    "Markup unavailable", systemImage: "photo", description: Text(error ?? "Opening image…"))
                if let cancel { Button("Close", action: cancel).padding(12) }
            }
        }
        .background(DieterTheme.surface)
        .onAppear {
            guard document == nil else { return }
            do { document = try AttachmentMarkupDocument(part: part) } catch { self.error = error.localizedDescription }
        }
    }

    private func tools(_ document: AttachmentMarkupDocument) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 3) {
                ForEach(AttachmentMarkupTool.allCases) { tool in
                    Button {
                        document.tool = tool
                    } label: {
                        Image(systemName: tool.symbol).frame(width: 27, height: 25)
                            .background(
                                document.tool == tool ? Color.accentColor.opacity(0.2) : .clear,
                                in: RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.borderless).help(tool.title).accessibilityLabel(tool.title)
                    .accessibilityAddTraits(document.tool == tool ? .isSelected : [])
                    .accessibilityIdentifier("attachment.markup.tool.\(tool.rawValue)")
                    .smokeTarget("attachment.markup.tool.\(tool.rawValue)")
                }
                Spacer(minLength: 0)
                Button {
                    document.undo()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .disabled(!document.canUndo).help("Undo (⌘Z)").accessibilityLabel("Undo mark")
                .accessibilityIdentifier("attachment.markup.undo").smokeTarget("attachment.markup.undo")
                Button {
                    document.redo()
                } label: {
                    Image(systemName: "arrow.uturn.forward")
                }
                .disabled(!document.canRedo).help("Redo (⇧⌘Z)").accessibilityLabel("Redo mark")
                Button("Clear") { document.clear() }.disabled(!document.hasChanges)
                    .accessibilityIdentifier("attachment.markup.clear").smokeTarget("attachment.markup.clear")
            }
            HStack(spacing: 7) {
                ForEach(AttachmentMarkupColor.allCases) { color in
                    Button {
                        document.color = color
                    } label: {
                        Circle().fill(Color(nsColor: color.color)).frame(width: 15, height: 15)
                            .padding(3).overlay(
                                Circle().stroke(document.color == color ? Color.primary : .clear, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain).accessibilityLabel(color.rawValue.capitalized)
                    .accessibilityAddTraits(document.color == color ? .isSelected : [])
                    .accessibilityIdentifier("attachment.markup.color.\(color.rawValue)")
                    .smokeTarget("attachment.markup.color.\(color.rawValue)")
                }
                Spacer(minLength: 4)
                Stepper(
                    "Width \(Int(document.lineWidth))",
                    value: Binding(get: { document.lineWidth }, set: { document.lineWidth = $0 }), in: 1...8
                )
                .font(.caption).fixedSize().accessibilityLabel("Stroke width")
            }
        }
        .controlSize(.small)
    }
}

struct ScreenshotMarkupInspector: View {
    @Binding var attachments: [Dieter_V1_MessagePart]
    @State private var selectedIndex = 0
    private var images: [Int] {
        attachments.indices.filter { attachments[$0].mediaType.hasPrefix("image/") || attachments[$0].type == "image" }
    }
    private var index: Int? { images.contains(selectedIndex) ? selectedIndex : images.first }

    var body: some View {
        VStack(spacing: 0) {
            if let index {
                let part = attachments[index]
                HStack {
                    Label("Screenshot", systemImage: "photo").font(.headline)
                    Spacer()
                    if images.count > 1 {
                        Picker("Image", selection: $selectedIndex) {
                            ForEach(images, id: \.self) { position in
                                Text(attachments[position].filename).tag(position)
                            }
                        }.labelsHidden().frame(maxWidth: 180)
                    }
                }.padding(12)
                Divider()
                AttachmentMarkupEditor(part: part) { edited in
                    attachments = try AttachmentMarkupReplacement.replacing(
                        part, at: index, with: edited, in: attachments)
                }
                .id("\(index):\(part.payloadRevision):\(part.data.hashValue)")
            } else {
                ContentUnavailableView(
                    "Add a screenshot", systemImage: "photo.badge.plus",
                    description: Text("Paste, drop or attach an image to mark it up here."))
            }
        }
        .frame(minWidth: 340, maxWidth: .infinity, minHeight: 430, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(DieterTheme.border))
        .accessibilityIdentifier("quick-task.screenshot-inspector")
        .smokeTarget("quick-task.screenshot-inspector")
    }
}
