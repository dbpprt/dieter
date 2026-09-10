import AppKit
import DieterAPI
import DieterClient
import DieterCore
import Testing
@testable import DieterMac

@Test func externalFileLocalityUsesTheActualDataPlaneAndRejectsRelay() {
    let gateway = DieterEndpoint(name: "Gateway", host: "gateway.example", port: 443, secure: true, daemonID: "daemon")
    #expect(DieterRPC.isLoopbackDataPlane(endpoint: gateway, route: .gateway, directHost: "127.0.0.1"))
    #expect(DieterRPC.isLoopbackDataPlane(endpoint: gateway, route: .gateway, directHost: "::1"))
    #expect(DieterRPC.isLoopbackDataPlane(endpoint: gateway, route: .gateway, directHost: "::ffff:127.0.0.1"))
    #expect(!DieterRPC.isLoopbackDataPlane(endpoint: gateway, route: .gateway, directHost: "192.168.1.2"))
    #expect(!DieterRPC.isLoopbackDataPlane(endpoint: gateway, route: .relay(daemonID: "daemon"), directHost: nil))
    #expect(
        !DieterRPC.isLoopbackDataPlane(endpoint: gateway, route: .relay(daemonID: "remote"), directHost: "127.0.0.1"))
    let local = DieterEndpoint(name: "Local", host: "127.0.0.1", port: 4242)
    #expect(DieterRPC.isLoopbackDataPlane(endpoint: local, route: .gateway, directHost: nil))
    #expect(!DieterRPC.isLoopbackDataPlane(endpoint: local, route: .relay(daemonID: "remote"), directHost: nil))
    let localGateway = DieterEndpoint(name: "Local gateway", host: "localhost", port: 443, daemonID: "remote")
    #expect(!DieterRPC.isLoopbackDataPlane(endpoint: localGateway, route: .gateway, directHost: nil))
}

@Test func externalFileResolutionRequiresLocalityAndAContainedRegularFile() throws {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let root = temporary.appendingPathComponent("project")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let file = root.appendingPathComponent("notes.md")
    try Data("# Local".utf8).write(to: file)
    let outside = temporary.appendingPathComponent("outside.md")
    try Data("outside".utf8).write(to: outside)
    try FileManager.default.createSymbolicLink(
        at: root.appendingPathComponent("linked.md"), withDestinationURL: outside)

    let local = FileExternalActions.resolve(verifiedLocal: true, rootPath: root.path, relativePath: "notes.md")
    #expect(local.fileURL == file.resolvingSymlinksInPath())
    #expect(local.displayPath == file.path)
    let remote = FileExternalActions.resolve(verifiedLocal: false, rootPath: root.path, relativePath: "notes.md")
    #expect(remote.fileURL == nil)
    #expect(remote.displayPath == file.path)
    for path in ["../outside.md", "linked.md", "missing.md", "", "/notes.md", "./notes.md"] {
        #expect(
            FileExternalActions.resolve(verifiedLocal: true, rootPath: root.path, relativePath: path).fileURL == nil)
    }
    #expect(FileExternalActions.resolve(verifiedLocal: true, rootPath: nil, relativePath: "notes.md").fileURL == nil)
}

@Test func externalApplicationChoicesDeduplicateAndPutDefaultFirst() {
    let alpha = FileOpeningApplication(
        url: URL(fileURLWithPath: "/Applications/Alpha.app"), name: "Alpha", isDefault: false)
    let zulu = FileOpeningApplication(
        url: URL(fileURLWithPath: "/Applications/Zulu.app"), name: "Zulu", isDefault: false)
    let preferred = FileOpeningApplication(url: alpha.url, name: "Alpha", isDefault: true)
    let ordered = FileOpeningApplication.ordered([zulu, alpha, preferred, zulu])
    #expect(ordered == [preferred, zulu])
}

@Test @MainActor func fileCopyActionsUseTheExactNameOrPath() {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    FileExternalActions.copy("Notes with spaces.md", to: pasteboard)
    #expect(pasteboard.string(forType: .string) == "Notes with spaces.md")
    FileExternalActions.copy("/project/Notes with spaces.md", to: pasteboard)
    #expect(pasteboard.string(forType: .string) == "/project/Notes with spaces.md")
}

@Test @MainActor func saveAsExportsUnsavedSourceWithoutMarkingTheOriginalSaved() {
    let session = FileEditorSession()
    session.prepare(documentKey: "file-a", text: "Saved")
    #expect(session.applyReplacement("Unsaved\n💡", documentKey: "file-a"))
    var document = Dieter_V1_FileDocument()
    document.content = "Saved"
    #expect(
        FileExternalActions.exportBytes(document: document, session: session, documentKey: "file-a")
            == Data("Unsaved\n💡".utf8))
    #expect(session.isDirty)
    #expect(
        FileExternalActions.exportBytes(document: document, session: session, documentKey: "other-file")
            == Data("Saved".utf8))
    document.binary = true
    document.data = Data([0, 255, 17])
    #expect(
        FileExternalActions.exportBytes(document: document, session: session, documentKey: "file-a") == document.data)
    #expect(session.isDirty)
}
