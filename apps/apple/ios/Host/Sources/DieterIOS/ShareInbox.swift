import DieterAPI
import Foundation

/// The share extension's handoff: it stages files in the app group's ShareInbox and records
/// one pending request with its destination; the app reads it the next time it is active.
enum ShareInbox {
    struct Request: Equatable, Sendable {
        let id: String
        /// "new-task", "task" or "chat".
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
        }
        let items: [Item]
    }

    private static let pendingName = "pending-request.json"

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
            ["new-task", "task", "chat"].contains(pending.destination)
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
                let bytes = try? Data(contentsOf: directory.appendingPathComponent(item.storedName))
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
}
