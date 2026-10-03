import CoreGraphics
import DieterAPI
import DieterShared
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
    /// Throws the shared core's limit problem for files measured but not read
    /// yet; [names] and [sizes] pair up, and a size of zero is an empty file.
    nonisolated static func checkLimits(names: [String], sizes: [Int64]) throws {
        let problem = SharedRules.shared.attachmentLimitError(
            names: names, sizes: sizes.map { KotlinLong(value: $0) })
        guard problem.isEmpty else { throw DieterAttachmentError.limit(problem) }
    }

    /// Throws when [incoming] after [existing] would break the shared limits.
    nonisolated static func validate(
        _ incoming: [Dieter_V1_MessagePart], appendingTo existing: [Dieter_V1_MessagePart]
    ) throws -> [Dieter_V1_MessagePart] {
        let parts = existing + incoming
        try checkLimits(names: parts.map(\.filename), sizes: parts.map { Int64($0.data.count) })
        return parts
    }

    func parts(
        urls: [URL],
        appendingTo existing: [Dieter_V1_MessagePart] = []
    ) throws -> [Dieter_V1_MessagePart] {
        try MacPerformanceSignposts.measure("Load file attachments", log: MacPerformanceSignposts.attachment) {
            var measured: [(url: URL, values: URLResourceValues)] = []
            for url in urls {
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                let values = try url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey, .isRegularFileKey])
                guard values.isRegularFile != false else {
                    throw DieterAttachmentError.notAFile(url.lastPathComponent)
                }
                measured.append((url, values))
            }
            // Measured sizes rule out oversized files before any is read; an
            // unknown size is checked once the file is read.
            try Self.checkLimits(
                names: existing.map(\.filename) + measured.map(\.url.lastPathComponent),
                sizes: existing.map { Int64($0.data.count) } + measured.map { Int64($0.values.fileSize ?? 1) })
            var parts = existing
            for (url, values) in measured {
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url, options: [.mappedIfSafe])
                parts.append(Self.part(data: data, filename: url.lastPathComponent, contentType: values.contentType))
            }
            return try Self.validate([], appendingTo: parts)
        }
    }

    func parts(
        images: [AttachmentImageInput],
        appendingTo existing: [Dieter_V1_MessagePart] = []
    ) throws -> [Dieter_V1_MessagePart] {
        try MacPerformanceSignposts.measure("Normalize image attachments", log: MacPerformanceSignposts.attachment) {
            try Self.checkLimits(
                names: existing.map(\.filename) + images.map { $0.suggestedName ?? "" },
                sizes: existing.map { Int64($0.data.count) } + images.map { Int64($0.data.count) })
            var parts = existing
            for image in images {
                let type = UTType(image.typeIdentifier)
                let normalized = try Self.normalizedImage(data: image.data, type: type)
                // A pasted image without a name is named by the core.
                parts.append(
                    Self.part(data: normalized.data, filename: image.suggestedName ?? "", contentType: normalized.type))
            }
            return try Self.validate([], appendingTo: parts)
        }
    }

    /// The part the core sends a read file as, named and typed by its rules.
    private static func part(data: Data, filename: String, contentType: UTType?) -> Dieter_V1_MessagePart {
        Dieter_V1_MessagePart(
            rules: SharedRules.shared.attachmentPart(
                filename: filename, declaredMediaType: contentType?.preferredMIMEType ?? "", bytes: data))
    }

    private static func normalizedImage(data: Data, type: UTType?) throws -> (data: Data, type: UTType) {
        if type == .png || type == .jpeg || type == .gif || type == .heic {
            return (data, type ?? .png)
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw DieterAttachmentError.invalidImage
        }
        let output = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                output,
                UTType.png.identifier as CFString,
                1,
                nil
            )
        else {
            throw DieterAttachmentError.invalidImage
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw DieterAttachmentError.invalidImage
        }
        return (output as Data, .png)
    }
}
