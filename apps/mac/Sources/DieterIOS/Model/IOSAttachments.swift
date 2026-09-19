import DieterAPI
import Foundation
import UniformTypeIdentifiers
#if os(iOS)
    import PhotosUI
    import SwiftUI
#endif

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

struct IOSAttachmentPayload: Sendable {
    let data: Data
    let filename: String
    let mediaType: String
}

enum IOSAttachmentError: LocalizedError {
    case tooMany
    case fileTooLarge(String)
    case totalTooLarge
    case empty(String)
    case notAFile(String)
    case unavailableShare
    case invalidShare
    case invalidPaste

    var errorDescription: String? {
        switch self {
        case .tooMany: "You can attach up to 4 images or files."
        case .fileTooLarge(let name): "\(name) must be at most 5 MB."
        case .totalTooLarge: "Attachments must total at most 6 MB."
        case .empty(let name): "\(name) is empty."
        case .notAFile(let name): "\(name) is not a regular file."
        case .unavailableShare: "The shared item is no longer available. Share it again and retry."
        case .invalidShare: "Dieter could not read the shared item."
        case .invalidPaste: "Dieter could not read the pasted screenshot."
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

    func parts(
        payloads: [IOSAttachmentPayload],
        appendingTo existing: [Dieter_V1_MessagePart] = []
    ) throws -> [Dieter_V1_MessagePart] {
        guard existing.count + payloads.count <= Self.maximumCount else {
            throw IOSAttachmentError.tooMany
        }
        var result = existing
        var total = existing.reduce(0) { $0 + $1.data.count }
        for payload in payloads {
            let filename = sanitizedFilename(payload.filename)
            guard !payload.data.isEmpty else { throw IOSAttachmentError.empty(filename) }
            guard payload.data.count <= Self.maximumBytes else {
                throw IOSAttachmentError.fileTooLarge(filename)
            }
            total += payload.data.count
            guard total <= Self.maximumTotalBytes else { throw IOSAttachmentError.totalTooLarge }
            var part = Dieter_V1_MessagePart()
            part.type = "file"
            part.mediaType = normalizedMediaType(
                payload.mediaType,
                fallback: UTType(filenameExtension: URL(fileURLWithPath: filename).pathExtension))
            part.filename = filename
            part.data = payload.data
            result.append(part)
        }
        return result
    }

    #if os(iOS)
        func parts(
            photoItems: [PhotosPickerItem],
            appendingTo existing: [Dieter_V1_MessagePart] = []
        ) async throws -> [Dieter_V1_MessagePart] {
            guard existing.count + photoItems.count <= Self.maximumCount else {
                throw IOSAttachmentError.tooMany
            }
            var payloads: [IOSAttachmentPayload] = []
            payloads.reserveCapacity(photoItems.count)
            for (index, item) in photoItems.enumerated() {
                guard let data = try await item.loadTransferable(type: Data.self), !data.isEmpty else {
                    throw IOSAttachmentError.invalidPaste
                }
                let type = item.supportedContentTypes.first(where: { $0.conforms(to: .image) })
                let suffix = type?.preferredFilenameExtension ?? "png"
                let number = photoItems.count == 1 ? "" : " \(index + 1)"
                payloads.append(
                    IOSAttachmentPayload(
                        data: data,
                        filename: "Photo\(number).\(suffix)",
                        mediaType: type?.preferredMIMEType ?? "image/png"))
            }
            return try parts(payloads: payloads, appendingTo: existing)
        }
    #endif

    static func appending(
        _ incoming: [Dieter_V1_MessagePart],
        to existing: [Dieter_V1_MessagePart]
    ) throws -> [Dieter_V1_MessagePart] {
        guard existing.count + incoming.count <= maximumCount else {
            throw IOSAttachmentError.tooMany
        }
        var total = existing.reduce(0) { $0 + $1.data.count }
        for part in incoming {
            let filename = part.filename.isEmpty ? "attachment" : part.filename
            guard !part.data.isEmpty else { throw IOSAttachmentError.empty(filename) }
            guard part.data.count <= maximumBytes else {
                throw IOSAttachmentError.fileTooLarge(filename)
            }
            total += part.data.count
            guard total <= maximumTotalBytes else { throw IOSAttachmentError.totalTooLarge }
        }
        return existing + incoming
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
    enum Destination: String, Sendable {
        case newTask = "new-task"
        case task
        case chat
    }

    struct Request: Equatable, Sendable {
        let id: String
        let destination: Destination
    }

    private struct Manifest: Decodable {
        struct Item: Decodable {
            let storedName: String
            let filename: String
            let mediaType: String
        }

        let items: [Item]
    }

    private struct PendingRequest: Codable {
        let id: String
        let destination: String
    }

    private static let pendingRequestName = "pending-request.json"

    static func request(from url: URL) -> Request? {
        guard url.scheme?.lowercased() == "dieter-mac", url.host?.lowercased() == "share",
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
            let value = query.first(where: { $0.name == "id" })?.value,
            let id = UUID(uuidString: value)
        else { return nil }
        let destination: Destination
        if let value = query.first(where: { $0.name == "destination" })?.value {
            guard let parsed = Destination(rawValue: value) else { return nil }
            destination = parsed
        } else {
            destination = .newTask
        }
        return Request(id: id.uuidString.lowercased(), destination: destination)
    }

    static func shareID(from url: URL) -> String? {
        request(from: url)?.id
    }

    static func pendingRequest() -> Request? {
        guard
            let group = Bundle.main.object(forInfoDictionaryKey: "DieterAppGroupIdentifier") as? String,
            let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: group)
        else { return nil }
        return pendingRequest(from: container)
    }

    static func pendingRequest(from container: URL) -> Request? {
        let inbox = container.appendingPathComponent("ShareInbox", isDirectory: true)
        let url = inbox.appendingPathComponent(pendingRequestName, isDirectory: false)
        guard let data = try? Data(contentsOf: url), data.count <= 16 * 1_024,
            let pending = try? JSONDecoder().decode(PendingRequest.self, from: data),
            let id = UUID(uuidString: pending.id),
            let destination = Destination(rawValue: pending.destination)
        else { return nil }
        let canonicalID = id.uuidString.lowercased()
        let manifest = inbox.appendingPathComponent(canonicalID, isDirectory: true)
            .appendingPathComponent("manifest.json", isDirectory: false)
        guard FileManager.default.fileExists(atPath: manifest.path) else { return nil }
        return Request(id: canonicalID, destination: destination)
    }

    static func recordPendingRequest(_ request: Request, in container: URL) throws {
        guard let id = UUID(uuidString: request.id) else { throw IOSAttachmentError.invalidShare }
        let inbox = container.appendingPathComponent("ShareInbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let canonicalID = id.uuidString.lowercased()
        try JSONEncoder().encode(
            PendingRequest(id: canonicalID, destination: request.destination.rawValue)
        ).write(to: inbox.appendingPathComponent(pendingRequestName), options: .atomic)
    }

    static func clearPendingRequest(_ request: Request) {
        guard
            let group = Bundle.main.object(forInfoDictionaryKey: "DieterAppGroupIdentifier") as? String,
            let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: group)
        else { return }
        clearPendingRequest(request, from: container)
    }

    static func clearPendingRequest(_ request: Request, from container: URL) {
        let url = container.appendingPathComponent("ShareInbox", isDirectory: true)
            .appendingPathComponent(pendingRequestName, isDirectory: false)
        guard let data = try? Data(contentsOf: url), data.count <= 16 * 1_024,
            let pending = try? JSONDecoder().decode(PendingRequest.self, from: data),
            let id = UUID(uuidString: pending.id),
            let destination = Destination(rawValue: pending.destination),
            Request(id: id.uuidString.lowercased(), destination: destination) == request
        else { return }
        try? FileManager.default.removeItem(at: url)
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
