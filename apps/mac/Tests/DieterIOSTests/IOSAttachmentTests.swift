import DieterAPI
import Foundation
import Testing
@testable import DieterIOS

@Suite("iOS task attachments")
struct IOSAttachmentTests {
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
        await #expect(throws: IOSAttachmentError.self) {
            try await IOSAttachmentLoader().parts(urls: [extra], appendingTo: existing)
        }
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
        try Data(repeating: 1, count: IOSAttachmentLoader.maximumBytes + 1).write(to: oversized)
        await #expect(throws: IOSAttachmentError.self) {
            try await IOSAttachmentLoader().parts(urls: [oversized])
        }

        var existing = Dieter_V1_MessagePart()
        existing.type = "file"
        existing.filename = "existing.bin"
        existing.mediaType = "application/octet-stream"
        existing.data = Data(repeating: 2, count: IOSAttachmentLoader.maximumTotalBytes)
        let extra = directory.appendingPathComponent("extra.bin")
        try Data([3]).write(to: extra)
        await #expect(throws: IOSAttachmentError.self) {
            try await IOSAttachmentLoader().parts(urls: [extra], appendingTo: [existing])
        }
    }

    @Test func shareURLAcceptsOnlyCanonicalInboxIdentifiers() throws {
        let id = UUID()
        let valid = try #require(URL(string: "dieter-mac://share?id=\(id.uuidString)"))
        #expect(IOSShareInbox.shareID(from: valid) == id.uuidString.lowercased())
        #expect(IOSShareInbox.request(from: valid)?.destination == .newTask)
        for destination in [
            IOSShareInbox.Destination.newTask, .task, .chat,
        ] {
            let routed = try #require(
                URL(string: "dieter-mac://share?id=\(id.uuidString)&destination=\(destination.rawValue)"))
            #expect(
                IOSShareInbox.request(from: routed)
                    == IOSShareInbox.Request(id: id.uuidString.lowercased(), destination: destination))
        }
        #expect(IOSShareInbox.shareID(from: URL(string: "https://share?id=\(id)")!) == nil)
        #expect(IOSShareInbox.shareID(from: URL(string: "dieter-mac://share?id=../escape")!) == nil)
        #expect(
            IOSShareInbox.request(
                from: URL(string: "dieter-mac://share?id=\(id)&destination=unknown")!) == nil)
        #expect(IOSShareInbox.shareID(from: URL(string: "dieter-mac://oauth/callback?id=\(id)")!) == nil)
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
                Array(repeating: shared, count: IOSAttachmentLoader.maximumCount), to: [existing])
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

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
