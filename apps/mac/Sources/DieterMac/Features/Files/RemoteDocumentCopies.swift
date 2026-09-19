import DieterAPI
import Foundation

/// External apps receive a bounded, private snapshot, never a remote pathname
/// interpreted as a path on this Mac. Copies live for this Dieter session.
@MainActor final class RemoteDocumentCopies {
    private let root: URL
    private var copies: [URL] = []
    static let maximumBytes = 32 * 1024 * 1024

    init(
        root: URL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "DieterDocuments-" + UUID().uuidString)
    ) {
        self.root = root
    }

    func fetch(
        client: any FilesRPC, target: WorkspaceTarget, path: String,
        isCurrent: @MainActor () -> Bool
    ) async throws -> URL {
        guard isCurrent() else { throw CancellationError() }
        var request = Dieter_V1_ReadFileRequest()
        request.projectID = target.projectID
        request.cardID = target.conversationID
        request.path = path
        let document = try await client.readFile(request)
        try Task.checkCancellation()
        guard isCurrent() else { throw CancellationError() }
        return try save(document, path: path)
    }

    func save(_ document: Dieter_V1_FileDocument, path: String) throws -> URL {
        let name = (path as NSString).lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", !name.contains("\0") else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        let bytes = ProjectFilePresentation.bytes(
            binary: document.binary, content: document.content, data: document.data)
        guard bytes.count <= Self.maximumBytes else { throw CocoaError(.fileReadTooLarge) }
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let file = folder.appendingPathComponent(name)
        do {
            try bytes.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        copies.append(folder)
        // Bound retained snapshots while allowing several external documents.
        if copies.count > 16 { try? FileManager.default.removeItem(at: copies.removeFirst()) }
        return file
    }

    deinit { try? FileManager.default.removeItem(at: root) }
}
