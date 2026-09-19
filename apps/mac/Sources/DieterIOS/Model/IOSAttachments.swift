import DieterAPI
import Foundation
import UniformTypeIdentifiers

struct IOSAttachmentSource: Sendable {
    let url: URL
    let filename: String?
    let mediaType: String?

    init(url: URL, filename: String? = nil, mediaType: String? = nil) {
        self.url = url
        self.filename = filename
        self.mediaType = mediaType
    }
}

enum IOSAttachmentError: LocalizedError {
    case tooMany
    case fileTooLarge(String)
    case totalTooLarge
    case empty(String)
    case notAFile(String)
    case unavailableShare
    case invalidShare

    var errorDescription: String? {
        switch self {
        case .tooMany: "You can attach up to 4 images or files."
        case .fileTooLarge(let name): "\(name) must be at most 5 MB."
        case .totalTooLarge: "Attachments must total at most 6 MB."
        case .empty(let name): "\(name) is empty."
        case .notAFile(let name): "\(name) is not a regular file."
        case .unavailableShare: "The shared item is no longer available. Share it again and retry."
        case .invalidShare: "Dieter could not read the shared item."
        }
    }
}

actor IOSAttachmentLoader {
    static let maximumCount = 4
    static let maximumBytes = 5 * 1_024 * 1_024
    static let maximumTotalBytes = 6 * 1_024 * 1_024

    func parts(
        urls: [URL],
        appendingTo existing: [Dieter_V1_MessagePart] = []
    ) throws -> [Dieter_V1_MessagePart] {
        try parts(sources: urls.map { IOSAttachmentSource(url: $0) }, appendingTo: existing)
    }

    func parts(
        sources: [IOSAttachmentSource],
        appendingTo existing: [Dieter_V1_MessagePart] = []
    ) throws -> [Dieter_V1_MessagePart] {
        guard existing.count + sources.count <= Self.maximumCount else {
            throw IOSAttachmentError.tooMany
        }
        var result = existing
        var total = existing.reduce(0) { $0 + $1.data.count }
        for source in sources {
            let accessed = source.url.startAccessingSecurityScopedResource()
            defer { if accessed { source.url.stopAccessingSecurityScopedResource() } }
            let values = try source.url.resourceValues(
                forKeys: [.contentTypeKey, .fileSizeKey, .isRegularFileKey])
            let filename = sanitizedFilename(source.filename ?? source.url.lastPathComponent)
            guard values.isRegularFile != false else { throw IOSAttachmentError.notAFile(filename) }
            if let size = values.fileSize, size > Self.maximumBytes {
                throw IOSAttachmentError.fileTooLarge(filename)
            }
            let data = try Data(contentsOf: source.url, options: [.mappedIfSafe])
            guard !data.isEmpty else { throw IOSAttachmentError.empty(filename) }
            guard data.count <= Self.maximumBytes else {
                throw IOSAttachmentError.fileTooLarge(filename)
            }
            total += data.count
            guard total <= Self.maximumTotalBytes else { throw IOSAttachmentError.totalTooLarge }
            let type = values.contentType ?? UTType(filenameExtension: source.url.pathExtension)
            var part = Dieter_V1_MessagePart()
            part.type = "file"
            part.mediaType = normalizedMediaType(source.mediaType, fallback: type)
            part.filename = filename
            part.data = data
            result.append(part)
        }
        return result
    }

    private func sanitizedFilename(_ value: String) -> String {
        let filename = URL(fileURLWithPath: value).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return filename.isEmpty ? "attachment" : filename
    }

    private func normalizedMediaType(_ value: String?, fallback: UTType?) -> String {
        let candidate = value?.split(separator: ";", maxSplits: 1).first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let candidate, candidate.contains("/") { return candidate }
        return fallback?.preferredMIMEType ?? "application/octet-stream"
    }
}

enum IOSShareInbox {
    private struct Manifest: Decodable {
        struct Item: Decodable {
            let storedName: String
            let filename: String
            let mediaType: String
        }

        let items: [Item]
    }

    static func shareID(from url: URL) -> String? {
        guard url.scheme?.lowercased() == "dieter-mac", url.host?.lowercased() == "share",
            let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "id" })?.value,
            let id = UUID(uuidString: value)
        else { return nil }
        return id.uuidString.lowercased()
    }

    static func consume(id: String) async throws -> [Dieter_V1_MessagePart] {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "DieterAppGroupIdentifier") as? String,
            let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: group)
        else { throw IOSAttachmentError.unavailableShare }
        return try await consume(id: id, from: container)
    }

    static func consume(id: String, from container: URL) async throws -> [Dieter_V1_MessagePart] {
        guard let uuid = UUID(uuidString: id) else { throw IOSAttachmentError.invalidShare }
        let directory = container.appendingPathComponent("ShareInbox", isDirectory: true)
            .appendingPathComponent(uuid.uuidString.lowercased(), isDirectory: true)
        let manifestURL = directory.appendingPathComponent("manifest.json", isDirectory: false)
        guard let data = try? Data(contentsOf: manifestURL), data.count <= 64 * 1_024,
            let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
            !manifest.items.isEmpty, manifest.items.count <= IOSAttachmentLoader.maximumCount
        else { throw IOSAttachmentError.invalidShare }
        let sources = try manifest.items.map { item -> IOSAttachmentSource in
            guard item.storedName == URL(fileURLWithPath: item.storedName).lastPathComponent,
                !item.storedName.isEmpty
            else { throw IOSAttachmentError.invalidShare }
            let url = directory.appendingPathComponent(item.storedName, isDirectory: false)
            guard url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL,
                FileManager.default.fileExists(atPath: url.path)
            else { throw IOSAttachmentError.unavailableShare }
            return IOSAttachmentSource(url: url, filename: item.filename, mediaType: item.mediaType)
        }
        do {
            let parts = try await IOSAttachmentLoader().parts(sources: sources)
            try? FileManager.default.removeItem(at: directory)
            return parts
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}
