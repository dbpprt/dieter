import CoreGraphics
import DieterAPI
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct AttachmentImageInput: Sendable {
    let data: Data
    let typeIdentifier: String
    let suggestedName: String?
}

enum AttachmentPasteboardInput: Sendable {
    case urls([URL])
    case images([AttachmentImageInput])
}

actor AttachmentLoader {
    static let maximumCount = 4
    static let maximumBytes = 5 * 1_024 * 1_024
    static let maximumTotalBytes = 6 * 1_024 * 1_024

    func parts(
        urls: [URL],
        appendingTo existing: [Dieter_V1_MessagePart] = []
    ) throws -> [Dieter_V1_MessagePart] {
        try MacPerformanceSignposts.measure("Load file attachments", log: MacPerformanceSignposts.attachment) {
        guard existing.count + urls.count <= Self.maximumCount else {
            throw DieterAttachmentError.tooMany
        }
        var parts = existing
        for url in urls {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let values = try url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile != false else {
                throw DieterAttachmentError.notAFile(url.lastPathComponent)
            }
            if let size = values.fileSize, size > Self.maximumBytes {
                throw DieterAttachmentError.fileTooLarge(url.lastPathComponent)
            }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            parts = try Self.appending(
                data: data,
                filename: url.lastPathComponent,
                contentType: values.contentType,
                to: parts
            )
        }
        return parts
        }
    }

    func parts(
        images: [AttachmentImageInput],
        appendingTo existing: [Dieter_V1_MessagePart] = []
    ) throws -> [Dieter_V1_MessagePart] {
        try MacPerformanceSignposts.measure("Normalize image attachments", log: MacPerformanceSignposts.attachment) {
        guard existing.count + images.count <= Self.maximumCount else {
            throw DieterAttachmentError.tooMany
        }
        var parts = existing
        for image in images {
            let type = UTType(image.typeIdentifier)
            let normalized = try Self.normalizedImage(data: image.data, type: type)
            let baseName = image.suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallbackName = "Pasted Image \(parts.count + 1)"
            let resolvedName = baseName.flatMap { $0.isEmpty ? nil : $0 } ?? fallbackName
            let filename = Self.filename(resolvedName, for: normalized.type)
            parts = try Self.appending(
                data: normalized.data,
                filename: filename,
                contentType: normalized.type,
                to: parts
            )
        }
        return parts
        }
    }

    private static func appending(
        data: Data,
        filename: String,
        contentType: UTType?,
        to existing: [Dieter_V1_MessagePart]
    ) throws -> [Dieter_V1_MessagePart] {
        guard existing.count < maximumCount else { throw DieterAttachmentError.tooMany }
        guard !data.isEmpty else { throw DieterAttachmentError.empty(filename) }
        guard data.count <= maximumBytes else { throw DieterAttachmentError.fileTooLarge(filename) }
        guard existing.reduce(0, { $0 + $1.data.count }) + data.count <= maximumTotalBytes else {
            throw DieterAttachmentError.totalTooLarge
        }
        var part = Dieter_V1_MessagePart()
        part.type = contentType?.conforms(to: .image) == true ? "image" : "file"
        part.mediaType = contentType?.preferredMIMEType ?? "application/octet-stream"
        part.filename = filename
        part.data = data
        return existing + [part]
    }

    private static func normalizedImage(data: Data, type: UTType?) throws -> (data: Data, type: UTType) {
        if type == .png || type == .jpeg || type == .gif || type == .heic {
            return (data, type ?? .png)
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw DieterAttachmentError.invalidImage
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw DieterAttachmentError.invalidImage
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw DieterAttachmentError.invalidImage
        }
        return (output as Data, .png)
    }

    private static func filename(_ value: String, for type: UTType) -> String {
        let path = value as NSString
        if !path.pathExtension.isEmpty { return value }
        guard let suffix = type.preferredFilenameExtension else { return value }
        return "\(value).\(suffix)"
    }
}
