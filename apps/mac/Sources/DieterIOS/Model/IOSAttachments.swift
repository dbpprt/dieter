import DieterAPI
import DieterShared
import Foundation
import SharedCore
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

/// Why an attachment could not be read. The shared core's limits arrive as
/// `limit` with its wording.
enum IOSAttachmentError: LocalizedError, Equatable {
    case limit(String)
    case notAFile(String)
    case unavailableShare
    case invalidShare
    case invalidPaste

    var errorDescription: String? {
        switch self {
        case .limit(let problem): problem
        case .notAFile(let name): "\(name) is not a regular file."
        case .unavailableShare: "The shared item is no longer available. Share it again and retry."
        case .invalidShare: "Dieter could not read the shared item."
        case .invalidPaste: "Dieter could not read the pasted screenshot."
        }
    }
}

/// Reads picked, pasted, and shared files into message parts. What may be
/// attached, and how parts are named and typed, are the shared core's rules;
/// reading the bytes stays native.
actor IOSAttachmentLoader {
    /// Throws the core's problem with attachments measured but not read
    /// yet; `names` and `sizes` pair up, and a size of zero is an empty file.
    nonisolated static func checkLimits(names: [String], sizes: [Int64]) throws {
        let problem = SharedRules.shared.attachmentLimitError(
            names: names, sizes: sizes.map { KotlinLong(value: $0) })
        guard problem.isEmpty else { throw IOSAttachmentError.limit(problem) }
    }

    /// `incoming` after `existing`, when the result stays within the limits.
    nonisolated static func appending(
        _ incoming: [Dieter_V1_MessagePart],
        to existing: [Dieter_V1_MessagePart]
    ) throws -> [Dieter_V1_MessagePart] {
        let parts = existing + incoming
        try checkLimits(names: parts.map(\.filename), sizes: parts.map { Int64($0.data.count) })
        return parts
    }

    /// How many more files may join `existing`; pickers offer at most this many.
    nonisolated static func remainingSlots(after existing: [Dieter_V1_MessagePart]) -> Int {
        Int(SharedRules.shared.attachmentSlots(count: Int32(clamping: existing.count)))
    }

    /// The limits, as shown next to attachment pickers.
    nonisolated static var limits: String { SharedRules.shared.attachmentLimits() }

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
        var measured: [(source: IOSAttachmentSource, values: URLResourceValues)] = []
        for source in sources {
            let accessed = source.url.startAccessingSecurityScopedResource()
            defer { if accessed { source.url.stopAccessingSecurityScopedResource() } }
            let values = try source.url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile != false else {
                throw IOSAttachmentError.notAFile(source.filename ?? source.url.lastPathComponent)
            }
            measured.append((source, values))
        }
        // Measured sizes rule out oversized files before any is read; an
        // unknown size is checked once the file is read.
        try Self.checkLimits(
            names: existing.map(\.filename) + measured.map { $0.source.filename ?? $0.source.url.lastPathComponent },
            sizes: existing.map { Int64($0.data.count) } + measured.map { Int64($0.values.fileSize ?? 1) })
        var result = existing
        for (source, values) in measured {
            let accessed = source.url.startAccessingSecurityScopedResource()
            defer { if accessed { source.url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: source.url, options: [.mappedIfSafe])
            let type = values.contentType ?? UTType(filenameExtension: source.url.pathExtension)
            result.append(
                Self.part(
                    data: data, filename: source.filename ?? source.url.lastPathComponent,
                    declaredType: source.mediaType ?? type?.preferredMIMEType ?? ""))
        }
        return try Self.appending([], to: result)
    }

    func parts(
        payloads: [IOSAttachmentPayload],
        appendingTo existing: [Dieter_V1_MessagePart] = []
    ) throws -> [Dieter_V1_MessagePart] {
        let parts = payloads.map { Self.part(data: $0.data, filename: $0.filename, declaredType: $0.mediaType) }
        return try Self.appending(parts, to: existing)
    }

    #if os(iOS)
        func parts(
            photoItems: [PhotosPickerItem],
            appendingTo existing: [Dieter_V1_MessagePart] = []
        ) async throws -> [Dieter_V1_MessagePart] {
            // Rule out too many photos before loading any.
            try Self.checkLimits(
                names: existing.map(\.filename) + photoItems.map { _ in "" },
                sizes: existing.map { Int64($0.data.count) } + photoItems.map { _ in 1 })
            var payloads: [IOSAttachmentPayload] = []
            payloads.reserveCapacity(photoItems.count)
            for item in photoItems {
                guard let data = try await item.loadTransferable(type: Data.self), !data.isEmpty else {
                    throw IOSAttachmentError.invalidPaste
                }
                let type = item.supportedContentTypes.first(where: { $0.conforms(to: .image) })
                // Photos have no file name; the core names them.
                payloads.append(
                    IOSAttachmentPayload(data: data, filename: "", mediaType: type?.preferredMIMEType ?? ""))
            }
            return try parts(payloads: payloads, appendingTo: existing)
        }
    #endif

    /// The part the core sends a read file as, named and typed by its rules.
    private static func part(data: Data, filename: String, declaredType: String) -> Dieter_V1_MessagePart {
        Dieter_V1_MessagePart(
            rules: SharedRules.shared.attachmentPart(filename: filename, declaredMediaType: declaredType, bytes: data))
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
            // A bound on the manifest only; the loader applies the core's limits.
            !manifest.items.isEmpty, manifest.items.count <= 64
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
