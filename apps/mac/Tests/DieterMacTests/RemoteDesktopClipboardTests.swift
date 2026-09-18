import AppKit
import DieterCore
import Foundation
import Testing
@testable import DieterMac

@Test func screenClipboardPreservesFilesAndRejectsUnsafeNames() throws {
    let board = NSPasteboard(name: .init("com.dbpprt.dieter.fixture.binary.\(UUID().uuidString)"))
    let root = FileManager.default.temporaryDirectory.appending(path: "clipboard-unit-\(UUID().uuidString)")
    defer { board.releaseGlobally(); try? FileManager.default.removeItem(at: root) }
    let original = ScreenClipboardContent(items: [
        .init(kind: 0, name: "empty.txt", mimeType: "text/plain", data: Data()),
        .init(kind: 0, name: "binary.bin", mimeType: "application/octet-stream", data: Data([0, 255, 10])),
    ])
    try original.write(board, directory: root)
    let result = try ScreenClipboardContent.read(board, binary: true)
    #expect(result.items.map(\.name) == original.items.map(\.name))
    #expect(result.items.map(\.data) == original.items.map(\.data))
    #expect(try ScreenClipboardContent.read(board, binary: false).text == nil)
    for name in ["../escape", "/absolute", "..", "a\\b", "nul\0name"] {
        let bad = ScreenClipboardContent(items: [
            .init(kind: 0, name: name, mimeType: "application/octet-stream", data: Data())
        ])
        #expect(throws: (any Error).self) { try bad.write(board, directory: root) }
    }
    // Clipboard URLs stay usable after transfer, and staging retains at most
    // eight batches without deleting files outside its own transfer namespace.
    try Data([7]).write(to: root.appending(path: "untouched"))
    for _ in 0..<12 { try original.write(board, directory: root) }
    #expect(
        try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("transfer-") }.count == 8)
    #expect(try Data(contentsOf: root.appending(path: "untouched")) == Data([7]))
}
