import DieterAPI
import Foundation
import Testing
@testable import DieterIOS

/// Attachment reading stays native; what may be attached, and how parts are
/// named and typed, are the shared core's rules (SharedRules).
@Suite("iOS task attachments")
struct IOSAttachmentTests {
    /// The core's limits: 4 files, 5 MB each, 6 MB together.
    static let maximumCount = 4
    static let maximumBytes = 5 * 1_024 * 1_024
    static let maximumTotalBytes = 6 * 1_024 * 1_024

    @Test func filePickerPayloadsPreserveBytesNamesAndMediaTypes() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = directory.appendingPathComponent("screenshot.png")
        let notes = directory.appendingPathComponent("notes.txt")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: image)
        try Data("notes".utf8).write(to: notes)

        let parts = try await IOSAttachmentLoader().parts(urls: [image, notes])

        #expect(parts.map(\.filename) == ["screenshot.png", "notes.txt"])
        #expect(parts.map(\.type) == ["file", "file"])
        #expect(parts[0].mediaType == "image/png")
        #expect(parts[1].mediaType == "text/plain")
        #expect(parts[1].data == Data("notes".utf8))
    }

    @Test func attachmentLimitsIncludeExistingDraftFiles() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var existing: [Dieter_V1_MessagePart] = []
        for index in 0..<4 {
            var part = Dieter_V1_MessagePart()
            part.type = "file"
            part.filename = "\(index).txt"
            part.mediaType = "text/plain"
            part.data = Data([UInt8(index)])
            existing.append(part)
        }
        let extra = directory.appendingPathComponent("extra.txt")
        try Data("extra".utf8).write(to: extra)
        await #expect(throws: IOSAttachmentError.limit("You can attach up to 4 images or files.")) {
            try await IOSAttachmentLoader().parts(urls: [extra], appendingTo: existing)
        }
        #expect(IOSAttachmentLoader.remainingSlots(after: existing) == 0)
        #expect(IOSAttachmentLoader.remainingSlots(after: []) == Self.maximumCount)
        #expect(IOSAttachmentLoader.limits == "Up to 4 attachments · 5 MB each · 6 MB total")
    }

    @Test func pastedScreenshotPayloadsBecomePortableImageAttachments() async throws {
        let first = IOSAttachmentPayload(
            data: Data([0x89, 0x50, 0x4E, 0x47]),
            filename: "Pasted Screenshot.png",
            mediaType: "image/png")
        let second = IOSAttachmentPayload(
            data: Data([0x89, 0x50, 0x4E, 0x47, 0x02]),
            filename: "../Pasted Screenshot 2.png",
            mediaType: "IMAGE/PNG; charset=binary")

        let parts = try await IOSAttachmentLoader().parts(payloads: [first, second])

        #expect(parts.map(\.type) == ["file", "file"])
        #expect(parts.map(\.filename) == ["Pasted Screenshot.png", "Pasted Screenshot 2.png"])
        #expect(parts.map(\.mediaType) == ["image/png", "image/png"])
        #expect(parts.map(\.data) == [first.data, second.data])
    }

    @Test func pastedScreenshotLimitsIncludeExistingAttachments() async throws {
        var existing: [Dieter_V1_MessagePart] = []
        for index in 0..<4 {
            var part = Dieter_V1_MessagePart()
            part.type = "file"
            part.filename = "\(index).png"
            part.mediaType = "image/png"
            part.data = Data([UInt8(index)])
            existing.append(part)
        }
        let pasted = IOSAttachmentPayload(
            data: Data([0x89, 0x50, 0x4E, 0x47]),
            filename: "Pasted Screenshot.png",
            mediaType: "image/png")

        await #expect(throws: IOSAttachmentError.self) {
            try await IOSAttachmentLoader().parts(payloads: [pasted], appendingTo: existing)
        }
    }

    @Test func fileAndCombinedByteLimitsAreEnforced() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let oversized = directory.appendingPathComponent("oversized.bin")
        try Data(repeating: 1, count: Self.maximumBytes + 1).write(to: oversized)
        await #expect(throws: IOSAttachmentError.limit("Each attachment must be at most 5 MB.")) {
            try await IOSAttachmentLoader().parts(urls: [oversized])
        }

        var existing = Dieter_V1_MessagePart()
        existing.type = "file"
        existing.filename = "existing.bin"
        existing.mediaType = "application/octet-stream"
        // Two files that each fit and together use up the total.
        existing.data = Data(repeating: 2, count: Self.maximumTotalBytes / 2)
        let extra = directory.appendingPathComponent("extra.bin")
        try Data([3]).write(to: extra)
        await #expect(throws: IOSAttachmentError.limit("Attachments must total at most 6 MB.")) {
            try await IOSAttachmentLoader().parts(urls: [extra], appendingTo: [existing, existing])
        }
    }

    @Test func sharedAttachmentsRespectAnExistingComposerDraft() throws {
        var existing = Dieter_V1_MessagePart()
        existing.type = "file"
        existing.filename = "existing.png"
        existing.mediaType = "image/png"
        existing.data = Data([1])
        var shared = Dieter_V1_MessagePart()
        shared.type = "file"
        shared.filename = "shared.png"
        shared.mediaType = "image/png"
        shared.data = Data([2])

        let combined = try IOSAttachmentLoader.appending([shared], to: [existing])

        #expect(combined.map(\.filename) == ["existing.png", "shared.png"])
        #expect(combined.map(\.data) == [Data([1]), Data([2])])

        #expect(throws: IOSAttachmentError.self) {
            try IOSAttachmentLoader.appending(
                Array(repeating: shared, count: Self.maximumCount), to: [existing])
        }
    }

    @Test func stagedShareBecomesAttachmentsAndIsConsumedOnce() async throws {
        let container = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let id = UUID().uuidString.lowercased()
        let directory = container.appendingPathComponent("ShareInbox/\(id)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("screenshot".utf8).write(to: directory.appendingPathComponent("attachment-0.png"))
        try Data(
            """
            {"items":[{"storedName":"attachment-0.png","filename":"Screenshot.png","mediaType":"image/png"}]}
            """.utf8
        ).write(to: directory.appendingPathComponent("manifest.json"))

        let parts = try await IOSShareInbox.consume(id: id, from: container)

        #expect(parts.count == 1)
        #expect(parts[0].filename == "Screenshot.png")
        #expect(parts[0].mediaType == "image/png")
        #expect(parts[0].data == Data("screenshot".utf8))
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        await #expect(throws: IOSAttachmentError.self) {
            try await IOSShareInbox.consume(id: id, from: container)
        }
    }

    @Test func pendingShareHandoffIsBoundedAndClearedConditionally() throws {
        let container = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let first = IOSShareInbox.Request(id: UUID().uuidString.lowercased(), destination: .newTask)
        let second = IOSShareInbox.Request(id: UUID().uuidString.lowercased(), destination: .chat)
        for request in [first, second] {
            let directory = container.appendingPathComponent(
                "ShareInbox/\(request.id)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("{\"items\":[]}".utf8).write(to: directory.appendingPathComponent("manifest.json"))
        }

        try recordPendingRequest(first, in: container)
        #expect(IOSShareInbox.pendingRequest(from: container) == first)
        try recordPendingRequest(second, in: container)
        IOSShareInbox.clearPendingRequest(first, from: container)
        #expect(IOSShareInbox.pendingRequest(from: container) == second)
        IOSShareInbox.clearPendingRequest(second, from: container)
        #expect(IOSShareInbox.pendingRequest(from: container) == nil)
    }

    /// The extension pre-filters with its own copy of the limits; the app
    /// validates again on consume with the core's rules and naming.
    @Test func consumedShareIsValidatedAndNamedByTheCoreRules() async throws {
        let container = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let id = try stageShare(
            in: container,
            items: [("attachment-0.bin", "../Screen Shot.PNG", "IMAGE/PNG; charset=binary", Data([0x89, 0x50]))])
        let parts = try await IOSShareInbox.consume(id: id, from: container)
        #expect(parts.map(\.filename) == ["Screen Shot.PNG"])
        #expect(parts.map(\.mediaType) == ["image/png"])

        let tooMany = try stageShare(
            in: container,
            items: (0...Self.maximumCount).map { ("attachment-\($0).txt", "\($0).txt", "text/plain", Data([1])) })
        await #expect(throws: IOSAttachmentError.limit("You can attach up to 4 images or files.")) {
            try await IOSShareInbox.consume(id: tooMany, from: container)
        }
        // A rejected share is not offered again.
        #expect(
            !FileManager.default.fileExists(
                atPath: container.appendingPathComponent("ShareInbox/\(tooMany)").path))
    }

    @Test func stagedShareCannotEscapeItsInboxDirectory() async throws {
        let container = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let id = UUID().uuidString.lowercased()
        let directory = container.appendingPathComponent("ShareInbox/\(id)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("outside".utf8).write(to: container.appendingPathComponent("outside.txt"))
        try Data(
            """
            {"items":[{"storedName":"../../outside.txt","filename":"outside.txt","mediaType":"text/plain"}]}
            """.utf8
        ).write(to: directory.appendingPathComponent("manifest.json"))

        await #expect(throws: IOSAttachmentError.self) {
            try await IOSShareInbox.consume(id: id, from: container)
        }
    }

    /// Stages a share as the extension does: stored files plus a manifest.
    private func stageShare(
        in container: URL, items: [(stored: String, filename: String, mediaType: String, data: Data)]
    ) throws -> String {
        let id = UUID().uuidString.lowercased()
        let directory = container.appendingPathComponent("ShareInbox/\(id)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var manifest: [[String: String]] = []
        for item in items {
            try item.data.write(to: directory.appendingPathComponent(item.stored))
            manifest.append(["storedName": item.stored, "filename": item.filename, "mediaType": item.mediaType])
        }
        try JSONSerialization.data(withJSONObject: ["items": manifest])
            .write(to: directory.appendingPathComponent("manifest.json"))
        return id
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes the hand-off the share extension leaves for the app.
    private func recordPendingRequest(_ request: IOSShareInbox.Request, in container: URL) throws {
        let inbox = container.appendingPathComponent("ShareInbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        try JSONEncoder().encode(["id": request.id, "destination": request.destination.rawValue])
            .write(to: inbox.appendingPathComponent("pending-request.json"), options: .atomic)
    }
}
