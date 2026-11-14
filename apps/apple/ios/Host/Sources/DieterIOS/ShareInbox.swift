import DieterAPI
import Foundation

/// The share extension's handoff: it stages files in the app group's ShareInbox and records
/// one pending request with its destination; the app reads it the next time it is active.
enum ShareInbox {
    struct Request: Equatable, Sendable {
        let id: String
        /// "new-task", "task", "chat" or "folder" ("Save to folder…").
        let destination: String
    }

    private struct PendingRequest: Codable {
        let id: String
        let destination: String
    }

    private struct Manifest: Decodable {
        struct Item: Decodable {
            let storedName: String
            let filename: String
            let mediaType: String
            /// Absent in requests staged before folders.
            let size: Int64?
        }
        let items: [Item]
    }

    private static let pendingName = "pending-request.json"
    /// The extension offers tasks and chats only for files up to this size.
    private static let maximumAttachmentBytes: Int64 = 5 * 1_024 * 1_024

    static func container() -> URL? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "DieterAppGroupIdentifier") as? String,
            !group.isEmpty
        else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
    }

    /// The staged request, if one is complete; an incomplete or foreign request is ignored.
    static func pendingRequest(in container: URL) -> Request? {
        let inbox = container.appendingPathComponent("ShareInbox", isDirectory: true)
        guard let data = try? Data(contentsOf: inbox.appendingPathComponent(pendingName)),
            data.count <= 16 * 1_024,
            let pending = try? JSONDecoder().decode(PendingRequest.self, from: data),
            let id = UUID(uuidString: pending.id),
            ["new-task", "task", "chat", "folder"].contains(pending.destination)
        else { return nil }
        let canonical = id.uuidString.lowercased()
        let manifest = inbox.appendingPathComponent(canonical, isDirectory: true)
            .appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifest.path) else { return nil }
        return Request(id: canonical, destination: pending.destination)
    }

    /// Reads the request's files as one encoded UiMessage and removes them from the inbox.
    /// Files that cannot be read are reported in the returned problem; the rest still arrive.
    static func consume(_ request: Request, in container: URL) -> (message: Data, problem: String) {
        let inbox = container.appendingPathComponent("ShareInbox", isDirectory: true)
        let directory = inbox.appendingPathComponent(request.id, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: inbox.appendingPathComponent(pendingName))
            try? FileManager.default.removeItem(at: directory)
        }
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")),
            data.count <= 64 * 1_024,
            let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
            !manifest.items.isEmpty, manifest.items.count <= 64
        else { return (Data(), "The shared items could not be read. Share them again.") }
        var parts: [Dieter_V1_MessagePart] = []
        var problem = ""
        for item in manifest.items {
            // Stored names come from the extension; never follow a path out of the directory.
            guard !item.storedName.isEmpty, item.storedName == URL(fileURLWithPath: item.storedName).lastPathComponent,
                (item.size ?? 0) <= maximumAttachmentBytes,
                let bytes = try? Data(contentsOf: directory.appendingPathComponent(item.storedName)),
                Int64(bytes.count) <= maximumAttachmentBytes
            else {
                problem = "A shared file could not be read. Share it again."
                continue
            }
            parts.append(
                .with {
                    $0.type = "file"
                    $0.filename = item.filename
                    $0.mediaType = item.mediaType
                    $0.data = bytes
                })
        }
        let message = (try? Dieter_V1_UiMessage.with { $0.parts = parts }.serializedData()) ?? Data()
        return (message, problem)
    }

    /// "Save to folder…": moves the request's files out of the App Group into the app's caches,
    /// where they stay while the core streams them into the folder the person picks, and returns
    /// their file URLs and names in order. Earlier handoffs older than a day are removed.
    static func consumeForFolder(_ request: Request, in container: URL) -> (
        sources: [String], names: [String], problem: String
    ) {
        let manager = FileManager.default
        let inbox = container.appendingPathComponent("ShareInbox", isDirectory: true)
        let directory = inbox.appendingPathComponent(request.id, isDirectory: true)
        defer {
            try? manager.removeItem(at: inbox.appendingPathComponent(pendingName))
            try? manager.removeItem(at: directory)
        }
        guard let caches = manager.urls(for: .cachesDirectory, in: .userDomainMask).first,
            let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")),
            data.count <= 64 * 1_024,
            let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
            !manifest.items.isEmpty, manifest.items.count <= 100
        else { return ([], [], "The shared items could not be read. Share them again.") }
        let handoffs = caches.appendingPathComponent("SharedToFolder", isDirectory: true)
        removeOldHandoffs(in: handoffs)
        let target = handoffs.appendingPathComponent(request.id, isDirectory: true)
        guard (try? manager.createDirectory(at: target, withIntermediateDirectories: true)) != nil else {
            return ([], [], "The shared items could not be read. Share them again.")
        }
        var sources: [String] = []
        var names: [String] = []
        var problem = ""
        for item in manifest.items {
            // Stored names come from the extension; never follow a path out of the directory.
            let destination = target.appendingPathComponent(item.storedName)
            guard !item.storedName.isEmpty, item.storedName == URL(fileURLWithPath: item.storedName).lastPathComponent,
                (try? manager.moveItem(at: directory.appendingPathComponent(item.storedName), to: destination))
                    != nil
            else {
                problem = "A shared file could not be read. Share it again."
                continue
            }
            sources.append(destination.absoluteString)
            names.append(item.filename)
        }
        return (sources, names, problem)
    }

    private static func removeOldHandoffs(in directory: URL) {
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        let entries =
            (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])) ?? []
        for entry in entries {
            let created = (try? entry.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            if created < cutoff { try? FileManager.default.removeItem(at: entry) }
        }
    }
}
